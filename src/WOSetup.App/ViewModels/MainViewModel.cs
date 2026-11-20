using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Net.NetworkInformation;
using System.Windows;
using System.Windows.Data;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using WOSetup.App.Services;
using WOSetup.Core.Actions;
using WOSetup.Core.Checks;
using WOSetup.Core.Engine;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.App.ViewModels;

public sealed record LogLine(string Text, LineKind Kind);

/// <summary>
/// The wizard window. Rules live in WizardSession (Core); this class turns
/// button presses into session calls, runs checks and actions, and keeps the
/// screen in sync.
///
/// Workflow (owner's redesign, Oct 2026):
///  * every step that can be checked is checked ("Check this machine"),
///    steps found done are marked done and the wizard jumps to what is missing;
///  * "Fix what's missing" walks the missing steps in checklist order: the
///    wizard performs automatic steps after a confirmation, and waits for the
///    operator on manual ones (Tamper Protection, WinUtil, drivers...).
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly AppPaths _paths;
    private readonly JsonStateStore _store;
    private readonly FileLogger _log;
    private readonly IDialogService _dialogs;
    private readonly ScriptRunner _scripts;
    private readonly CheckService _checks;
    private readonly ActionService _actions;
    private CancellationTokenSource? _cts;

    public MainViewModel(AppPaths paths, JsonStateStore store, FileLogger log, IDialogService dialogs)
    {
        _paths = paths;
        _store = store;
        _log = log;
        _dialogs = dialogs;
        var workspace = new EngineWorkspace(paths);
        var runner = new PowerShellRunner();
        _scripts = new ScriptRunner(paths, workspace, runner, log);
        _checks = new CheckService(workspace, runner, _scripts, log);
        _actions = new ActionService(workspace, runner, log);
        StepsView = CollectionViewSource.GetDefaultView(Steps);
        StepsView.GroupDescriptions.Add(new PropertyGroupDescription(nameof(StepItemViewModel.SectionTitle)));
    }

    // ------------------------------------------------------------ start screen

    [ObservableProperty] private bool _isStartScreen = true;
    [ObservableProperty] private Profile _startProfile = Profile.WO7;
    [ObservableProperty] private Role _startRole = Role.Display;
    public IReadOnlyList<Profile> Profiles { get; } = [Profile.WO7, Profile.WO6];
    public IReadOnlyList<Role> Roles { get; } = [Role.Display, Role.Production];

    /// <summary>Decision D (Oct 2026): the old "Before you start" section, kept as a short note.</summary>
    public IReadOnlyList<string> HaveReady { get; } =
    [
        "Windows 11 Pro 64-bit 24H2/25H2 installed, signed in with the show account (BIOS, RAID arrays and Windows Setup are done before the wizard).",
        "WATCHOUT 7: the 45 GB WO_RECOVERY partition for the factory image is created in Windows Setup (docs/PROJECT_CONTEXT.md section 2a).",
        "Network cable unplugged until PreUpdate has run (section 1).",
        "On the USB stick: NIC, chipset, storage/RAID and capture/audio drivers, the NVIDIA driver tested for your WATCHOUT release, WinUtil, the WATCHOUT installer.",
        "WATCHOUT 6: licence key (CodeMeter dongle). Plan the IP addresses of the show network.",
    ];

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
            Banner = $"Restart confirmed: step {confirmed} is done. Press \"Fix what's missing\" to continue.";
        }
        else if (Session.State.PendingReboot is { } p)
        {
            Banner = $"Step {p.StepId} is waiting for a restart. Windows has not restarted since " +
                     $"{p.RequestedAt:yyyy-MM-dd HH:mm}. Restart, then start the wizard again.";
        }
        RefreshAll();
        GoToCurrent();
    }

    [RelayCommand] private void Start() => StartNew();

    /// <summary>For a machine prepared earlier: start, then check everything at once.</summary>
    [RelayCommand]
    private async Task StartAndCheck()
    {
        StartNew();
        await CheckMachine();
    }

    private void StartNew()
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
        $"{Session.CountFinished()} of {Steps.Count} steps finished · {Session.MissingSteps().Count} missing";

    [RelayCommand] private void DismissBanner() => Banner = null;

    [RelayCommand]
    private void GoToCurrent()
    {
        if (Session is null) return;
        var current = Session.CurrentStep;
        Select(current?.Id);
        IsOptionsVisible = false;
    }

    private void Select(string? id) =>
        SelectedStep = id is null ? Steps.LastOrDefault() : Steps.FirstOrDefault(s => s.Id == id);

    private void RefreshAll()
    {
        foreach (var s in Steps) s.Refresh();
        OnPropertyChanged(nameof(ProgressText));
        OnPropertyChanged(nameof(HeaderText));
        OnPropertyChanged(nameof(CommandPreview));
    }

    private bool Busy()
    {
        if (!IsRunning) return false;
        _dialogs.Info("Busy", "Something is still running. Wait for it to finish, or press Stop.");
        return true;
    }

    // ------------------------------------------------------------ status changes

    /// <summary>
    /// The operator says the step is done. If the step has a quick check,
    /// it runs first; a "not done" answer needs an explicit "mark anyway"
    /// (never pretend, AGENTS.md rule 2).
    /// </summary>
    [RelayCommand]
    private async Task MarkDone()
    {
        if (SelectedStep is not { CanMarkDone: true } s || Session is null || Busy()) return;
        await MarkDoneAfterCheck(s.Step);
        RefreshAll();
        GoToCurrent();
    }

    /// <returns>True when the step ended up done.</returns>
    private async Task<bool> MarkDoneAfterCheck(StepDefinition step)
    {
        if (step.HasCheck && !step.IsAuditCheck)
        {
            var r = await CheckSteps([step], step.Id, showOutput: false);
            if (r is null) return false;
            var result = r.Results.Single();
            if (result.State == CheckState.Done) { _log.Log($"{step.Id} confirmed done by its check"); return true; }
            if (result.State == CheckState.NotDone &&
                !_dialogs.Confirm("The check disagrees", $"{step.Id}: the wizard's check says this is NOT done.",
                    [result.Detail, "Mark it done anyway only if you are sure the check is wrong for this machine (the build record keeps both)."],
                    null, "Mark done anyway"))
                return false;
            Session!.MarkDone(step.Id, result.State switch
            {
                CheckState.NotDone => $"Marked done by the operator although the check said: {result.Detail}",
                CheckState.CantCheck => $"Marked done by the operator ({result.Detail})",
                _ => null,
            });
        }
        else
        {
            Session!.MarkDone(step.Id);
        }
        _log.Log($"{step.Id} marked done");
        Session.ApplyAfterRules();
        return true;
    }

    [RelayCommand]
    private void Skip()
    {
        if (SelectedStep is not { } s || Session is null || Busy()) return;
        var reason = _dialogs.Prompt("Skip step", $"Why is \"{s.Id}\" skipped? The reason goes into the build record.");
        if (reason is null) return;
        Session.Skip(s.Id, reason);
        _log.Log($"{s.Id} skipped: {reason}");
        RefreshAll();
        GoToCurrent();
    }

    [RelayCommand]
    private void NotApplicable()
    {
        if (SelectedStep is not { } s || Session is null || Busy()) return;
        var reason = _dialogs.Prompt("Not applicable", $"Why does \"{s.Id}\" not apply to this machine (e.g. no AMD RAID)?");
        if (reason is null) return;
        Session.SetNotApplicable(s.Id, reason);
        _log.Log($"{s.Id} not applicable: {reason}");
        RefreshAll();
        GoToCurrent();
    }

    [RelayCommand]
    private void ResetStep()
    {
        if (SelectedStep is not { } s || Session is null || Busy()) return;
        Session.Reset(s.Id);
        Session.ApplyAfterRules();
        _log.Log($"{s.Id} reset");
        RefreshAll();
    }

    [RelayCommand]
    private void Open(string? target)
    {
        if (string.IsNullOrEmpty(target)) return;
        try { ShellLauncher.Open(target); }
        catch (Exception ex) { _dialogs.Error("Could not open", $"{target}: {ex.Message}"); }
    }

    // ------------------------------------------------------------ checks

    /// <summary>Runs the selected step's check now.</summary>
    [RelayCommand]
    private async Task CheckNow()
    {
        if (SelectedStep is not { HasCheck: true } s || Session is null || Busy()) return;
        var r = await CheckSteps([s.Step], s.Id, showOutput: true);
        if (r is not null) RunStatus = $"{s.Id}: {s.CheckText}";
        RefreshAll();
    }

    /// <summary>
    /// Decision B (Oct 2026): run every check, mark what is found done, list
    /// what is missing and jump to the first missing step.
    /// </summary>
    [RelayCommand]
    private async Task CheckMachine()
    {
        if (Session is null || Busy()) return;
        if (!PowerShellRunner.Available)
        {
            _dialogs.Error("Windows PowerShell", $"Windows PowerShell 5.1 was not found at {PowerShellRunner.PowerShellPath}.");
            return;
        }
        var steps = Session.Flow.AllSteps.Where(s => s.HasCheck && s.AppliesTo(Session.State.Role)).ToList();
        var r = await CheckSteps(steps, "check-machine", showOutput: true);
        if (r is null) return;

        var sum = Session.Summarize(r.Results);
        _log.Log($"Check this machine: {sum}");
        RunStatus = $"Checked {sum.Checked} steps: {sum.FoundDone} found done, {sum.NotDone} not done, {sum.CantCheck} can't be told from Windows. " +
                    $"{sum.Missing} step(s) still open. Nothing was changed.";
        RefreshAll();
        GoToCurrent();
        await AfterScan(sum);
    }

    private async Task AfterScan(ScanSummary sum)
    {
        var lines = new List<string>
        {
            $"{sum.FoundDone} step(s) found already done and marked done.",
            $"{sum.NotDone} step(s) are NOT done (marked ✗ in the list).",
        };
        if (sum.CantCheck > 0) lines.Add($"{sum.CantCheck} check(s) could not tell (shown on each step).");
        if (sum.Unverifiable > 0) lines.Add($"{sum.Unverifiable} open step(s) have no check (WinUtil, NVIDIA Control Panel...): only you know if they were done.");
        lines.Add($"{sum.Missing} step(s) are open in total. Nothing on the machine was changed.");

        var buttons = new List<string> { "Fix what's missing" };
        if (sum.Unverifiable > 0) buttons.Add("Tick manual steps already done…");
        buttons.Add("Close");
        var choice = _dialogs.Choose("Check this machine", "Result", lines, buttons);
        if (choice < 0 || buttons[choice] == "Close") return;
        if (buttons[choice] == "Tick manual steps already done…")
        {
            ConfirmManualSteps();
            if (_dialogs.Choose("Check this machine", $"{Session!.MissingSteps().Count} step(s) still open.", [],
                    ["Fix what's missing", "Close"]) != 0)
                return;
        }
        await FixMissing();
    }

    /// <summary>Bulk confirmation of manual steps without a check (e.g. done before the wizard existed).</summary>
    [RelayCommand]
    private void ConfirmManualSteps()
    {
        if (Session is null || Busy()) return;
        var open = Session.UncheckableOpenSteps();
        if (open.Count == 0)
        {
            _dialogs.Info("Manual steps", "No open manual step without a check.");
            return;
        }
        var picked = _dialogs.PickMany("Manual steps already done",
            "These steps cannot be checked from Windows. Tick the ones you know were done on this machine (also earlier, by hand). " +
            "Leave the rest: the wizard will ask for them one by one.",
            open.Select(s => (s.Id, s.Title)).ToList(), "Mark ticked as done");
        if (picked is null || picked.Count == 0) return;
        Session.MarkManyDone(picked, "Confirmed by the operator as done before (no automatic check).");
        _log.Log($"Operator confirmed as done: {string.Join(", ", picked)}");
        RefreshAll();
        GoToCurrent();
    }

    /// <summary>Runs the checks for some steps and applies the results. Null when cancelled or failed.</summary>
    private async Task<CheckRun?> CheckSteps(IReadOnlyList<StepDefinition> steps, string recordAs, bool showOutput)
    {
        if (Session is null) return null;
        BeginBusy(showOutput, $"Checking {(steps.Count == 1 ? steps[0].Id : $"{steps.Count} steps")}…");
        try
        {
            var r = await _checks.RunAsync(Session, steps, recordAs, OnLine, _cts!.Token);
            LastRunFolder = r.Folders.LastOrDefault() ?? LastRunFolder;
            foreach (var audit in r.Audits.Values.Where(a => a is not null))
                foreach (var row in audit!.Audit) AuditRows.Add(row);
            if (r.Cancelled)
            {
                RunStatus = "Check stopped. Nothing was changed.";
                return null;
            }
            Session.ApplyChecks(r.Results);
            foreach (var res in r.Results) _log.Log($"check {res.Id}: {res.State} – {res.Detail}");
            if (!showOutput) RunStatus = "";
            return r;
        }
        catch (Exception ex)
        {
            _log.Log($"Check error: {ex}");
            _dialogs.Error("Check", $"The check could not run: {ex.Message}");
            return null;
        }
        finally
        {
            EndBusy();
            RefreshAll();
        }
    }

    // ------------------------------------------------------------ fix what's missing

    /// <summary>
    /// Decision C (Oct 2026): walk every open step in checklist order.
    /// Automatic steps run after a confirmation; manual steps wait for the
    /// operator; check steps are checked. "Skip for now" leaves a step open
    /// and moves on; "Stop" ends the walk.
    /// </summary>
    [RelayCommand]
    private async Task FixMissing()
    {
        if (Session is null || Busy()) return;
        var passed = new HashSet<string>();
        while (true)
        {
            var step = Session.MissingSteps().FirstOrDefault(s => !passed.Contains(s.Id));
            if (step is null) break;
            Select(step.Id);
            var outcome = await FixOne(step);
            RefreshAll();
            if (outcome == FixOutcome.Stop) { RunStatus = "Stopped. Press \"Fix what's missing\" to continue later."; return; }
            if (outcome == FixOutcome.Restarting) return;
            if (outcome == FixOutcome.Next && !WizardSession.IsFinal(Session.State.StatusOf(step.Id))) passed.Add(step.Id);
        }
        var left = Session.MissingSteps();
        GoToCurrent();
        _dialogs.Info("Fix what's missing", left.Count == 0
            ? "Every step is done. Open \"Finish the build\" to close the build and save the support bundle."
            : $"End of the list. {left.Count} step(s) are still open (skipped for now or not done):\n" +
              string.Join("\n", left.Take(15).Select(s => $"  {s.Id}  {s.Title}")));
    }

    private enum FixOutcome { Next, Stop, Restarting }

    private async Task<FixOutcome> FixOne(StepDefinition step)
    {
        var item = Steps.First(s => s.Id == step.Id);
        var header = $"{step.Id}  ·  {step.Section.DisplayTitle}";
        var lines = new List<string> { step.Title };
        if (step.Details.Length > 0) lines.Add(step.Details);
        if (item.CheckText.Length > 0) lines.Add(item.CheckText);
        if (step.Uncertain) lines.Add("[Uncertain] item: not confirmed on real hardware.");

        if (step.IsFinish) return FixOutcome.Stop;

        if (step.IsRestart)
        {
            var c = _dialogs.Choose("Restart", header, lines, ["Restart now", "Skip for now", "Stop"]);
            if (c == 0) return RestartForStep("now") ? FixOutcome.Restarting : FixOutcome.Stop;
            return c == 1 ? FixOutcome.Next : FixOutcome.Stop;
        }

        if (step.Kind == StepKind.Check)
        {
            while (true)
            {
                var r = await CheckSteps([step], step.Id, showOutput: true);
                if (r is null) return FixOutcome.Stop;
                if (WizardSession.IsFinal(Session!.State.StatusOf(step.Id))) return FixOutcome.Next;
                var c = _dialogs.Choose("Check", header, [.. lines.Take(2), item.CheckText,
                        "Fix the cause (often an earlier step), then check again."],
                    ["Check again", "Skip for now", "Stop"]);
                if (c != 0) return c == 1 ? FixOutcome.Next : FixOutcome.Stop;
            }
        }

        if (step.Kind == StepKind.Automated && (step.IsScriptRun || step.IsCommand))
        {
            var c = _dialogs.Choose("Automatic step", header,
                [.. lines, "The wizard does this step for you. Steps that reduce security or write to a disk show what will change and ask again."],
                ["Do it", "Skip for now", "Stop"]);
            if (c != 0) return c == 1 ? FixOutcome.Next : FixOutcome.Stop;
            await DoStep(step, fromWalk: true);
            return FixOutcome.Next;
        }

        if (step.Kind == StepKind.Automated)   // auto-done steps that were reset
        {
            Session!.MarkDone(step.Id);
            return FixOutcome.Next;
        }

        // Manual: the operator does it, the wizard waits (Tamper Protection, WinUtil, drivers...).
        while (true)
        {
            var buttons = new List<string> { step.HasCheck ? "Done – check it" : "Done" };
            buttons.AddRange(item.OpenTargets.Select(t => $"Open {t}"));
            if (step.OptionsStep) buttons.Add("Options…");
            buttons.AddRange(["Skip for now", "Stop"]);
            var c = _dialogs.Choose("Manual step", header,
                [.. lines, "Do this yourself now (this window can stay open), then confirm."], buttons);
            if (c < 0 || buttons[c] == "Stop") return FixOutcome.Stop;
            var b = buttons[c];
            if (b == "Skip for now") return FixOutcome.Next;
            if (b.StartsWith("Open ", StringComparison.Ordinal)) { Open(b["Open ".Length..]); continue; }
            if (b == "Options…") { ShowOptions(); return FixOutcome.Stop; }
            if (await MarkDoneAfterCheck(step)) return FixOutcome.Next;
        }
    }

    // ------------------------------------------------------------ automatic steps

    /// <summary>"Do it" on the selected step: run the setup script or the wizard action.</summary>
    [RelayCommand]
    private async Task DoIt()
    {
        if (SelectedStep is not { CanDoIt: true } s || Session is null || Busy()) return;
        await DoStep(s.Step, fromWalk: false);
        RefreshAll();
    }

    private async Task DoStep(StepDefinition step, bool fromWalk)
    {
        if (!PowerShellRunner.Available)
        {
            _dialogs.Error("Windows PowerShell", $"Windows PowerShell 5.1 was not found at {PowerShellRunner.PowerShellPath}.");
            return;
        }
        if (!fromWalk && !ConfirmOrder(step)) return;
        if (step.MustBeOffline && NetworkConnected() is { } nic &&
            !_dialogs.Confirm("Network is connected", $"{step.Id} should run with the network cable unplugged.",
                [$"Connected: {nic}.",
                 "Windows may already be fetching drivers by itself. On a machine prepared earlier this does no harm: the setting is applied anyway."],
                null, "Run anyway"))
            return;

        if (step.IsScriptRun) await RunScript(step, step.Action!.Phase!.Value);
        else if (step.IsCommand) await RunCommand(step);
    }

    private bool ConfirmOrder(StepDefinition step)
    {
        // Checklist order (AGENTS.md rule 1): warn, and let the operator decide.
        var open = Session!.UnfinishedBefore(step.Id);
        return open.Count == 0 || _dialogs.Confirm("Earlier steps not finished",
            $"{open.Count} earlier step(s) are not finished. The order matters (PreUpdate before any driver and " +
            "before the cable is plugged in; PostInstall after updates, drivers, WinUtil and the WATCHOUT install).",
            open.Take(12).Select(x => $"{x.Id}  {x.Title}").Append(open.Count > 12 ? $"... and {open.Count - 12} more" : "")
                .Where(x => x.Length > 0).ToList(),
            null, "Run anyway");
    }

    private static string? NetworkConnected()
    {
        try
        {
            var up = NetworkInterface.GetAllNetworkInterfaces().Where(n =>
                n.OperationalStatus == OperationalStatus.Up &&
                n.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.GigabitEthernet &&
                !n.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase) &&
                !n.Description.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase)).ToList();
            return up.Count == 0 ? null : string.Join(", ", up.Select(n => n.Name));
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }

    private async Task RunScript(StepDefinition step, EnginePhase phase)
    {
        var profile = Session!.Flow.Profile;
        var role = Session.State.Role;
        var options = Session.State.Options.Clone();
        var errors = OptionsValidator.Validate(profile, options);
        if (errors.Count > 0)
        {
            _dialogs.Error("Options", "Fix the options first:\n" + string.Join("\n", errors));
            return;
        }
        // Show before changing (AGENTS.md rule 3).
        var summary = ConfirmationSummaryBuilder.Build(profile, role, phase, options, EngineWorkspace.LgpoAvailable);
        var command = ScriptArgumentBuilder.CommandLine(Session.Flow.Script, ScriptArgumentBuilder.Build(profile, role, phase, options, false, null));
        if (!_dialogs.Confirm(summary.Title, $"This will run:  {command}", summary.Lines,
                summary.RequiresTypedConfirmation ? "APPLY" : null, "Run"))
            return;

        BeginBusy(true, $"Running {phase}…");
        var status = StepStatus.Failed;
        var warnings = new List<string>();
        try
        {
            var run = await _scripts.RunAsync(Session, step.Id, phase, audit: false, OnLine, _cts!.Token);
            LastRunFolder = run.Folder;
            status = run.Status;
            warnings = run.Warnings;
        }
        catch (Exception ex)
        {
            warnings.Add($"The wizard could not run the script: {ex.Message}");
            _log.Log($"{step.Id}: wizard error {ex}");
        }
        finally
        {
            Session.FinishStep(step.Id, status, warnings);
            Session.ApplyAfterRules();
            EndBusy();
            RunStatus = $"{phase} finished: {Steps.First(s => s.Id == step.Id).StatusText}." +
                        (warnings.Count > 0 ? $" {warnings.Count} warning(s), see above." : "");
            RefreshAll();
        }
    }

    /// <summary>A wizard action from Engine/WO-Actions.ps1; asks for input first where needed.</summary>
    private async Task RunCommand(StepDefinition step)
    {
        var name = step.Action!.Name!;
        object? input = null;
        ActionSummaryBuilder.Summary summary;
        switch (name)
        {
            case "bitlocker-off":
                summary = ActionSummaryBuilder.BitLockerOff();
                break;
            case "indexing-off":
                summary = ActionSummaryBuilder.IndexingOff();
                break;
            case "wol-enable":
                summary = ActionSummaryBuilder.WolEnable();
                break;
            case "media-disk-init":
            {
                var disks = await Query<DiskInfo>("list-disks");
                if (disks is null) return;
                if (disks.Count == 0)
                {
                    _dialogs.Info("Media drive", "No empty disk found (only disks without any partition table are offered). " +
                                                  "If the media drive is already formatted, press \"Check now\" on this step.");
                    return;
                }
                if (_dialogs.PickMediaDisk(disks) is not { } pick) return;
                summary = ActionSummaryBuilder.MediaDisk(pick.Disk, pick.Input);
                input = pick.Input.ToParams();
                break;
            }
            case "static-ip":
            {
                var adapters = await Query<AdapterInfo>("list-adapters");
                if (adapters is null) return;
                if (adapters.Count == 0) { _dialogs.Info("Static IP", "No physical network adapter found."); return; }
                if (_dialogs.EditStaticIps(adapters) is not { Count: > 0 } entries) return;
                summary = ActionSummaryBuilder.StaticIp(entries);
                input = new Dictionary<string, object> { ["Adapters"] = entries.Select(e => e.ToParams()).ToList() };
                break;
            }
            default:
                _dialogs.Error("Action", $"This build does not know the action '{name}'.");
                return;
        }

        // Show before changing (AGENTS.md rule 3); typed word for disk writes and security changes.
        if (!_dialogs.Confirm(summary.Title, $"{step.Id}: the wizard will now do this:", summary.Lines, summary.TypedWord, "Do it"))
            return;

        BeginBusy(true, $"{summary.Title}…");
        var status = StepStatus.Failed;
        var warnings = new List<string>();
        try
        {
            Session!.State.Step(step.Id).Attempts++;
            OnLine($"> {name}", false);
            var r = await _actions.RunAsync(Session.State, name, input, OnLine, _cts!.Token);
            LastRunFolder = r.Folder;
            if (r.Exit is null) { status = StepStatus.Interrupted; warnings.Add("Stopped. Running it again is safe."); }
            else if (r.Result is null) warnings.Add(r.Error ?? "No result.");
            else
            {
                warnings.AddRange(r.Result.Warnings);
                status = r.Ok ? (warnings.Count == 0 ? StepStatus.Done : StepStatus.DoneWithWarnings) : StepStatus.Failed;
            }
        }
        catch (Exception ex)
        {
            warnings.Add($"The wizard could not run the action: {ex.Message}");
            _log.Log($"{step.Id}: wizard error {ex}");
        }
        finally
        {
            Session!.FinishStep(step.Id, status, warnings);
            EndBusy();
        }

        // Read back with the step's own check (never pretend): it may turn "done" into "not done".
        if (status is StepStatus.Done or StepStatus.DoneWithWarnings && step.HasCheck)
            await CheckSteps([step], step.Id, showOutput: false);
        RunStatus = $"{step.Id}: {Steps.First(s => s.Id == step.Id).StatusText}." +
                    (warnings.Count > 0 ? $" {warnings.Count} warning(s)." : "");
        RefreshAll();
    }

    /// <summary>Read-only list from WO-Actions.ps1 (disks, adapters). Null when it failed.</summary>
    private async Task<List<T>?> Query<T>(string query)
    {
        BeginBusy(false, "Reading the machine…");
        try
        {
            var r = await _actions.RunAsync(Session!.State, query, null, (_, _) => { }, _cts!.Token);
            if (!r.Ok || r.Result is null)
            {
                _dialogs.Error("Could not read the machine", r.Error ?? string.Join("\n", r.Result?.Warnings ?? []));
                return null;
            }
            return r.Result.DataList<T>();
        }
        catch (Exception ex)
        {
            _dialogs.Error("Could not read the machine", ex.Message);
            return null;
        }
        finally
        {
            EndBusy();
        }
    }

    // ------------------------------------------------------------ restarts

    /// <summary>Restart step: remember the boot time, then restart (or let the operator restart).</summary>
    [RelayCommand]
    private void RestartStep(string? mode)
    {
        if (Busy()) return;
        RestartForStep(mode);
    }

    private bool RestartForStep(string? mode)
    {
        if (SelectedStep is not { IsRestart: true } s || Session is null) return false;
        if (mode == "now" && !_dialogs.Confirm("Restart Windows", "Windows will restart in 10 seconds.",
                ["After the restart, sign in with the show account and start WOSetupWizard.exe from the USB stick again.",
                 "The wizard confirms the restart and continues with the next step."], null, "Restart now"))
            return false;
        Session.RequestReboot(s.Id, SystemInfo.BootTime);
        _log.Log($"{s.Id}: restart requested ({mode})");
        RefreshAll();
        if (mode == "now")
        {
            try { ShellLauncher.Restart(); return true; }
            catch (Exception ex) { _dialogs.Error("Restart", $"Could not start the restart: {ex.Message}"); return false; }
        }
        _dialogs.Info("Restart", "Restart Windows when you are ready, then start WOSetupWizard.exe again from the USB stick.\n" +
                                 "The wizard confirms the restart and continues.");
        return true;
    }

    // ------------------------------------------------------------ finish

    [RelayCommand]
    private void Finish()
    {
        if (SelectedStep is not { IsFinish: true } s || Session is null || Busy()) return;
        var open = Session.UnfinishedBefore(s.Id);
        if (open.Count > 0 && !_dialogs.Confirm("Finish", $"{open.Count} step(s) are not finished:",
                open.Take(12).Select(x => $"{x.Id}  {x.Title}").ToList(), null, "Finish anyway"))
            return;
        Session.Finish(s.Id);
        _log.Log("Build marked finished");
        RefreshAll();
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

    /// <summary>The exact command the selected script step (or audit) will run.</summary>
    public string CommandPreview
    {
        get
        {
            if (Session is null || SelectedStep?.Step is not { } step) return "";
            var (phase, audit) = step.IsScriptRun ? (step.Action!.Phase, false) : step.IsAuditCheck ? (step.AuditPhase, true) : (null, false);
            if (phase is null) return "";
            var phases = phase == EnginePhase.Both ? new[] { EnginePhase.PreUpdate, EnginePhase.PostInstall } : [phase.Value];
            return string.Join("\n", phases.Select(ph => ScriptArgumentBuilder.CommandLine(Session.Flow.Script,
                ScriptArgumentBuilder.Build(Session.Flow.Profile, Session.State.Role, ph, Session.State.Options, audit, null))));
        }
    }

    public bool HasCommandPreview => CommandPreview.Length > 0;

    // ------------------------------------------------------------ run output

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

    private void BeginBusy(bool clearOutput, string status)
    {
        IsRunning = true;
        _cts = new CancellationTokenSource();
        if (clearOutput)
        {
            LogLines.Clear();
            AuditRows.Clear();
        }
        RunStatus = status;
        NotifyOutput();
    }

    private void EndBusy()
    {
        IsRunning = false;
        _cts?.Dispose();
        _cts = null;
        NotifyOutput();
    }

    private void NotifyOutput()
    {
        OnPropertyChanged(nameof(HasAuditRows));
        OnPropertyChanged(nameof(VisibleAuditRows));
        OnPropertyChanged(nameof(HasRunOutput));
    }

    /// <summary>Console line from a script (any thread).</summary>
    private void OnLine(string line, bool isError)
    {
        var kind = line.StartsWith("> ", StringComparison.Ordinal) ? LineKind.StepHeader
                 : isError ? LineKind.Error : EngineOutputParser.Classify(line);
        Application.Current.Dispatcher.BeginInvoke(() => LogLines.Add(new LogLine(line, kind)));
    }

    [RelayCommand]
    private void Cancel()
    {
        if (!IsRunning || _cts is null) return;
        if (_dialogs.Confirm("Stop", "Stop what is running now?",
                ["Changes already made stay in place.", "Running the step again with the same options is safe (every step is idempotent)."],
                null, "Stop"))
            _cts?.Cancel();
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
        if (Session is null || Busy()) return;
        if (!_dialogs.Confirm("Start over", "Start a new build on this machine?",
                ["The current progress is kept as a file next to state.json (state_<date>.json.old), with all logs and backups.",
                 "Nothing on the machine is undone: settings the wizard applied stay applied.",
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
