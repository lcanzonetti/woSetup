using System.Text;
using System.Text.RegularExpressions;
using WOSetup.Core.Flow;

namespace WOSetup.Core.Options;

public enum DefenderMode { Off, Exclusions, Skip }

/// <summary>
/// Script options, 1:1 with the parameters of WO7-Setup.ps1 / WO6-Setup.ps1
/// (AGENTS.md "Options"). Defaults are the scripts' defaults. -Role lives in
/// the wizard state because it also decides which steps apply.
/// </summary>
public sealed class EngineOptions
{
    // Both scripts
    public DefenderMode DefenderMode { get; set; } = DefenderMode.Off;
    public bool KeepFirewall { get; set; }
    public bool KeepUpdateService { get; set; }
    public string? WatchoutPath { get; set; }

    // WO7 only
    public string? WorkingDirectory { get; set; }

    // WO6 only
    public string? ShowsPath { get; set; }
    public int StartDelay { get; set; } = 8;
    public bool KeepServices { get; set; }
    public List<string> KeepService { get; set; } = [];
    public bool KeepAdapterBindings { get; set; }
    public bool ForcePcieLinkSpeed { get; set; }

    public EngineOptions Clone() => new()
    {
        DefenderMode = DefenderMode, KeepFirewall = KeepFirewall, KeepUpdateService = KeepUpdateService,
        WatchoutPath = WatchoutPath, WorkingDirectory = WorkingDirectory,
        ShowsPath = ShowsPath, StartDelay = StartDelay, KeepServices = KeepServices,
        KeepService = [.. KeepService], KeepAdapterBindings = KeepAdapterBindings,
        ForcePcieLinkSpeed = ForcePcieLinkSpeed,
    };
}

public static partial class OptionsValidator
{
    [GeneratedRegex(@"^[A-Za-z0-9_.\-]+$")] private static partial Regex ServiceNameRegex();

    /// <summary>Same limits as the scripts' parameter validation, plus obvious typos.</summary>
    public static IReadOnlyList<string> Validate(Profile profile, EngineOptions o)
    {
        var errors = new List<string>();
        if (profile == Profile.WO6)
        {
            if (o.StartDelay is < 0 or > 600) errors.Add("Start delay must be between 0 and 600 seconds.");
            foreach (var name in o.KeepService.Where(n => !ServiceNameRegex().IsMatch(n)))
                errors.Add($"'{name}' is not a valid service name.");
        }
        return errors;
    }
}

/// <summary>
/// Turns options into the parameter set passed to a script (via params.json
/// and the wrapper's splatting) and into the equivalent command line shown to
/// the operator.
/// </summary>
public static class ScriptArgumentBuilder
{
    /// <summary>Parameters in the order a person would type them.</summary>
    public static List<KeyValuePair<string, object>> Build(
        Profile profile, Role role, EnginePhase phase, EngineOptions o, bool audit, string? resultPath)
    {
        if (phase == EnginePhase.Both) throw new ArgumentException("Build one phase at a time.", nameof(phase));
        var p = new List<KeyValuePair<string, object>> { new("Phase", phase.ToString()) };
        void Add(string name, object value) => p.Add(new(name, value));
        void AddText(string name, string? value) { if (!string.IsNullOrWhiteSpace(value)) Add(name, value.Trim()); }

        // PreUpdate takes no options in either script.
        if (phase == EnginePhase.PostInstall)
        {
            if (role != Role.Display) Add("Role", role.ToString());
            if (o.DefenderMode != DefenderMode.Off) Add("DefenderMode", o.DefenderMode.ToString());
            if (o.KeepFirewall) Add("KeepFirewall", true);
            if (o.KeepUpdateService) Add("KeepUpdateService", true);
            AddText("WatchoutPath", o.WatchoutPath);
            if (profile == Profile.WO7)
            {
                AddText("WorkingDirectory", o.WorkingDirectory);
            }
            else
            {
                AddText("ShowsPath", o.ShowsPath);
                if (o.StartDelay != 8) Add("StartDelay", o.StartDelay);
                if (o.KeepServices) Add("KeepServices", true);
                var keep = o.KeepService.Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => s.Trim()).ToArray();
                if (keep.Length > 0) Add("KeepService", keep);
                if (o.KeepAdapterBindings) Add("KeepAdapterBindings", true);
                if (o.ForcePcieLinkSpeed) Add("ForcePcieLinkSpeed", true);
            }
        }
        if (audit) Add("Audit", true);
        if (resultPath is not null) Add("ResultPath", resultPath);
        return p;
    }

    /// <summary>What the operator would type in an elevated prompt (ResultPath left out).</summary>
    public static string CommandLine(string script, IEnumerable<KeyValuePair<string, object>> parameters)
    {
        var sb = new StringBuilder($".\\{script}");
        foreach (var (name, value) in parameters)
        {
            if (name == "ResultPath") continue;
            sb.Append(" -").Append(name);
            switch (value)
            {
                case bool b when b: break;                       // switch
                case string[] list: sb.Append(' ').Append(string.Join(',', list.Select(Quote))); break;
                default: sb.Append(' ').Append(Quote(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) ?? "")); break;
            }
        }
        return sb.ToString();
    }

    private static string Quote(string s) =>
        s.Length > 0 && s.All(c => char.IsLetterOrDigit(c) || c is '_' or '-' or '.' or ':' or '\\')
            ? s
            : "'" + s.Replace("'", "''") + "'";
}
