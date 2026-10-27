using CommunityToolkit.Mvvm.ComponentModel;
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
    public string TypeLabel => Step.TypeLabel;
    public string Details => Step.Details;
    public string RebootText => Step.Reboot;
    public IReadOnlyList<string> OpenTargets { get; }

    public bool HasDetails => Step.Details.Length > 0;
    public bool HasRebootText => Step.Reboot.Length > 0;
    public bool IsPreWindows => Step.PreWindows;
    public bool NeedsInternet => Step.NeedsInternet;
    public bool MustBeOffline => Step.MustBeOffline;
    public bool NeedsConfirmation => Step.Confirm || Step.Engine is { Audit: false, Phase: EnginePhase.PostInstall };
    public bool IsUncertain => Step.Uncertain;

    public bool HasEngine => Step.Engine is not null;
    public bool IsApplyRun => Step.Engine is { Audit: false };
    public bool IsAudit => Step.Engine is { Audit: true };
    public bool IsRebootStep => Step.RebootStep;
    public bool IsFinish => Step.Id == "W-99";
    public bool IsOptionsStep => Step.OptionsStep || IsApplyRun || IsAudit;

    /// <summary>A reboot is mentioned (Windows Update, driver installers) but the step is not itself a restart.</summary>
    public bool OffersRestart => !IsRebootStep && Step.Reboot.Contains('⟳') && !Step.PreWindows;

    /// <summary>Checks and commands the wizard does not run itself yet (later milestone).</summary>
    public bool NotAutomatedYet => Step.Kind != StepKind.Manual && !HasEngine && !IsFinish && !Step.AutoDone;

    public string KindText => Step.Kind switch
    {
        StepKind.Manual => "Manual",
        StepKind.Check when IsAudit => "Check (script audit, read-only)",
        StepKind.Check => "Check",
        _ => IsApplyRun ? "Automated (setup script)" : "Automated",
    };

    public StepStatus Status => _session.State.StatusOf(Id);
    public string? Note => _session.State.Steps.TryGetValue(Id, out var s) ? s.Note : null;
    public bool HasNote => !string.IsNullOrWhiteSpace(Note);
    public IReadOnlyList<string> Warnings => _session.State.Steps.TryGetValue(Id, out var s) ? s.Warnings : [];
    public bool HasWarnings => Warnings.Count > 0;
    public bool IsFinal => WizardSession.IsFinal(Status);

    public string StatusGlyph => Status switch
    {
        StepStatus.Done => "✔",
        StepStatus.DoneWithWarnings => "⚠",
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
        StepStatus.Done => "Done",
        StepStatus.DoneWithWarnings => "Done with warnings",
        StepStatus.Failed => "Failed",
        StepStatus.Interrupted => "Interrupted",
        StepStatus.AwaitingReboot => "Waiting for restart",
        StepStatus.Skipped => "Skipped",
        StepStatus.NotApplicable => "Not applicable",
        _ => Status.ToString(),
    };

    public void Refresh()
    {
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(StatusGlyph));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(Note));
        OnPropertyChanged(nameof(HasNote));
        OnPropertyChanged(nameof(Warnings));
        OnPropertyChanged(nameof(HasWarnings));
        OnPropertyChanged(nameof(IsFinal));
    }
}
