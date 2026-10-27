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

    public void MarkDone(string id, string? note = null) => Set(id, StepStatus.Done, note);

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

    public void Finish(string stepId)
    {
        State.FinishedAt = _clock();
        Set(stepId, StepStatus.Done, null);
    }
}
