using System.Text.Json.Serialization;

namespace WOSetup.Core.Flow;

/// <summary>Which WATCHOUT version the machine is built for.</summary>
public enum Profile { WO7, WO6 }

/// <summary>Display server or production (WATCHMAKER / Producer) PC; maps to the scripts' -Role.</summary>
public enum Role { Display, Production }

/// <summary>The three step types (AGENTS.md: one class per step type).</summary>
public enum StepKind { Automated, Manual, Check }

/// <summary>Script phase. "Both" is only used by the final audit.</summary>
public enum EnginePhase { PreUpdate, PostInstall, Both }

public enum ActionType { Script, Restart, Command, Finish }

/// <summary>What an automated step does when the operator confirms.</summary>
public sealed class StepAction
{
    public ActionType Type { get; init; }

    /// <summary>Script phase, for Type = Script.</summary>
    public EnginePhase? Phase { get; init; }

    /// <summary>Command in Engine/WO-Actions.ps1, for Type = Command (e.g. "bitlocker-off").</summary>
    public string? Name { get; init; }
}

/// <summary>
/// One wizard step, defined in tools/flowgen/generate_flows.py. The subclass
/// says who does the work; <see cref="Check"/> says how the wizard can tell
/// that it is already done.
/// </summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(AutomatedStep), "automated")]
[JsonDerivedType(typeof(ManualStep), "manual")]
[JsonDerivedType(typeof(CheckStep), "check")]
public abstract class StepDefinition
{
    public required string Id { get; init; }
    public required string Title { get; init; }

    /// <summary>Instructions, what the wizard does and how it checks.</summary>
    public string Details { get; init; } = "";

    /// <summary>
    /// Read-only test telling whether the step is already done: an id in
    /// Engine/WO-Checks.ps1, a native check ("lgpo", "display-scale"), or
    /// "audit:PreUpdate" / "audit:PostInstall" / "audit:Both" (the script's -Audit).
    /// </summary>
    public string? Check { get; init; }

    public StepAction? Action { get; init; }

    /// <summary>
    /// Only needed when this other step is performed now (a restart after
    /// PostInstall, reading its warnings). When that step is found already
    /// done by a check, this one is marked not needed.
    /// </summary>
    public string? After { get; init; }

    public List<Role> Roles { get; init; } = [Role.Display, Role.Production];
    public bool NeedsInternet { get; init; }
    public bool MustBeOffline { get; init; }

    /// <summary>Security-reducing or destructive: explicit confirmation (AGENTS.md rule 3).</summary>
    public bool Confirm { get; init; }

    /// <summary>The step carries an [Uncertain] marker.</summary>
    public bool Uncertain { get; init; }

    /// <summary>Opens the script options page.</summary>
    public bool OptionsStep { get; init; }

    /// <summary>Completed by the wizard itself at start.</summary>
    public bool AutoDone { get; init; }

    /// <summary>
    /// A check step that is done once its check has run (the audit before
    /// PostInstall: its job is to show what would change, not to pass).
    /// </summary>
    public bool Informational { get; init; }

    [JsonIgnore] public abstract StepKind Kind { get; }

    /// <summary>Section the step belongs to; set by the loader.</summary>
    [JsonIgnore] public SectionDefinition Section { get; internal set; } = null!;

    public bool AppliesTo(Role role) => Roles.Contains(role);

    [JsonIgnore] public bool HasCheck => !string.IsNullOrEmpty(Check);
    [JsonIgnore] public bool IsAuditCheck => Check?.StartsWith("audit:", StringComparison.Ordinal) == true;

    /// <summary>Phase of an "audit:..." check.</summary>
    [JsonIgnore]
    public EnginePhase? AuditPhase => IsAuditCheck && Enum.TryParse<EnginePhase>(Check!["audit:".Length..], out var p) ? p : null;

    [JsonIgnore] public bool IsScriptRun => Action?.Type == ActionType.Script;
    [JsonIgnore] public bool IsRestart => Action?.Type == ActionType.Restart;
    [JsonIgnore] public bool IsCommand => Action?.Type == ActionType.Command;
    [JsonIgnore] public bool IsFinish => Action?.Type == ActionType.Finish;
}

/// <summary>The wizard does it after the operator confirms.</summary>
public sealed class AutomatedStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Automated;
}

/// <summary>The operator does it, then confirms. A check, if any, verifies it.</summary>
public sealed class ManualStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Manual;
}

/// <summary>Read-only verification only.</summary>
public sealed class CheckStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Check;
}

public sealed class SectionDefinition
{
    public required string Id { get; init; }

    /// <summary>Checklist section number (0 = wizard start, 99 = finish).</summary>
    public int Number { get; init; }

    public required string Title { get; init; }
    public List<StepDefinition> Steps { get; init; } = [];

    public string DisplayTitle => Number is 0 or 99 ? Title : $"{Number}. {Title}";
}

public sealed class FlowDefinition
{
    public int SchemaVersion { get; init; }
    public Profile Profile { get; init; }
    public required string Title { get; init; }

    /// <summary>Script file name, e.g. WO7-Setup.ps1.</summary>
    public required string Script { get; init; }

    public string Checklist { get; init; } = "";
    public List<SectionDefinition> Sections { get; init; } = [];

    public IEnumerable<StepDefinition> AllSteps => Sections.SelectMany(s => s.Steps);

    public StepDefinition? Find(string id) => AllSteps.FirstOrDefault(s => s.Id == id);
}
