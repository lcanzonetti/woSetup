using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;

namespace WOSetup.Core.Tests;

public class OptionsAndScriptTests
{
    private static Dictionary<string, object> Args(Profile p, Role r, EnginePhase ph, EngineOptions o, bool audit = false, string? result = null) =>
        ScriptArgumentBuilder.Build(p, r, ph, o, audit, result).ToDictionary(kv => kv.Key, kv => kv.Value);

    [Fact]
    public void PreUpdate_takes_only_the_phase()
    {
        var o = new EngineOptions { KeepFirewall = true, DefenderMode = DefenderMode.Skip };
        var a = Args(Profile.WO7, Role.Production, EnginePhase.PreUpdate, o);
        Assert.Equal(["Phase"], a.Keys);
    }

    [Fact]
    public void Defaults_produce_a_bare_PostInstall()
    {
        var a = Args(Profile.WO6, Role.Display, EnginePhase.PostInstall, new EngineOptions());
        Assert.Equal(["Phase"], a.Keys);
        Assert.Equal("PostInstall", a["Phase"]);
    }

    [Fact]
    public void KeepService_is_passed_as_an_array()
    {
        var o = new EngineOptions { KeepService = ["TermService", " SessionEnv ", ""] };
        var a = Args(Profile.WO6, Role.Display, EnginePhase.PostInstall, o);
        Assert.Equal(new[] { "TermService", "SessionEnv" }, (string[])a["KeepService"]);
    }

    [Fact]
    public void Profile_specific_options_are_only_passed_to_their_script()
    {
        var o = new EngineOptions { WorkingDirectory = @"E:\Work", ShowsPath = @"E:\Shows", KeepAdapterBindings = true };
        var wo7 = Args(Profile.WO7, Role.Display, EnginePhase.PostInstall, o);
        var wo6 = Args(Profile.WO6, Role.Display, EnginePhase.PostInstall, o);
        Assert.True(wo7.ContainsKey("WorkingDirectory"));
        Assert.False(wo7.ContainsKey("ShowsPath"));
        Assert.False(wo7.ContainsKey("KeepAdapterBindings"));
        Assert.True(wo6.ContainsKey("ShowsPath"));
        Assert.False(wo6.ContainsKey("WorkingDirectory"));
    }

    [Fact]
    public void Audit_and_result_path_are_added()
    {
        var a = Args(Profile.WO7, Role.Display, EnginePhase.PostInstall, new EngineOptions(), audit: true, result: @"C:\r.json");
        Assert.Equal(true, a["Audit"]);
        Assert.Equal(@"C:\r.json", a["ResultPath"]);
    }

    [Fact]
    public void Command_line_matches_what_an_operator_types()
    {
        var o = new EngineOptions { KeepService = ["TermService", "SessionEnv"], ShowsPath = @"E:\My Shows", KeepFirewall = true };
        var p = ScriptArgumentBuilder.Build(Profile.WO6, Role.Production, EnginePhase.PostInstall, o, audit: false, resultPath: @"C:\x.json");
        var line = ScriptArgumentBuilder.CommandLine("WO6-Setup.ps1", p);
        Assert.Equal(@".\WO6-Setup.ps1 -Phase PostInstall -Role Production -KeepFirewall -ShowsPath 'E:\My Shows' -KeepService TermService,SessionEnv", line);
    }

    [Fact]
    public void Options_are_validated_like_the_scripts_do()
    {
        Assert.Empty(OptionsValidator.Validate(Profile.WO6, new EngineOptions { PinVersion = "25H2", StartDelay = 600 }));
        Assert.NotEmpty(OptionsValidator.Validate(Profile.WO6, new EngineOptions { StartDelay = 601 }));
        Assert.NotEmpty(OptionsValidator.Validate(Profile.WO7, new EngineOptions { PinVersion = "Windows 11" }));
        Assert.NotEmpty(OptionsValidator.Validate(Profile.WO6, new EngineOptions { KeepService = ["Term Service"] }));
    }

    [Fact]
    public void PostInstall_summary_names_every_security_reduction_and_needs_typing()
    {
        var s = ConfirmationSummaryBuilder.Build(Profile.WO6, Role.Display, EnginePhase.PostInstall, new EngineOptions(), lgpoAvailable: true);
        Assert.True(s.RequiresTypedConfirmation);
        var text = string.Join("\n", s.Lines);
        Assert.Contains("Firewall will be turned OFF", text);
        Assert.Contains("real-time protection will be turned OFF", text);
        Assert.Contains("DISABLED FOR GOOD", text);
        Assert.Contains("UNBOUND", text);
        Assert.Contains("does NOT undo", text);
        Assert.DoesNotContain("LGPO.exe NOT FOUND", text);
    }

    [Fact]
    public void Summary_follows_the_options()
    {
        var o = new EngineOptions { KeepFirewall = true, DefenderMode = DefenderMode.Exclusions, KeepUpdateService = true, KeepAdapterBindings = true };
        var text = string.Join("\n", ConfirmationSummaryBuilder.Build(Profile.WO6, Role.Display, EnginePhase.PostInstall, o, false).Lines);
        Assert.Contains("Firewall stays ON", text);
        Assert.Contains("Defender stays ON", text);
        Assert.DoesNotContain("DISABLED FOR GOOD", text);
        Assert.DoesNotContain("UNBOUND", text);
        Assert.Contains("LGPO.exe NOT FOUND", text);
    }

    [Fact]
    public void PreUpdate_summary_needs_no_typed_confirmation()
    {
        Assert.False(ConfirmationSummaryBuilder.Build(Profile.WO7, Role.Display, EnginePhase.PreUpdate, new EngineOptions(), true).RequiresTypedConfirmation);
    }

    [Theory]
    [InlineData("=== Power plan", LineKind.StepHeader)]
    [InlineData("  [OK]   SearchOrderConfig = 0", LineKind.Ok)]
    [InlineData("  [WARN] Tamper Protection is ON", LineKind.Warning)]
    [InlineData("  [SET]     Hibernation off", LineKind.Set)]
    [InlineData("  [NOT SET] x (current: 1)", LineKind.NotSet)]
    [InlineData("  [N/A]     x (-KeepFirewall)", LineKind.NotApplicable)]
    [InlineData("[FATAL] LGPO import failed", LineKind.Fatal)]
    [InlineData("Ok.", LineKind.Text)]
    public void Console_lines_are_classified_by_prefix(string line, LineKind kind) =>
        Assert.Equal(kind, EngineOutputParser.Classify(line));

    [Fact]
    public void Result_file_writer_warning_is_not_counted()
    {
        Assert.Equal(1, EngineOutputParser.CountWarnings(["  [WARN] real", "  [WARN] Result file not written: denied"]));
    }

    [Fact]
    public void Result_file_schema_2_is_read()
    {
        const string json = """
        {
          "schemaVersion": 2, "script": "WO7-Setup.ps1", "phase": "PostInstall", "mode": "Audit",
          "status": "Completed", "fatal": null, "warnings": [ "w1" ],
          "backups": [ { "Kind": "LgpoBackup", "Path": "C:\\b", "Restore": "LGPO.exe /g \"C:\\b\\{G}\"" } ],
          "audit": [ { "Section": "Power plan", "Item": "Hibernation off", "State": "Set", "Detail": "" },
                     { "Section": "Power plan", "Item": "x", "State": "NotSet", "Detail": "current: 1" } ],
          "parameters": { "Phase": "PostInstall", "KeepService": [] }
        }
        """;
        var r = EngineResult.Parse(json);
        Assert.Equal("Audit", r.Mode);
        Assert.Equal(1, r.AuditCount("NotSet"));
        Assert.Equal("LgpoBackup", r.Backups[0].Kind);
        Assert.False(r.Failed);
    }

    [Fact]
    public void Result_file_schema_1_is_read_as_an_apply_run()
    {
        var r = EngineResult.Parse("""{ "schemaVersion": 1, "phase": "PreUpdate", "status": "Completed", "warnings": [] }""");
        Assert.Equal("Apply", r.Mode);
        Assert.Empty(r.Audit);
    }
}
