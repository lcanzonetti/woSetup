using System.IO;
using System.Runtime.InteropServices;
using WOSetup.Core.Actions;
using WOSetup.Core.Checks;
using WOSetup.Core.Engine;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.App.Services;

/// <summary>One finished run of WO7-Setup.ps1 / WO6-Setup.ps1 (real or audit).</summary>
public sealed record ScriptRun(RunRecord Run, string Folder, int? Exit, EngineResult? Result, StepStatus Status, List<string> Warnings);

/// <summary>
/// Runs one phase of the setup script in its own run folder and records it.
/// A real run goes through BeginRun/RecordRun (the caller finishes the step);
/// an audit used as a check is only recorded (BeginAudit) and never changes
/// a step's status by itself.
/// </summary>
public sealed class ScriptRunner(AppPaths paths, EngineWorkspace workspace, PowerShellRunner runner, FileLogger log)
{
    public async Task<ScriptRun> RunAsync(WizardSession session, string stepId, EnginePhase phase, bool audit,
                                          Action<string, bool> onLine, CancellationToken ct)
    {
        var profile = session.Flow.Profile;
        var options = session.State.Options.Clone();
        var folder = workspace.Create(session.State, session.Flow.Script, phase.ToString(), audit, DateTimeOffset.Now);
        var parameters = ScriptArgumentBuilder.Build(profile, session.State.Role, phase, options, audit, folder.ResultPath);
        EngineWorkspace.WriteParams(folder, parameters);
        var commandLine = ScriptArgumentBuilder.CommandLine(session.Flow.Script, parameters);
        var run = new RunRecord
        {
            RunId = Path.GetFileName(folder.Path),
            Script = session.Flow.Script,
            Phase = phase.ToString(),
            Audit = audit,
            CommandLine = commandLine,
            Folder = paths.Relative(folder.Path),
            ScriptSha256 = folder.ScriptSha256,
            LgpoBundled = EngineWorkspace.LgpoBundled,
            StartedAt = DateTimeOffset.Now,
        };
        if (audit) session.BeginAudit(stepId, run);
        else session.BeginRun(stepId, run);
        log.Log($"{stepId}: start {commandLine} in {folder.Path}");
        onLine($"> {commandLine}", false);

        var lines = new List<string>();
        var exit = await runner.RunAsync(folder, (line, isError) =>
        {
            lock (lines) lines.Add(line);
            onLine(line, isError);
        }, ct);

        EngineResult? result = null;
        string? parseWarning = null;
        if (File.Exists(folder.ResultPath))
        {
            try { result = EngineResult.Parse(await File.ReadAllTextAsync(folder.ResultPath, CancellationToken.None)); }
            catch (Exception ex) { parseWarning = $"The result file could not be read: {ex.Message}"; }
        }
        int consoleWarnings;
        lock (lines) consoleWarnings = EngineOutputParser.CountWarnings(lines);
        var (status, warnings) = WizardSession.Evaluate(audit, exit, result, consoleWarnings);
        if (parseWarning is not null) warnings.Insert(0, parseWarning);
        session.RecordRun(run, result, status, warnings);
        log.Log($"{stepId}: {phase} {(audit ? "audit" : "run")} ended, exit {exit?.ToString() ?? "cancelled"}, {status}, {warnings.Count} warning(s)");
        return new ScriptRun(run, folder.Path, exit, result, status, warnings);
    }
}

/// <summary>Outcome of a batch of checks.</summary>
public sealed record CheckRun(List<CheckResult> Results, Dictionary<EnginePhase, EngineResult?> Audits, List<string> Folders, bool Cancelled);

/// <summary>
/// Runs every check a set of steps needs: native ones in-process, the rest
/// with Engine/WO-Checks.ps1 in one PowerShell session, plus the setup
/// script's -Audit for the phases needed. All read-only.
/// </summary>
public sealed class CheckService(EngineWorkspace workspace, PowerShellRunner runner, ScriptRunner scripts, FileLogger log)
{
    public async Task<CheckRun> RunAsync(WizardSession session, IEnumerable<StepDefinition> steps, string recordAs,
                                         Action<string, bool> onLine, CancellationToken ct)
    {
        var plan = new CheckPlan(steps);
        var byCheck = new Dictionary<string, CheckResult>();
        var audits = new Dictionary<EnginePhase, EngineResult?>();
        var folders = new List<string>();

        foreach (var id in plan.Native)
        {
            byCheck[id] = NativeChecks.Run(id);
            onLine($"  [check] {id}: {byCheck[id].State}", false);
        }

        if (plan.ScriptChecks.Count > 0)
        {
            var f = workspace.CreateHelper(session.State, "WO-Checks.ps1", "Checks", DateTimeOffset.Now);
            folders.Add(f.Path);
            EngineWorkspace.WriteJson(f.ParamsPath, CheckContext.Build(session.Flow.Profile, session.State.Role, session.State.Options));
            onLine($"> WO-Checks.ps1 ({plan.ScriptChecks.Count} checks)", false);
            var exit = await runner.RunHelperAsync(f,
                ["-Ids", string.Join(",", plan.ScriptChecks), "-ParamsJson", f.ParamsPath, "-ResultPath", f.ResultPath], onLine, ct);
            if (exit is null) return new CheckRun(plan.ForSteps(byCheck, audits), audits, folders, Cancelled: true);
            if (File.Exists(f.ResultPath))
            {
                try
                {
                    foreach (var r in CheckResult.ParseMany(await File.ReadAllTextAsync(f.ResultPath, CancellationToken.None)))
                        byCheck[r.Id] = r;
                }
                catch (Exception ex) { onLine($"[WARN] The check results could not be read: {ex.Message}", true); }
            }
            else onLine($"[WARN] WO-Checks.ps1 wrote no result (exit code {exit}). See {f.StderrPath}.", true);
            log.Log($"Checks ({string.Join(",", plan.ScriptChecks)}) ran in {f.Path}, exit {exit}");
        }

        foreach (var phase in plan.AuditPhases)
        {
            var run = await scripts.RunAsync(session, recordAs, phase, audit: true, onLine, ct);
            folders.Add(run.Folder);
            if (run.Exit is null) return new CheckRun(plan.ForSteps(byCheck, audits), audits, folders, Cancelled: true);
            audits[phase] = run.Result;
        }
        return new CheckRun(plan.ForSteps(byCheck, audits), audits, folders, Cancelled: false);
    }
}

/// <summary>Outcome of one wizard action (Engine/WO-Actions.ps1).</summary>
public sealed record ActionRun(int? Exit, ActionResult? Result, string Folder, string? Error)
{
    public bool Ok => Exit == 0 && Result is { Failed: false };
}

/// <summary>Runs Engine/WO-Actions.ps1: the owner-approved actions and the two read-only queries.</summary>
public sealed class ActionService(EngineWorkspace workspace, PowerShellRunner runner, FileLogger log)
{
    public async Task<ActionRun> RunAsync(WizardState state, string action, object? input, Action<string, bool> onLine, CancellationToken ct)
    {
        var f = workspace.CreateHelper(state, "WO-Actions.ps1", $"Action_{action}", DateTimeOffset.Now);
        var args = new List<string> { "-Action", action, "-ResultPath", f.ResultPath };
        if (input is not null)
        {
            EngineWorkspace.WriteJson(f.ParamsPath, input);
            args.AddRange(["-ParamsJson", f.ParamsPath]);
        }
        var exit = await runner.RunHelperAsync(f, args, onLine, ct);
        ActionResult? result = null;
        string? error = null;
        if (File.Exists(f.ResultPath))
        {
            try { result = ActionResult.Parse(await File.ReadAllTextAsync(f.ResultPath, CancellationToken.None)); }
            catch (Exception ex) { error = $"The result file could not be read: {ex.Message}"; }
        }
        else if (exit is not null) error = $"The action wrote no result (exit code {exit}). See {f.StderrPath}.";
        log.Log($"Action {action} in {f.Path}: exit {exit?.ToString() ?? "cancelled"}, {result?.Status ?? "no result"}");
        return new ActionRun(exit, result, f.Path, error);
    }
}

/// <summary>Checks the wizard does itself.</summary>
public static class NativeChecks
{
    public static CheckResult Run(string id)
    {
        try
        {
            return id switch
            {
                "lgpo" => Lgpo(),
                "display-scale" => DisplayScale(),
                _ => new CheckResult(id, CheckState.CantCheck, $"Unknown native check '{id}'."),
            };
        }
        catch (Exception ex)
        {
            return new CheckResult(id, CheckState.CantCheck, $"The check failed: {ex.Message}");
        }
    }

    private static CheckResult Lgpo() => EngineWorkspace.LgpoAvailable
        ? new CheckResult("lgpo", CheckState.Done, $"LGPO.exe {EngineWorkspace.LgpoSource}.")
        : new CheckResult("lgpo", CheckState.NotDone,
            "LGPO.exe is neither bundled nor next to the wizard exe. The scripts then write the policy values straight to the registry " +
            "(gpedit.msc will not show them). Put LGPO.exe next to the exe, or skip this step.");

    /// <summary>
    /// 100 % scale = 96 DPI. The wizard is per-monitor DPI aware
    /// (app.manifest), so Windows reports each monitor's real DPI.
    /// </summary>
    private static CheckResult DisplayScale()
    {
        var monitors = new List<(string Name, uint Dpi)>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, _, _, _) =>
        {
            var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            GetMonitorInfo(h, ref info);
            var hr = GetDpiForMonitor(h, 0 /* MDT_EFFECTIVE_DPI */, out var dpiX, out _);
            monitors.Add((info.szDevice.Replace(@"\\.\", ""), hr == 0 ? dpiX : 0));
            return true;
        }, IntPtr.Zero);
        if (monitors.Count == 0) return new CheckResult("display-scale", CheckState.CantCheck, "No monitor found.");
        var text = string.Join(", ", monitors.Select(m => m.Dpi == 0 ? $"{m.Name} ?" : $"{m.Name} {m.Dpi * 100 / 96} %"));
        if (monitors.Any(m => m.Dpi == 0)) return new CheckResult("display-scale", CheckState.CantCheck, $"Could not read every monitor: {text}.");
        return monitors.All(m => m.Dpi == 96)
            ? new CheckResult("display-scale", CheckState.Done, $"All outputs at 100 %: {text}.")
            : new CheckResult("display-scale", CheckState.NotDone, $"Not every output is at 100 %: {text}.");
    }

    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
}

/// <summary>Guesses the profile for the start screen from what is installed. Only a suggestion.</summary>
public static class ProfileDetector
{
    public static (Profile? Profile, string Text) Detect()
    {
        try
        {
            var names = new List<string>();
            foreach (var root in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(root);
                if (key is null) continue;
                foreach (var sub in key.GetSubKeyNames())
                {
                    using var k = key.OpenSubKey(sub);
                    if (k?.GetValue("DisplayName") is string n && n.Contains("WATCHOUT", StringComparison.OrdinalIgnoreCase))
                        names.Add($"{n} {k.GetValue("DisplayVersion")}".Trim());
                }
            }
            var wo6Exe = new[] { @"C:\WATCHOUT 6", @"D:\WATCHOUT 6", @"D:\WATCHOUT" }
                .Any(d => File.Exists(Path.Combine(d, "WATCHPOINT.exe")) || File.Exists(Path.Combine(d, "WATCHMAKER.exe")));
            // [Uncertain] the WATCHOUT 7 installer's program name and version format.
            var has7 = names.Any(n => System.Text.RegularExpressions.Regex.IsMatch(n, @"\b7(\.|\b)"));
            var has6 = wo6Exe || names.Any(n => System.Text.RegularExpressions.Regex.IsMatch(n, @"\b6(\.|\b)"));
            if (has7 && !has6) return (Profile.WO7, $"Found {string.Join(", ", names)}: WATCHOUT 7 suggested.");
            if (has6 && !has7) return (Profile.WO6, "WATCHOUT 6 found on this machine: WATCHOUT 6 suggested.");
            if (has6 && has7) return (null, $"Both WATCHOUT 6 and 7 seem installed ({string.Join(", ", names)}). Choose the profile.");
            return (null, "No WATCHOUT installation found (normal before section 5). Choose the profile.");
        }
        catch (Exception ex)
        {
            return (null, $"Could not look for WATCHOUT: {ex.Message}");
        }
    }
}
