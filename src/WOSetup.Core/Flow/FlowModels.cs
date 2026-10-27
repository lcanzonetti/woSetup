using System.Text.Json.Serialization;

namespace WOSetup.Core.Flow;

/// <summary>Which WATCHOUT version the machine is built for.</summary>
public enum Profile { WO7, WO6 }

/// <summary>Display server or production (WATCHMAKER / Producer) PC; maps to the scripts' -Role.</summary>
public enum Role { Display, Production }

/// <summary>The three step types of the wizard (AGENTS.md: one class per step type).</summary>
public enum StepKind { Manual, Check, Automated }

/// <summary>Script phase a step runs. "Both" is only used by the final audit.</summary>
public enum EnginePhase { PreUpdate, PostInstall, Both }

/// <summary>A step that runs one of the setup scripts.</summary>
public sealed class EngineAction
{
    public EnginePhase Phase { get; init; }

    /// <summary>True: read-only audit (-Audit). False: the real run.</summary>
    public bool Audit { get; init; }
}

/// <summary>
/// One wizard step, generated from a row of docs/WIZARD_FLOW.md.
/// The subclass says what kind of step it is; the fields are the row's
/// columns plus a few flags the generator derives from them.
/// </summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(ManualStep), "manual")]
[JsonDerivedType(typeof(CheckStep), "check")]
[JsonDerivedType(typeof(AutomatedStep), "automated")]
public abstract class StepDefinition
{
    public required string Id { get; init; }
    public required string Title { get; init; }

    /// <summary>Type column as written in WIZARD_FLOW (e.g. "M+C", "A 🔒").</summary>
    public string TypeLabel { get; init; } = "";

    /// <summary>"Uses / verification" column: commands, checks, notes.</summary>
    public string Details { get; init; } = "";

    /// <summary>Reboot column as written in WIZARD_FLOW.</summary>
    public string Reboot { get; init; } = "";

    public List<Role> Roles { get; init; } = [Role.Display, Role.Production];
    public bool PreWindows { get; init; }
    public bool NeedsInternet { get; init; }
    public bool MustBeOffline { get; init; }

    /// <summary>Security-reducing or destructive: needs an explicit confirmation (AGENTS.md rule 3).</summary>
    public bool Confirm { get; init; }

    /// <summary>Finished only once the machine has really restarted.</summary>
    public bool RebootStep { get; init; }

    /// <summary>Completed by the wizard itself at start (profile choice, own folder).</summary>
    public bool AutoDone { get; init; }

    /// <summary>Opens the script options page.</summary>
    public bool OptionsStep { get; init; }

    /// <summary>The row carries an [Uncertain] marker.</summary>
    public bool Uncertain { get; init; }

    /// <summary>Set when the step runs a setup script phase.</summary>
    public EngineAction? Engine { get; init; }

    [JsonIgnore] public abstract StepKind Kind { get; }

    /// <summary>Section the step belongs to; set by the loader.</summary>
    [JsonIgnore] public SectionDefinition Section { get; internal set; } = null!;

    public bool AppliesTo(Role role) => Roles.Contains(role);
}

/// <summary>Instructions + "Mark done". The operator does it by hand.</summary>
public sealed class ManualStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Manual;
}

/// <summary>Read-only verification. With <see cref="StepDefinition.Engine"/> set it is a script audit.</summary>
public sealed class CheckStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Check;
}

/// <summary>The wizard changes the machine (script phase or a checklist command).</summary>
public sealed class AutomatedStep : StepDefinition
{
    [JsonIgnore] public override StepKind Kind => StepKind.Automated;
}

public sealed class SectionDefinition
{
    public required string Id { get; init; }

    /// <summary>Checklist section number (0 = wizard start, 99 = finish).</summary>
    public int Number { get; init; }

    public required string Title { get; init; }
    public List<StepDefinition> Steps { get; init; } = [];

    public string DisplayTitle => Number switch
    {
        0 => Title,
        99 => Title,
        _ => $"{Number}. {Title}",
    };
}

public sealed class FlowDefinition
{
    public int SchemaVersion { get; init; }
    public Profile Profile { get; init; }
    public required string Title { get; init; }

    /// <summary>Script file name, e.g. WO7-Setup.ps1.</summary>
    public required string Script { get; init; }

    public string ChecklistDate { get; init; } = "";
    public List<SectionDefinition> Sections { get; init; } = [];

    public IEnumerable<StepDefinition> AllSteps => Sections.SelectMany(s => s.Steps);

    public StepDefinition? Find(string id) => AllSteps.FirstOrDefault(s => s.Id == id);
}
