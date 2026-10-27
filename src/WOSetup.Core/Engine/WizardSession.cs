using WOSetup.Core.Checks;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.Core.Engine;

/// <summary>
/// All changes to the wizard state go through here, and every change is
/// saved immediately. The UI only calls these methods; it holds no rules.
/// </summary>
public sealed class WizardSession
{
    private readonly JsonStateStore _store;
    private readonly Func<DateTimeOffset> _clock;

    public FlowDefinition Flow { get; }
    public WizardState State { get; }

    public WizardSession(FlowDefinition flow, WizardState state, JsonStateStore store, Func<DateTimeOffset>? clock = null)
    {
        Flow = flow;
        State = state;
        _store = store;
        _clock = clock ?? (() => DateTimeOffset.Now);
    }

    /// <summary>Tolerance when comparing boot times computed from uptime.</summary>
    public static readonly TimeSpan BootTimeTolerance = TimeSpan.FromMinutes(2);

    public static WizardState CreateState(FlowDefinition flow, Role role, string computerName, string user,
                                          string wizardVersion, DateTimeOffset now)
    {
        var state = new WizardState
        {
            WizardVersion = wizardVersion,
            CreatedAt = now,
            Profile = flow.Profile,
            Role = role,
            Machine = new MachineInfo { ComputerNameAtStart = computerName, LogFolderName = computerName, UserAtStart = user },
        };
        foreach (var step in flow.AllSteps.Where(s => s.AutoDone))
            state.Steps[step.Id] = new StepState { Status = StepStatus.Done, UpdatedAt = now, Note = "Done by the wizard at start." };
        ApplyRole(flow, state, now);
        return state;
    }

    public static bool IsFinal(StepStatus s) =>
        s is StepStatus.Done or StepStatus.DoneWithWarnings or StepStatus.Skipped or StepStatus.NotApplicable;

    /// <summary>First step that is not finished yet; null when everything is done.</summary>
    public StepDefinition? CurrentStep => Flow.AllSteps.FirstOrDefault(s => !IsFinal(State.StatusOf(s.Id)));

    /// <summary>Earlier steps that are not finished (checklist order, AGENTS.md rule 1).</summary>
    public IReadOnlyList<StepDefinition> UnfinishedBefore(string stepId) =>
        Flow.AllSteps.TakeWhile(s => s.Id != stepId).Where(s => !IsFinal(State.StatusOf(s.Id))).ToList();

    public int CountFinished() => Flow.AllSteps.Count(s => IsFinal(State.StatusOf(s.Id)));

    public void Save() => _store.Save(State);

    private void Set(string id, StepStatus status, string? note)
    {
        var s = State.Step(id);
        s.Status = status;
        s.Note = note;
        s.UpdatedAt = _clock();
        Save();
    }

    public void MarkDone(string id, string? note = null)
    {
        State.Step(id).Detected = false;
        Set(id, StepStatus.Done, note);
    }

    /// <summary>Operator confirms several manual steps at once (e.g. done in the past, no check exists).</summary>
    public void MarkManyDone(IEnumerable<string> ids, string note)
    {
        var now = _clock();
        foreach (var id in ids)
        {
            var s = State.Step(id);
            s.Status = StepStatus.Done;
            s.Detected = false;
            s.Note = note;
            s.UpdatedAt = now;
        }
        Save();
    }

    public void Skip(string id, string reason)
    {
        if (string.IsNullOrWhiteSpace(reason)) throw new ArgumentException("A reason is required to skip a step.");
        Set(id, StepStatus.Skipped, reason.Trim());
    }

    public void SetNotApplicable(string id, string reason)
    {
        if (string.IsNullOrWhiteSpace(reason)) throw new ArgumentException("A reason is required.");
        Set(id, StepStatus.NotApplicable, reason.Trim());
    }

    public void Reset(string id)
    {
        if (State.PendingReboot?.StepId == id) State.PendingReboot = null;
        var s = State.Step(id);
        s.Warnings.Clear();
        s.Detected = false;
        Set(id, StepStatus.NotStarted, null);
    }

    /// <summary>Steps for the other role become "Not applicable"; switching back restores them.</summary>
    public void ChangeRole(Role role)
    {
        State.Role = role;
        ApplyRole(Flow, State, _clock());
        Save();
    }

    internal const string RoleNote = "Not for this role.";

    private static void ApplyRole(FlowDefinition flow, WizardState state, DateTimeOffset now)
    {
        foreach (var step in flow.AllSteps)
        {
            var s = state.Step(step.Id);
            if (!step.AppliesTo(state.Role))
            {
                if (s.Status == StepStatus.NotStarted)
                {
                    s.Status = StepStatus.NotApplicable;
                    s.Note = RoleNote;
                    s.UpdatedAt = now;
                }
            }
            else if (s.Status == StepStatus.NotApplicable && s.Note == RoleNote)
            {
                s.Status = StepStatus.NotStarted;
                s.Note = null;
                s.UpdatedAt = now;
            }
        }
    }

    public void SaveOptions(EngineOptions options)
    {
        State.Options = options.Clone();
        Save();
    }

    /// <summary>True once PostInstall has really run: later option changes do not undo it.</summary>
    public bool PostInstallHasRun =>
        State.Runs.Any(r => !r.Audit && r.Phase == nameof(EnginePhase.PostInstall) && r.ExitCode == 0);

    // ------------------------------------------------------------------ runs

    public void BeginRun(string stepId, RunRecord run)
    {
        run.StepId = stepId;
        State.Runs.Add(run);
        var s = State.Step(stepId);
        s.Attempts++;
        s.RunIds.Add(run.RunId);
        s.Warnings.Clear();
        if (!run.Audit) State.ProfileLocked = true;
        Set(stepId, StepStatus.InProgress, null);
    }

    /// <summary>
    /// A read-only audit run used as a check: recorded in the run history,
    /// but it does not change the step's status (the check result does).
    /// </summary>
    public void BeginAudit(string stepId, RunRecord run)
    {
        run.StepId = stepId;
        run.Audit = true;
        State.Runs.Add(run);
        if (Flow.Find(stepId) is not null) State.Step(stepId).RunIds.Add(run.RunId);
        Save();
    }

    /// <summary>Records one finished script run (an audit of both phases calls this twice).</summary>
    public void RecordRun(RunRecord run, EngineResult? result, StepStatus outcome, IReadOnlyList<string> warnings)
    {
        run.EndedAt = _clock();
        run.Outcome = outcome;
        run.Warnings = warnings.Count;
        run.Fatal = result?.Fatal;
        if (result is not null)
        {
            run.AuditSet = result.AuditCount("Set");
            run.AuditNotSet = result.AuditCount("NotSet");
            run.AuditNotApplicable = result.AuditCount("NA");
            foreach (var b in result.Backups)
            {
                State.Backups.Add(new BackupRecord
                {
                    Kind = b.Kind,
                    Path = b.Path,
                    Restore = b.Restore,
                    RunId = run.RunId,
                    IsBaseline = !State.Backups.Any(x => x.Kind == b.Kind && (b.Kind != "AdapterBindings" || x.Restore == b.Restore)),
                });
            }
        }
        Save();
    }

    public void FinishStep(string stepId, StepStatus outcome, IReadOnlyList<string> warnings)
    {
        var s = State.Step(stepId);
        s.Warnings = [.. warnings];
        s.Detected = false;
        Set(stepId, outcome, null);
    }

    /// <summary>
    /// Outcome of one script run. Warnings come from the result file, never
    /// from the exit code alone; anything that cannot be interpreted becomes a
    /// warning instead of a silent "done" (AGENTS.md rule 2).
    /// </summary>
    public static (StepStatus Status, List<string> Warnings) Evaluate(bool audit, int? exitCode, EngineResult? result, int consoleWarnings)
    {
        var warnings = new List<string>();
        if (exitCode is null) return (StepStatus.Interrupted, ["The run was cancelled. Running it again with the same options is safe."]);
        if (result is null)
        {
            if (exitCode == 0)
                return (StepStatus.DoneWithWarnings, ["The script finished but wrote no result file. Read the transcript in the run folder."]);
            return (StepStatus.Failed, [$"The script failed (exit code {exitCode}) before writing a result. See the log."]);
        }
        if (result.Failed || exitCode != 0)
            return (StepStatus.Failed, [result.Fatal ?? $"The script failed (exit code {exitCode})."]);

        warnings.AddRange(result.Warnings);
        if (consoleWarnings != result.Warnings.Count)
            warnings.Add($"The console showed {consoleWarnings} warning(s) but the result file lists {result.Warnings.Count}. Read the transcript.");
        if (audit)
        {
            var notSet = result.AuditCount("NotSet");
            if (notSet > 0) warnings.Add($"{notSet} item(s) are not set yet (see the audit list).");
        }
        return (warnings.Count == 0 ? StepStatus.Done : StepStatus.DoneWithWarnings, warnings);
    }

    /// <summary>At start: a run that was in progress when the app or the machine stopped.</summary>
    public void MarkInterruptedRuns()
    {
        var changed = false;
        foreach (var (id, s) in State.Steps.Where(kv => kv.Value.Status == StepStatus.InProgress))
        {
            s.Status = StepStatus.Interrupted;
            s.Note = "The wizard stopped while this was running. Running it again with the same options is safe.";
            s.UpdatedAt = _clock();
            changed = true;
        }
        foreach (var r in State.Runs.Where(r => r.EndedAt is null))
        {
            r.Outcome = StepStatus.Interrupted;
            r.EndedAt = _clock();
            changed = true;
        }
        if (changed) Save();
    }

    // --------------------------------------------------------------- reboots

    public void RequestReboot(string stepId, DateTimeOffset currentBootTime)
    {
        State.PendingReboot = new PendingReboot { StepId = stepId, RequestedAt = _clock(), BootTimeAtRequest = currentBootTime };
        Set(stepId, StepStatus.AwaitingReboot, "Waiting for the machine to restart.");
    }

    /// <summary>
    /// Called at start. Returns the step id whose reboot is now confirmed, or
    /// null. A step stays "Awaiting reboot" if Windows has not restarted.
    /// </summary>
    public string? ConfirmReboot(DateTimeOffset currentBootTime)
    {
        var p = State.PendingReboot;
        if (p is null || currentBootTime <= p.BootTimeAtRequest + BootTimeTolerance) return null;
        State.PendingReboot = null;
        Set(p.StepId, StepStatus.Done, $"Restart confirmed (Windows started {currentBootTime:yyyy-MM-dd HH:mm}).");
        return p.StepId;
    }

    // ---------------------------------------------------------------- checks

    internal const string NotNeededPrefix = "Not needed: ";
    internal const string FoundDonePrefix = "Found done by the check";

    /// <summary>
    /// Stores a check result and updates the step's status (decision B, Oct
    /// 2026: steps found done are marked done so the wizard jumps to what is
    /// missing). Rules:
    /// - Done: the step becomes Done ("found done") unless it is already final.
    ///   An informational check is Done whenever it ran.
    /// - Not done: a step that was Done or Done with warnings becomes Not done,
    ///   because the machine no longer matches (AGENTS.md rule 2, never pretend).
    ///   Skipped and Not applicable stay: those are the operator's decisions.
    /// - Not applicable: an open step becomes Not applicable with the reason.
    /// - Can't check: only the detail is stored.
    /// A step that is running or waiting for a restart is never changed.
    /// Call <see cref="ApplyAfterRules"/> (or use <see cref="ApplyChecks"/>) afterwards.
    /// </summary>
    public void ApplyCheck(string stepId, CheckResult result, bool save = true)
    {
        var step = Flow.Find(stepId) ?? throw new ArgumentException($"Unknown step {stepId}");
        var s = State.Step(stepId);
        var now = _clock();
        var state = result.State;
        if (step.Informational && state is CheckState.NotDone) state = CheckState.Done;
        s.CheckState = state;
        s.CheckDetail = result.Detail;
        s.CheckedAt = now;

        if (s.Status is StepStatus.InProgress or StepStatus.AwaitingReboot || (s.Note == RoleNote && s.Status == StepStatus.NotApplicable))
        {
            if (save) Save();
            return;
        }

        switch (state)
        {
            case CheckState.Done when !IsFinal(s.Status):
                s.Status = StepStatus.Done;
                s.Detected = true;
                s.Note = $"{FoundDonePrefix}: {result.Detail}";
                s.UpdatedAt = now;
                break;
            case CheckState.NotDone when s.Status is StepStatus.Done or StepStatus.DoneWithWarnings
                                                  or StepStatus.NotStarted or StepStatus.Interrupted:
                s.Status = StepStatus.NotDone;
                s.Detected = false;
                s.Note = result.Detail;
                s.UpdatedAt = now;
                break;
            case CheckState.NotDone when s.Status == StepStatus.NotDone:
                s.Note = result.Detail;
                break;
            case CheckState.NotApplicable when !IsFinal(s.Status):
                s.Status = StepStatus.NotApplicable;
                s.Detected = true;
                s.Note = result.Detail;
                s.UpdatedAt = now;
                break;
        }
        if (save) Save();
    }

    /// <summary>Applies a batch of results, then the "after" rules; saves once.</summary>
    public void ApplyChecks(IEnumerable<CheckResult> results)
    {
        foreach (var r in results) ApplyCheck(r.Id, r, save: false);
        ApplyAfterRules(save: false);
        Save();
    }

    /// <summary>
    /// A step with "after X" (restart after PostInstall, read its warnings) is
    /// only needed when X is performed now. If X was found already done by a
    /// check, the step is marked not needed; if X is open again, it comes back.
    /// </summary>
    public void ApplyAfterRules(bool save = true)
    {
        var now = _clock();
        foreach (var step in Flow.AllSteps.Where(x => x.After is not null))
        {
            var s = State.Step(step.Id);
            var target = State.Step(step.After!);
            var targetFound = target.Status == StepStatus.Done && target.Detected;
            if (targetFound && s.Status is StepStatus.NotStarted or StepStatus.NotDone or StepStatus.Interrupted)
            {
                s.Status = StepStatus.NotApplicable;
                s.Note = $"{NotNeededPrefix}{step.After} was found already done.";
                s.UpdatedAt = now;
            }
            else if (!targetFound && s.Status == StepStatus.NotApplicable && s.Note?.StartsWith(NotNeededPrefix, StringComparison.Ordinal) == true)
            {
                s.Status = StepStatus.NotStarted;
                s.Note = null;
                s.UpdatedAt = now;
            }
        }
        if (save) Save();
    }

    /// <summary>Steps still open (not done, not skipped, not applicable), in checklist order.</summary>
    public IReadOnlyList<StepDefinition> MissingSteps() =>
        Flow.AllSteps.Where(s => !IsFinal(State.StatusOf(s.Id)) && !s.IsFinish).ToList();

    /// <summary>Open steps that have no check: only the operator can say whether they were done.</summary>
    public IReadOnlyList<StepDefinition> UncheckableOpenSteps() =>
        MissingSteps().Where(s => !s.HasCheck && s.Kind == StepKind.Manual).ToList();

    /// <summary>Summary of the last "Check this machine".</summary>
    public ScanSummary Summarize(IReadOnlyCollection<CheckResult> results)
    {
        var missing = MissingSteps();
        return new ScanSummary(
            Checked: results.Count,
            FoundDone: results.Count(r => State.Step(r.Id) is { Detected: true, Status: StepStatus.Done }),
            NotDone: results.Count(r => State.StatusOf(r.Id) == StepStatus.NotDone),
            CantCheck: results.Count(r => r.State == CheckState.CantCheck),
            Missing: missing.Count,
            Unverifiable: UncheckableOpenSteps().Count,
            FirstMissing: missing.FirstOrDefault()?.Id);
    }

    public void Finish(string stepId)
    {
        State.FinishedAt = _clock();
        Set(stepId, StepStatus.Done, null);
    }
}

/// <summary>Counts shown after "Check this machine".</summary>
public sealed record ScanSummary(int Checked, int FoundDone, int NotDone, int CantCheck, int Missing,
                                 int Unverifiable, string? FirstMissing);
