using WOSetup.Core.Flow;

namespace WOSetup.Core.Tests;

public class FlowTests
{
    [Theory]
    [InlineData(Profile.WO7)]
    [InlineData(Profile.WO6)]
    public void Embedded_flow_loads_and_is_valid(Profile profile)
    {
        var flow = FlowLoader.Load(profile);
        Assert.Equal(profile, flow.Profile);
        Assert.Empty(FlowValidator.Validate(flow));
        Assert.True(flow.AllSteps.Count() > 50);
    }

    [Theory]
    [InlineData(Profile.WO7)]
    [InlineData(Profile.WO6)]
    public void Flow_starts_after_Windows_is_installed(Profile profile)
    {
        // Oct 2026: "Before you start" and "Install Windows" are not wizard steps any more.
        var flow = FlowLoader.Load(profile);
        Assert.Equal([0, 1, 2, 3, 4, 5, 6, 7, 8, 99], flow.Sections.Select(s => s.Number));
        Assert.StartsWith("First boot", flow.Sections[1].Title);
        Assert.DoesNotContain(flow.AllSteps, s => s.Title.Contains("BIOS", StringComparison.Ordinal) && s.Section.Number == 1);
    }

    [Theory]
    [InlineData(Profile.WO7, "WO7-01.2", "WO7-07.4")]
    [InlineData(Profile.WO6, "WO6-01.2", "WO6-06.4")]
    public void Script_phases_are_automated_steps_in_checklist_order(Profile profile, string preUpdate, string postInstall)
    {
        var flow = FlowLoader.Load(profile);
        var pre = Assert.IsType<AutomatedStep>(flow.Find(preUpdate));
        var post = Assert.IsType<AutomatedStep>(flow.Find(postInstall));
        Assert.Equal(EnginePhase.PreUpdate, pre.Action!.Phase);
        Assert.Equal(EnginePhase.PostInstall, post.Action!.Phase);
        Assert.True(pre.MustBeOffline);
        Assert.True(post.Confirm);
        Assert.Equal("audit:PreUpdate", pre.Check);
        Assert.Equal("audit:PostInstall", post.Check);
        var ids = flow.AllSteps.Select(s => s.Id).ToList();
        Assert.True(ids.IndexOf(preUpdate) < ids.IndexOf(postInstall));
    }

    [Theory]
    [InlineData(Profile.WO7, "WO7-07.3", "WO7-07.4")]
    [InlineData(Profile.WO6, "WO6-06.3a", "WO6-06.4")]
    public void Audit_before_applying_comes_right_before_PostInstall(Profile profile, string audit, string run)
    {
        var flow = FlowLoader.Load(profile);
        var step = Assert.IsType<CheckStep>(flow.Find(audit));
        Assert.Equal(EnginePhase.PostInstall, step.AuditPhase);
        Assert.True(step.Informational);
        var ids = flow.AllSteps.Select(s => s.Id).ToList();
        Assert.Equal(ids.IndexOf(run) - 1, ids.IndexOf(audit));
    }

    [Theory]
    [InlineData(Profile.WO7)]
    [InlineData(Profile.WO6)]
    public void Owner_decisions_on_what_is_automatic_are_in_the_flow(Profile profile)
    {
        // Oct 2026: BitLocker off, media drive, static IP and Wake-on-LAN are automatic
        // (WO7 also indexing off); updates, drivers, WinUtil, NVIDIA and WATCHOUT install stay manual.
        var flow = FlowLoader.Load(profile);
        var commands = flow.AllSteps.Where(s => s.IsCommand).Select(s => s.Action!.Name).ToHashSet();
        Assert.Superset(new HashSet<string?> { "bitlocker-off", "media-disk-init", "static-ip", "wol-enable" }, commands);
        Assert.All(flow.AllSteps.Where(s => s.Check is "updates" or "nvidia-driver" or "watchout-installed"),
                   s => Assert.Equal(StepKind.Manual, s.Kind));
        Assert.All(flow.AllSteps.Where(s => s.Action?.Name is "bitlocker-off" or "media-disk-init" or "static-ip"),
                   s => Assert.True(s.Confirm));
    }

    [Fact]
    public void Restart_after_PostInstall_depends_on_it()
    {
        var flow = FlowLoader.Load(Profile.WO7);
        var restart = flow.Find("WO7-07.6")!;
        Assert.True(restart.IsRestart);
        Assert.Equal("WO7-07.4", restart.After);
    }

    [Fact]
    public void Sections_follow_the_checklist_and_steps_know_their_section()
    {
        var flow = FlowLoader.Load(Profile.WO7);
        Assert.Equal(0, flow.Sections[0].Number);
        Assert.Equal(99, flow.Sections[^1].Number);
        Assert.All(flow.AllSteps, s => Assert.Contains(s, s.Section.Steps));
    }

    [Fact]
    public void Role_specific_steps_are_marked()
    {
        var wo6 = FlowLoader.Load(Profile.WO6);
        Assert.Equal([Role.Display], wo6.Find("WO6-08.2")!.Roles);
        Assert.Equal([Role.Production], wo6.Find("WO6-05.8")!.Roles);
    }

    [Fact]
    public void WO6_has_its_own_WinUtil_steps()
    {
        var wo6 = FlowLoader.Load(Profile.WO6);
        Assert.Equal(4, wo6.Find("WO6-04.1")!.Section.Number);
        Assert.Contains("WinUtil", wo6.Find("WO6-04.1")!.Section.Title);
    }

    [Fact]
    public void Validator_rejects_a_broken_after_reference()
    {
        var flow = FlowLoader.Parse(new MemoryStream(System.Text.Encoding.UTF8.GetBytes("""
            { "schemaVersion": 2, "profile": "WO7", "title": "t", "script": "WO7-Setup.ps1",
              "sections": [ { "id": "s", "number": 1, "title": "S", "steps": [
                { "id": "a", "title": "A", "kind": "manual", "after": "zz" },
                { "id": "b", "title": "B", "kind": "check" } ] } ] }
            """)));
        var errors = FlowValidator.Validate(flow);
        Assert.Contains(errors, e => e.Contains("unknown step zz"));
        Assert.Contains(errors, e => e.Contains("check step without a check"));
    }
}

public class OpenTargetTests
{
    [Fact]
    public void Open_mentions_become_buttons()
    {
        Assert.Equal(["ncpa.cpl"], OpenTargets.Extract("Open `ncpa.cpl`. C†: `Get-NetAdapterBinding` per physical adapter"));
        Assert.Equal(["netplwiz", "ms-settings:signinoptions"], OpenTargets.Extract("Open `netplwiz`, `ms-settings:signinoptions`. C†: `HKLM\\...`"));
    }

    [Fact]
    public void Commands_in_checks_are_never_offered()
    {
        Assert.Empty(OpenTargets.Extract("`pnputil /enum-drivers | findstr /i rcraid` → all three found"));
        Assert.Empty(OpenTargets.Extract("C: `Get-MpComputerStatus | Select IsTamperProtected` → False"));
    }

    [Fact]
    public void Every_flow_step_offers_only_known_kinds_of_targets()
    {
        foreach (var p in new[] { Profile.WO7, Profile.WO6 })
            foreach (var s in FlowLoader.Load(p).AllSteps)
                foreach (var t in OpenTargets.Extract(s.Title + " " + s.Details))
                    Assert.Matches(@"^([A-Za-z0-9]+\.(msc|cpl)|ms-settings:.+|windowsdefender://.+|netplwiz|dfrgui|UserAccountControlSettings\.exe|SystemProperties\w+\.exe)$", t);
    }
}
