using WOSetup.Core.Actions;
using WOSetup.Core.Checks;
using WOSetup.Core.Flow;
using WOSetup.Core.Scripts;

namespace WOSetup.Core.Tests;

public class CheckPlanTests
{
    [Fact]
    public void Each_check_runs_once_and_answers_every_step_that_uses_it()
    {
        var flow = FlowLoader.Load(Profile.WO7);
        var plan = new CheckPlan(flow.AllSteps);
        Assert.Single(plan.ScriptChecks, c => c == "bitlocker-off");     // WO7-03.1 and WO7-08.3
        Assert.Contains("lgpo", plan.Native);
        Assert.Contains("display-scale", plan.Native);
        Assert.DoesNotContain("lgpo", plan.ScriptChecks);
        Assert.Equal([EnginePhase.PreUpdate, EnginePhase.PostInstall], plan.AuditPhases);

        var byCheck = new Dictionary<string, CheckResult> { ["bitlocker-off"] = new("bitlocker-off", CheckState.Done, "off") };
        var results = plan.ForSteps(byCheck, new Dictionary<EnginePhase, EngineResult?>());
        Assert.Equal(CheckState.Done, results.Single(r => r.Id == "WO7-03.1").State);
        Assert.Equal(CheckState.Done, results.Single(r => r.Id == "WO7-08.3").State);
        Assert.Equal(CheckState.CantCheck, results.Single(r => r.Id == "WO7-02.5").State);   // no result = never done
        Assert.Equal(CheckState.CantCheck, results.Single(r => r.Id == "WO7-07.4").State);   // audit missing
    }

    [Fact]
    public void Full_audit_needs_both_phases_clean()
    {
        var flow = FlowLoader.Load(Profile.WO6);
        var plan = new CheckPlan(flow.AllSteps.Where(s => s.Id == "WO6-08.7"));
        Assert.Equal([EnginePhase.PreUpdate, EnginePhase.PostInstall], plan.AuditPhases);
        var clean = new EngineResult { Status = "Completed", Audit = [new AuditEntry { State = "Set" }] };
        var gap = new EngineResult { Status = "Completed", Audit = [new AuditEntry { State = "NotSet", Item = "x" }] };
        Assert.Equal(CheckState.Done, plan.ForSteps(new Dictionary<string, CheckResult>(),
            new Dictionary<EnginePhase, EngineResult?> { [EnginePhase.PreUpdate] = clean, [EnginePhase.PostInstall] = clean })[0].State);
        Assert.Equal(CheckState.NotDone, plan.ForSteps(new Dictionary<string, CheckResult>(),
            new Dictionary<EnginePhase, EngineResult?> { [EnginePhase.PreUpdate] = clean, [EnginePhase.PostInstall] = gap })[0].State);
    }

    [Fact]
    public void Check_context_carries_profile_and_options()
    {
        var ctx = CheckContext.Build(Profile.WO6, Role.Display, new Options.EngineOptions { KeepUpdateService = true });
        Assert.Equal("WO6", ctx["Profile"]);
        var o = Assert.IsType<Dictionary<string, object?>>(ctx["Options"]);
        Assert.Equal(true, o["KeepUpdateService"]);
        Assert.Equal("Off", o["DefenderMode"]);
    }
}

public class ActionModelTests
{
    [Fact]
    public void Result_data_is_read_in_every_shape_PowerShell_5_writes()
    {
        var plain = ActionResult.Parse("""{"Status":"Completed","Warnings":[],"Data":[{"Number":1,"Name":"RAID0","SizeGB":3800,"BusType":"RAID"}]}""");
        Assert.False(plain.Failed);
        Assert.Equal(1, plain.DataList<DiskInfo>()[0].Number);

        var wrapped = ActionResult.Parse("""{"Status":"Completed","Warnings":[],"Data":{"value":[{"Number":2}],"Count":1}}""");
        Assert.Equal(2, wrapped.DataList<DiskInfo>()[0].Number);

        var single = ActionResult.Parse("""{"Status":"Completed","Warnings":[],"Data":{"Number":3}}""");
        Assert.Equal(3, single.DataList<DiskInfo>()[0].Number);

        var empty = ActionResult.Parse("""{"Status":"Failed","Warnings":["boom"],"Data":[]}""");
        Assert.True(empty.Failed);
        Assert.Empty(empty.DataList<DiskInfo>());
    }

    [Fact]
    public void Static_ip_input_is_validated()
    {
        Assert.Empty(new StaticIpEntry("Show", "192.168.10.11", 24, "", "").Validate());
        Assert.Empty(new StaticIpEntry("Show", "10.0.0.5", 8, "10.0.0.1", "10.0.0.1, 1.1.1.1").Validate());
        Assert.NotEmpty(new StaticIpEntry("Show", "192.168.10", 24, "", "").Validate());
        Assert.NotEmpty(new StaticIpEntry("Show", "192.168.10.11", 33, "", "").Validate());
        Assert.Contains("is not in", new StaticIpEntry("Show", "192.168.10.11", 24, "192.168.11.1", "").Validate()[0]);
        Assert.NotEmpty(new StaticIpEntry("Show", "192.168.10.11", 24, "", "dns.local").Validate());

        var all = StaticIpEntry.ValidateAll([
            new StaticIpEntry("A", "192.168.10.11", 24, "192.168.10.1", ""),
            new StaticIpEntry("B", "192.168.10.11", 24, "192.168.10.1", ""),
        ]);
        Assert.Contains(all, e => e.Contains("more than one adapter"));
        Assert.Contains(all, e => e.Contains("one adapter should have a default gateway"));
        Assert.NotEmpty(StaticIpEntry.ValidateAll([]));
    }

    [Fact]
    public void Disk_writes_need_the_disk_number_typed()
    {
        var disk = new DiskInfo { Number = 2, Name = "RAID0", SizeGB = 3800, BusType = "RAID" };
        var s = ActionSummaryBuilder.MediaDisk(disk, new MediaDiskInput(2, "Media", 65536));
        Assert.Equal("DISK 2", s.TypedWord);
        Assert.Contains(s.Lines, l => l.Contains("64 KB"));
        Assert.NotNull(ActionSummaryBuilder.BitLockerOff().TypedWord);
        Assert.NotNull(ActionSummaryBuilder.StaticIp([new StaticIpEntry("A", "1.2.3.4", 24, "", "")]).TypedWord);
    }

    [Fact]
    public void Media_disk_input_is_validated()
    {
        Assert.Empty(new MediaDiskInput(1, "Media", 65536).Validate());
        Assert.NotEmpty(new MediaDiskInput(1, "Media", 8192).Validate());
        Assert.NotEmpty(new MediaDiskInput(1, "Me:dia", 4096).Validate());
        Assert.NotEmpty(new MediaDiskInput(-1, "Media", 4096).Validate());
    }
    [Fact]
    public void Recovery_steps_that_write_ask_for_a_typed_word()
    {
        // Owner, Nov 2026: typed confirmations stay (AGENTS.md rule 7).
        Assert.Equal("BOOT", ActionSummaryBuilder.RecoveryInstall("F9", @"E:\WOSetupRecovery", "D").TypedWord);
        Assert.Equal("CAPTURE", ActionSummaryBuilder.RecoveryCapture("WO7_W11-25H2_2026-11-20", "D").TypedWord);
        Assert.Null(ActionSummaryBuilder.RecoveryExport(@"F:\Images\WO-DISP-01").TypedWord);
        Assert.Contains(ActionSummaryBuilder.RecoveryCapture("X", "D").Lines, l => l.Contains("before any show"));
    }

    [Theory]
    [InlineData("WO7.8.4_W11-25H2_2026-11-20", true)]
    [InlineData("WO7_W11-25H2_2026-11-20", true)]
    [InlineData("WO7 factory", false)]
    [InlineData("", false)]
    [InlineData(".hidden", false)]
    [InlineData("a/b", false)]
    public void Image_names_follow_the_WinPE_rule(string name, bool ok) =>
        Assert.Equal(ok, RecoveryInputs.ValidateImageName(name).Count == 0);

    [Fact]
    public void Default_image_name_is_valid() =>
        Assert.Empty(RecoveryInputs.ValidateImageName(RecoveryInputs.DefaultImageName("WO7", new DateOnly(2026, 11, 20))));

    [Theory]
    [InlineData(@"E:\WO7-Work", null, "E")]
    [InlineData(null, @"D:\WATCHOUT 7", "D")]
    [InlineData(@"C:\WATCHOUT\.wo", null, "D")]
    [InlineData(@"\\nas\share", null, "D")]
    [InlineData(null, null, "D")]
    public void Data_drive_comes_from_the_working_directory(string? workDir, string? woPath, string expected) =>
        Assert.Equal(expected, RecoveryInputs.DataDrive(workDir, woPath));

    [Fact]
    public void Recovery_keys_leave_the_firmware_keys_alone()
    {
        Assert.Equal("F9", RecoveryInputs.Keys[0]);
        Assert.DoesNotContain("F12", RecoveryInputs.Keys);
        Assert.DoesNotContain("F1", RecoveryInputs.Keys);
    }
}
