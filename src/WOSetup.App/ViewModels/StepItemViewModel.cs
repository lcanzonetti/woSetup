using CommunityToolkit.Mvvm.ComponentModel;
using WOSetup.Core.Checks;
using WOSetup.Core.Engine;
using WOSetup.Core.Flow;
using WOSetup.Core.State;

namespace WOSetup.App.ViewModels;

/// <summary>One step in the left rail and in the detail pane. Reads its status from the state.</summary>
public sealed class StepItemViewModel : ObservableObject
{
    private readonly WizardSession _session;

    public StepItemViewModel(StepDefinition step, WizardSession session)
    {
        Step = step;
        _session = session;
        OpenTargets = Core.Flow.OpenTargets.Extract(step.Title + " " + step.Details);
    }

    public StepDefinition Step { get; }
    public string Id => Step.Id;
    public string Title => Step.Title;
    public string SectionTitle => Step.Section.DisplayTitle;
    public string Details => Step.Details;
    public IReadOnlyList<string> OpenTargets { get; }

    public bool HasDetails => Step.Details.Length > 0;
    public bool NeedsInternet => Step.NeedsInternet;
    public bool MustBeOffline => Step.MustBeOffline;
    public bool NeedsConfirmation => Step.Confirm;
    public bool IsUncertain => Step.Uncertain;

    public bool IsScriptRun => Step.IsScriptRun;
    public bool IsCommand => Step.IsCommand;
    public bool IsRestart => Step.IsRestart;
    public bool IsFinish => Step.IsFinish;
    public bool HasCheck => Step.HasCheck;
    public bool IsManual => Step.Kind == StepKind.Manual;

    /// <summary>The wizard can perform this step (script run or action).</summary>
    public bool CanDoIt => IsScriptRun || IsCommand;

    public string DoItText => Step.Action switch
    {
        { Type: ActionType.Script, Phase: var p } => $"Run {p}",
        _ => "Do it",
    };

    public string CheckButtonText => Step.IsAuditCheck ? "Run audit (read-only)" : "Check now";
    public bool IsOptionsStep => Step.OptionsStep || IsScriptRun || Step.IsAuditCheck;
    public bool CanMarkDone => !IsRestart && !IsFinish;

    public string KindText => Step.Kind switch
    {
        StepKind.Manual => HasCheck ? "Manual: you do it, the wizard checks it" : "Manual: you do it, then confirm",
        StepKind.Check => Step.IsAuditCheck ? "Check (script audit, read-only)" : "Check (read-only)",
        _ when IsScriptRun => "Automatic: setup script",
        _ when IsRestart => "Automatic: restart",
        _ when IsFinish => "Finish",
        _ => "Automatic: the wizard does it after you confirm",
    };

    private StepState? S => _session.State.Steps.TryGetValue(Id, out var s) ? s : null;

    public StepStatus Status => _session.State.StatusOf(Id);
    public string? Note => S?.Note;
    public bool HasNote => !string.IsNullOrWhiteSpace(Note);
    public IReadOnlyList<string> Warnings => S?.Warnings ?? [];
    public bool HasWarnings => Warnings.Count > 0;
    public bool IsFinal => WizardSession.IsFinal(Status);

    /// <summary>Last check result, e.g. "Check (27 Oct 10:12): not done – C: protection on".</summary>
    public string CheckText => S is { CheckState: { } st, CheckedAt: { } at } s
        ? $"Last check {at:dd MMM HH:mm}: {StateText(st)}" + (string.IsNullOrWhiteSpace(s.CheckDetail) ? "" : $" – {s.CheckDetail}")
        : "";

    public bool HasCheckText => CheckText.Length > 0;

    private static string StateText(CheckState s) => s switch
    {
        CheckState.Done => "done",
        CheckState.NotDone => "NOT done",
        CheckState.NotApplicable => "not applicable",
        _ => "can't tell",
    };

    public string StatusGlyph => Status switch
    {
        StepStatus.Done => "✔",
        StepStatus.DoneWithWarnings => "⚠",
        StepStatus.NotDone => "✗",
        StepStatus.Failed => "✖",
        StepStatus.Interrupted => "✖",
        StepStatus.InProgress => "…",
        StepStatus.AwaitingReboot => "↻",
        StepStatus.Skipped => "»",
        StepStatus.NotApplicable => "–",
        _ => "○",
    };

    public string StatusText => Status switch
    {
        StepStatus.NotStarted => "Not started",
        StepStatus.InProgress => "Running",
        StepStatus.Done when S?.Detected == true => "Done (found by the check)",
        StepStatus.Done => "Done",
        StepStatus.DoneWithWarnings => "Done with warnings",
        StepStatus.NotDone => "Not done (the check says it is missing)",
        StepStatus.Failed => "Failed",
        StepStatus.Interrupted => "Interrupted",
        StepStatus.AwaitingReboot => "Waiting for restart",
        StepStatus.Skipped => "Skipped",
        StepStatus.NotApplicable => "Not applicable",
        _ => Status.ToString(),
    };

    public void Refresh()
    {
        foreach (var p in new[] { nameof(Status), nameof(StatusGlyph), nameof(StatusText), nameof(Note), nameof(HasNote),
                                  nameof(Warnings), nameof(HasWarnings), nameof(IsFinal), nameof(CheckText), nameof(HasCheckText) })
            OnPropertyChanged(p);
    }
}
