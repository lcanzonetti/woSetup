using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Data;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using WOSetup.App.Services;
using WOSetup.Core.Engine;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.App.ViewModels;

public sealed record LogLine(string Text, LineKind Kind);

/// <summary>
/// The wizard window. Rules live in WizardSession (Core); this class turns
/// button presses into session calls and keeps the screen in sync.
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly AppPaths _paths;
    private readonly JsonStateStore _store;
    private readonly FileLogger _log;
    private readonly IDialogService _dialogs;
    private readonly EngineWorkspace _workspace;
    private readonly PowerShellRunner _runner = new();
    private CancellationTokenSource? _cts;

    public MainViewModel(AppPaths paths, JsonStateStore store, FileLogger log, IDialogService dialogs)
    {
        _paths = paths;
        _store = store;
        _log = log;
        _dialogs = dialogs;
        _workspace = new EngineWorkspace(paths);
        StepsView = CollectionViewSource.GetDefaultView(Steps);
        StepsView.GroupDescriptions.Add(new PropertyGroupDescription(nameof(StepItemViewModel.SectionTitle)));
    }

    // ------------------------------------------------------------ start screen

    [ObservableProperty] private bool _isStartScreen = true;
    [ObservableProperty] private Profile _startProfile = Profile.WO7;
    [ObservableProperty] private Role _startRole = Role.Display;
    public IReadOnlyList<Profile> Profiles { get; } = [Profile.WO7, Profile.WO6];
    public IReadOnlyList<Role> Roles { get; } = [Role.Display, Role.Production];

    public string LgpoStatus => EngineWorkspace.LgpoAvailable
        ? $"LGPO.exe: {EngineWorkspace.LgpoSource}."
        : "LGPO.exe: not found (not bundled, not next to the wizard). The scripts will write policies straight to the registry.";

    public string EnvironmentStatus =>
        (SystemInfo.IsElevated ? "Running as administrator." : "NOT running as administrator.") + " " +
        (PowerShellRunner.Available ? "Windows PowerShell 5.1 found." : "Windows PowerShell 5.1 NOT found.");

    public string DataFolder => _paths.Root;

    /// <summary>Called at start with whatever state.json held.</summary>
    public void Initialise(StateLoadResult loaded)
    {
        if (loaded.Warning is not null) Banner = loaded.Warning;
        if (loaded.State is null) return;
        OpenSession(loaded.State);
        Session!.MarkInterruptedRuns();
        var confirmed = Session.ConfirmReboot(SystemInfo.BootTime);
        if (confirmed is not null)
        {
            _log.Log($"Restart confirmed for {confirmed}");
            Banner = $"Restart confirmed: step {confirmed} is done.";
        }
        else if (Session.State.PendingReboot is { } p)
        {
            Banner = $"Step {p.StepId} is waiting for a restart. Windows has not restarted since " +
                     $"{p.RequestedAt:yyyy-MM-dd HH:mm}. Restart, then start the wizard again.";
        }
        RefreshAll();
        GoToCurrent();
    }

    [RelayCommand]
    private void Start()
    {
        var flow = FlowLoader.Load(StartProfile);
        var state = WizardSession.CreateState(flow, StartRole, Environment.MachineName, SystemInfo.UserName,
                                              SystemInfo.WizardVersion, DateTimeOffset.Now);
        _store.Save(state);
        _log.MoveTo(Path.Combine(_paths.MachineLogs(state), "wizard.log"));
        _log.Log($"New build started: {StartProfile}, {StartRole}, user {SystemInfo.UserName}, wizard {SystemInfo.WizardVersion}");
        OpenSession(state);
        GoToCurrent();
    }

    private void OpenSession(WizardState state)
    {
        var flow = FlowLoader.Load(state.Profile);
        Session = new WizardSession(flow, state, _store);
        _log.MoveTo(Path.Combine(_paths.MachineLogs(state), "wizard.log"));
        Steps.Clear();
        foreach (var step in flow.AllSteps) Steps.Add(new StepItemViewModel(step, Session));
        IsStartScreen = false;
        OnPropertyChanged(nameof(HeaderText));
        RefreshAll();
    }

    // ---------------------------------------------------------------- wizard

    [ObservableProperty, NotifyPropertyChangedFor(nameof(HeaderText), nameof(ProgressText))]
    private WizardSession? _session;

    public ObservableCollection<StepItemViewModel> Steps { get; } = [];
    public ICollectionView StepsView { get; }

    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasSelection), nameof(CommandPreview), nameof(HasCommandPreview))]
    private StepItemViewModel? _selectedStep;

    public bool HasSelection => SelectedStep is not null && !IsOptionsVisible;

    // Picking a step in the rail closes the options page.
    partial void OnSelectedStepChanged(StepItemViewModel? value) => IsOptionsVisible = false;

    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasBanner))] private string? _banner;
    public bool HasBanner => !string.IsNullOrEmpty(Banner);

    public string HeaderText => Session is null
        ? "WATCHOUT Server Setup Wizard"
        : $"{Session.Flow.Title}  ·  {Session.State.Role}  ·  {Session.State.Machine.ComputerNameAtStart}" +
          (Session.State.FinishedAt is { } f ? $"  ·  finished {f:yyyy-MM-dd}" : "");

    public string ProgressText => Session is null ? "" :
        $"{Session.CountFinished()} of {Steps.Count} steps finished";

    [RelayCommand] private void DismissBanner() => Banner = null;

    [RelayCommand]
    private void GoToCurrent()
    {
        if (Session is null) return;
        var current = Session.CurrentStep;
        SelectedStep = current is null ? Steps.LastOrDefault() : Steps.FirstOrDefault(s => s.Id == current.Id);
        IsOptionsVisible = false;
    }

    private void RefreshAll()
    {
        foreach (var s in Steps) s.Refresh();
        OnPropertyChanged(nameof(ProgressText));
        OnPropertyChanged(nameof(HeaderText));
        OnPropertyChanged(nameof(CommandPreview));
    }

    private void AfterChange(bool advance)
    {
        RefreshAll();
        if (advance) GoToCurrent();
    }

    // ------------------------------------------------------------ manual

    [RelayCommand]
    private void MarkDone()
    {
        if (SelectedStep is not { } s || Session is null || IsRunning) return;
        Session.MarkDone(s.Id, s.NotAutomatedYet ? "Marked done by the operator (check run by hand)." : null);
        _log.Log($"{s.Id} marked done");
        AfterChange(advance: true);
    }

    [RelayCommand]
    private void Skip()
    {
        if (SelectedStep is not { } s || Session is null || IsRunning) return;
        var reason = _dialogs.Prompt("Skip step", $"Why is \"{s.Id}\" skipped? The reason goes into the build record.");
        if (reason is null) return;
        Session.Skip(s.Id, reason);
        _log.Log($"{s.Id} skipped: {reason}");
        AfterChange(advance: true);
    }

    [RelayCommand]
    private void NotApplicable()
    {
        if (SelectedStep is not { } s || Session is null || IsRunning) return;
        var reason = _dialogs.Prompt("Not applicable", $"Why does \"{s.Id}\" not apply to this machine (e.g. no AMD RAID)?");
        if (reason is null) return;
        Session.SetNotApplicable(s.Id, reason);
        _log.Log($"{s.Id} not applicable: {reason}");
        AfterChange(advance: true);
    }

    [RelayCommand]
    private void ResetStep()
    {
        if (SelectedStep is not { } s || Session is null || IsRunning) return;
        Session.Reset(s.Id);
        _log.Log($"{s.Id} reset");
        AfterChange(advance: false);
    }

    [RelayCommand]
    private void Open(string? target)
    {
        if (string.IsNullOrEmpty(target)) return;
        try { ShellLauncher.Open(target); }
        catch (Exception ex) { _dialogs.Error("Could not open", $"{target}: {ex.Message}"); }
    }

    // ------------------------------------------------------------ restarts

    /// <summary>Reboot step: remember the boot time, then restart (or let the operator restart).</summary>
    [RelayCommand]
    private void RestartForStep(string? mode)
    {
        if (SelectedStep is not { IsRebootStep: true } s || Session is null || IsRunning) return;
        Session.RequestReboot(s.Id, SystemInfo.BootTime);
        _log.Log($"{s.Id}: restart requested ({mode})");
        RefreshAll();
        if (mode == "now")
        {
            if (!_dialogs.Confirm("Restart Windows", "Windows will restart in 10 seconds.",
                    ["After the restart, sign in with the show account and start WOSetupWizard.exe from the USB stick again.",
                     "The wizard will confirm the restart and continue with the next step."], null, "Restart now"))
                return;
            TryRestart();
        }
        else
        {
            _dialogs.Info("Restart", "Restart Windows when you are ready, then start WOSetupWizard.exe again from the USB stick.\n" +
                                     "The wizard confirms the restart and continues.");
        }
    }

    /// <summary>Steps that mention a restart (Windows Update, driver installers): restart without changing the step.</summary>
    [RelayCommand]
    private void RestartOnly()
    {
        if (IsRunning) return;
        if (!_dialogs.Confirm("Restart Windows", "Windows will restart in 10 seconds.",
                ["This step stays as it is. After the restart, start WOSetupWizard.exe again and mark it done when finished."],
                null, "Restart now"))
            return;
        TryRestart();
    }

    private void TryRestart()
    {
        try { ShellLauncher.Restart(); }
        catch (Exception ex) { _dialogs.Error("Restart", $"Could not start the restart: {ex.Message}"); }
    }

    // ------------------------------------------------------------ finish

    [RelayCommand]
    private void Finish()
    {
        if (SelectedStep is not { IsFinish: true } s || Session is null) return;
        var open = Session.UnfinishedBefore(s.Id);
        if (open.Count > 0 && !_dialogs.Confirm("Finish", $"{open.Count} step(s) are not finished:",
                open.Take(12).Select(x => $"{x.Id}  {x.Title}").ToList(), null, "Finish anyway"))
            return;
        Session.Finish(s.Id);
        _log.Log("Build marked finished");
        AfterChange(advance: false);
        ExportBundle();
    }

    // ------------------------------------------------------------ options

    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasSelection))] private bool _isOptionsVisible;
    [ObservableProperty] private OptionsViewModel? _options;

    [RelayCommand]
    private void ShowOptions()
    {
        if (Session is null) return;
        Options = new OptionsViewModel(Session.Flow.Profile, Session.State.Role, Session.State.Options, Session.PostInstallHasRun);
        IsOptionsVisible = true;
    }

    [RelayCommand]
    private void SaveOptions()
    {
        if (Session is null || Options is null) return;
        if (Options.Errors.Count > 0)
        {
            _dialogs.Error("Options", string.Join("\n", Options.Errors));
            return;
        }
        if (Options.Role != Session.State.Role) Session.ChangeRole(Options.Role);
        Session.SaveOptions(Options.ToOptions());
        _log.Log($"Options saved: {Options.Preview}");
        IsOptionsVisible = false;
        RefreshAll();
    }

    [RelayCommand] private void CloseOptions() => IsOptionsVisible = false;

    /// <summary>The exact command the selected engine step will run.</summary>
    public string CommandPreview
    {
        get
        {
            if (Session is null || SelectedStep?.Step.Engine is not { } e) return "";
            var phases = e.Phase == EnginePhase.Both ? new[] { EnginePhase.PostInstall, EnginePhase.PreUpdate } : [e.Phase];
            return string.Join("\n", phases.Select(ph => ScriptArgumentBuilder.CommandLine(Session.Flow.Script,
                ScriptArgumentBuilder.Build(Session.Flow.Profile, Session.State.Role, ph, Session.State.Options, e.Audit, null))));
        }
    }

    public bool HasCommandPreview => CommandPreview.Length > 0;

    // ------------------------------------------------------------ script runs

    [ObservableProperty, NotifyPropertyChangedFor(nameof(IsNotRunning))] private bool _isRunning;
    public bool IsNotRunning => !IsRunning;
    [ObservableProperty] private string _runStatus = "";
    [ObservableProperty] private string? _lastRunFolder;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(VisibleAuditRows))] private bool _showOnlyNotSet;
    public ObservableCollection<LogLine> LogLines { get; } = [];
    public ObservableCollection<AuditEntry> AuditRows { get; } = [];
    public IEnumerable<AuditEntry> VisibleAuditRows => ShowOnlyNotSet ? AuditRows.Where(a => a.State == "NotSet") : AuditRows;
    public bool HasAuditRows => AuditRows.Count > 0;
    public bool HasRunOutput => LogLines.Count > 0 || IsRunning;

    [RelayCommand] private Task Run() => RunEngineAsync(audit: false);

    /// <summary>Audit step, or "Audit first" on a real-run step: read-only.</summary>
    [RelayCommand] private Task Audit() => RunEngineAsync(audit: true);

    [RelayCommand]
    private void Cancel()
    {
        if (!IsRunning || _cts is null) return;
        if (_dialogs.Confirm("Stop the script", "Stop the running script now?",
                ["Changes already made stay in place.", "Running the step again with the same options is safe (the scripts are idempotent)."],
                null, "Stop"))
            _cts.Cancel();
    }

    private async Task RunEngineAsync(bool audit)
    {
        if (Session is null || SelectedStep?.Step.Engine is not { } engine || IsRunning) return;
        var item = SelectedStep;
        var step = item.Step;
        var profile = Session.Flow.Profile;
        var role = Session.State.Role;
        var options = Session.State.Options.Clone();
        var phases = engine.Phase == EnginePhase.Both ? new[] { EnginePhase.PostInstall, EnginePhase.PreUpdate } : [engine.Phase];

        if (!PowerShellRunner.Available)
        {
            _dialogs.Error("Windows PowerShell", $"Windows PowerShell 5.1 was not found at {PowerShellRunner.PowerShellPath}.");
            return;
        }
        var errors = OptionsValidator.Validate(profile, options);
        if (errors.Count > 0)
        {
            _dialogs.Error("Options", "Fix the options first:\n" + string.Join("\n", errors));
            return;
        }

        if (!audit)
        {
            // Checklist order (AGENTS.md rule 1): warn, and let the operator decide.
            var open = Session.UnfinishedBefore(step.Id);
            if (open.Count > 0 && !_dialogs.Confirm("Earlier steps not finished",
                    $"{open.Count} earlier step(s) are not finished. The order matters (PreUpdate before any driver and " +
                    "before the cable is plugged in; PostInstall after updates, drivers, WinUtil and the WATCHOUT install).",
                    open.Take(12).Select(x => $"{x.Id}  {x.Title}").Append(open.Count > 12 ? $"... and {open.Count - 12} more" : "")
                        .Where(x => x.Length > 0).ToList(),
                    null, "Run anyway"))
                return;

            // Show before changing (AGENTS.md rule 3).
            var summary = ConfirmationSummaryBuilder.Build(profile, role, engine.Phase, options, EngineWorkspace.LgpoAvailable);
            var command = ScriptArgumentBuilder.CommandLine(Session.Flow.Script,
                ScriptArgumentBuilder.Build(profile, role, engine.Phase, options, false, null));
            if (!_dialogs.Confirm(summary.Title, $"This will run:  {command}",
                    summary.Lines, summary.RequiresTypedConfirmation ? "APPLY" : null, "Run"))
                return;
        }

        IsRunning = true;
        LogLines.Clear();
        AuditRows.Clear();
        OnPropertyChanged(nameof(HasAuditRows));
        OnPropertyChanged(nameof(VisibleAuditRows));
        OnPropertyChanged(nameof(HasRunOutput));
        _cts = new CancellationTokenSource();
        var worst = StepStatus.Done;
        var allWarnings = new List<string>();
        var dispatcher = Application.Current.Dispatcher;
        try
        {
            foreach (var phase in phases)
            {
                var folder = _workspace.Create(Session.State, Session.Flow.Script, phase.ToString(), audit, DateTimeOffset.Now);
                var parameters = ScriptArgumentBuilder.Build(profile, role, phase, options, audit, folder.ResultPath);
                EngineWorkspace.WriteParams(folder, parameters);
                var commandLine = ScriptArgumentBuilder.CommandLine(Session.Flow.Script, parameters);
                var run = new RunRecord
                {
                    RunId = Path.GetFileName(folder.Path),
                    Script = Session.Flow.Script,
                    Phase = phase.ToString(),
                    Audit = audit,
                    CommandLine = commandLine,
                    Folder = _paths.Relative(folder.Path),
                    ScriptSha256 = folder.ScriptSha256,
                    LgpoBundled = EngineWorkspace.LgpoBundled,
                    StartedAt = DateTimeOffset.Now,
                };
                Session.BeginRun(step.Id, run);
                item.Refresh();
                LastRunFolder = folder.Path;
                RunStatus = $"Running {commandLine}";
                _log.Log($"{step.Id}: start {commandLine} in {folder.Path}");
                LogLines.Add(new LogLine($"> {commandLine}", LineKind.StepHeader));

                var lines = new List<string>();
                var exit = await _runner.RunAsync(folder, (line, isError) =>
                {
                    lock (lines) lines.Add(line);
                    var kind = isError ? LineKind.Error : EngineOutputParser.Classify(line);
                    dispatcher.BeginInvoke(() => LogLines.Add(new LogLine(line, kind)));
                }, _cts.Token);

                EngineResult? result = null;
                var parseWarning = (string?)null;
                if (File.Exists(folder.ResultPath))
                {
                    try { result = EngineResult.Parse(await File.ReadAllTextAsync(folder.ResultPath)); }
                    catch (Exception ex) { parseWarning = $"The result file could not be read: {ex.Message}"; }
                }
                int consoleWarnings;
                lock (lines) consoleWarnings = EngineOutputParser.CountWarnings(lines);
                var (status, warnings) = WizardSession.Evaluate(audit, exit, result, consoleWarnings);
                if (parseWarning is not null) warnings.Insert(0, parseWarning);
                Session.RecordRun(run, result, status, warnings);
                _log.Log($"{step.Id}: {phase} {(audit ? "audit" : "run")} ended, exit {exit?.ToString() ?? "cancelled"}, {status}, {warnings.Count} warning(s)");

                if (result is not null)
                    foreach (var a in result.Audit) AuditRows.Add(a);
                allWarnings.AddRange(phases.Length > 1 ? warnings.Select(w => $"{phase}: {w}") : warnings);
                worst = Worse(worst, status);
                if (status is StepStatus.Failed or StepStatus.Interrupted) break;
            }
        }
        catch (Exception ex)
        {
            worst = StepStatus.Failed;
            allWarnings.Add($"The wizard could not run the script: {ex.Message}");
            _log.Log($"{step.Id}: wizard error {ex}");
        }
        finally
        {
            Session.FinishStep(step.Id, worst, allWarnings);
            IsRunning = false;
            _cts.Dispose();
            _cts = null;
            OnPropertyChanged(nameof(HasAuditRows));
            OnPropertyChanged(nameof(VisibleAuditRows));
            OnPropertyChanged(nameof(HasRunOutput));
            RunStatus = audit
                ? $"Audit finished: {AuditRows.Count(a => a.State == "Set")} set, {AuditRows.Count(a => a.State == "NotSet")} not set, " +
                  $"{AuditRows.Count(a => a.State == "NA")} not applicable. Nothing was changed."
                : $"Finished: {item.StatusText}." + (allWarnings.Count > 0 ? $" {allWarnings.Count} warning(s), see above." : "");
            RefreshAll();
        }
    }

    private static StepStatus Worse(StepStatus a, StepStatus b)
    {
        static int Rank(StepStatus s) => s switch
        {
            StepStatus.Done => 0,
            StepStatus.DoneWithWarnings => 1,
            StepStatus.Interrupted => 2,
            _ => 3,
        };
        return Rank(b) > Rank(a) ? b : a;
    }

    [RelayCommand]
    private void OpenRunFolder()
    {
        if (LastRunFolder is not null) ShellLauncher.OpenFolder(LastRunFolder);
    }

    // ------------------------------------------------------------ tools

    [RelayCommand]
    private void OpenLogs()
    {
        if (Session is null) ShellLauncher.OpenFolder(_paths.Root);
        else ShellLauncher.OpenFolder(_paths.MachineLogs(Session.State));
    }

    [RelayCommand]
    private void ExportBundle()
    {
        if (Session is null) return;
        var file = _dialogs.SaveFile("Save support bundle",
            $"WOSetup_{Session.State.Machine.LogFolderName}_{DateTime.Now:yyyyMMdd_HHmm}.zip", "Zip file (*.zip)|*.zip");
        if (file is null) return;
        try
        {
            SupportBundle.Create(_paths, Session.State, file);
            _log.Log($"Support bundle saved to {file}");
            _dialogs.Info("Support bundle", $"Saved:\n{file}");
        }
        catch (Exception ex)
        {
            _dialogs.Error("Support bundle", $"Could not save the bundle: {ex.Message}");
        }
    }

    [RelayCommand]
    private void StartOver()
    {
        if (Session is null || IsRunning) return;
        if (!_dialogs.Confirm("Start over", "Start a new build on this machine?",
                ["The current progress is kept as a file next to state.json (state_<date>.json.old), with all logs and backups.",
                 "Nothing on the machine is undone: settings the scripts applied stay applied.",
                 "Use this to choose another profile (WATCHOUT 6 / 7)."], "START OVER", "Start over"))
            return;
        var archived = _store.Archive(DateTimeOffset.Now);
        _log.Log($"Started over; previous state kept as {archived}");
        Session = null;
        Steps.Clear();
        SelectedStep = null;
        LogLines.Clear();
        AuditRows.Clear();
        IsStartScreen = true;
    }
}
