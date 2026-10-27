using WOSetup.Core.Checks;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;

namespace WOSetup.Core.State;

public enum StepStatus
{
    NotStarted,
    InProgress,
    Done,
    DoneWithWarnings,

    /// <summary>The step's check ran and says the goal is not in place.</summary>
    NotDone,
    Failed,
    Interrupted,
    AwaitingReboot,
    Skipped,
    NotApplicable,
}

/// <summary>
/// Everything the wizard remembers about one machine, saved as
/// %ProgramData%\WOSetupWizard\state.json (ARCHITECTURE §5). No secrets.
/// </summary>
public sealed class WizardState
{
    /// <summary>
    /// 2 = step lists without the old "Before you start" / "Install Windows"
    /// sections (Oct 2026). Older files belong to wizard 0.1 and are not read.
    /// </summary>
    public const int CurrentSchemaVersion = 2;

    public int SchemaVersion { get; set; } = CurrentSchemaVersion;
    public string WizardVersion { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
    public Profile Profile { get; set; }
    public Role Role { get; set; }

    /// <summary>Set after the first real script run: the profile can then only change via "Start over".</summary>
    public bool ProfileLocked { get; set; }

    public MachineInfo Machine { get; set; } = new();
    public EngineOptions Options { get; set; } = new();
    public Dictionary<string, StepState> Steps { get; set; } = [];
    public List<RunRecord> Runs { get; set; } = [];
    public List<BackupRecord> Backups { get; set; } = [];
    public PendingReboot? PendingReboot { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }

    public StepState Step(string id)
    {
        if (!Steps.TryGetValue(id, out var s)) Steps[id] = s = new StepState();
        return s;
    }

    public StepStatus StatusOf(string id) => Steps.TryGetValue(id, out var s) ? s.Status : StepStatus.NotStarted;
}

public sealed class MachineInfo
{
    public string ComputerNameAtStart { get; set; } = "";

    /// <summary>Log folder name, fixed at first run so a later rename does not split the logs.</summary>
    public string LogFolderName { get; set; } = "";
    public string UserAtStart { get; set; } = "";
}

public sealed class StepState
{
    public StepStatus Status { get; set; } = StepStatus.NotStarted;
    public DateTimeOffset? UpdatedAt { get; set; }

    /// <summary>Operator's reason for Skipped / Not applicable / accepted warnings, or the wizard's own note.</summary>
    public string? Note { get; set; }
    public int Attempts { get; set; }
    public List<string> RunIds { get; set; } = [];
    public List<string> Warnings { get; set; } = [];

    /// <summary>Set when a check, not the operator, found the step done.</summary>
    public bool Detected { get; set; }

    /// <summary>Last check result for this step (null = never checked).</summary>
    public CheckState? CheckState { get; set; }
    public string? CheckDetail { get; set; }
    public DateTimeOffset? CheckedAt { get; set; }
}

public sealed class RunRecord
{
    public string RunId { get; set; } = "";
    public string StepId { get; set; } = "";
    public string Script { get; set; } = "";
    public string Phase { get; set; } = "";
    public bool Audit { get; set; }
    public string CommandLine { get; set; } = "";

    /// <summary>Run folder relative to %ProgramData%\WOSetupWizard.</summary>
    public string Folder { get; set; } = "";
    public string? ScriptSha256 { get; set; }
    public bool LgpoBundled { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public int? ExitCode { get; set; }
    public StepStatus Outcome { get; set; }
    public string? Fatal { get; set; }
    public int Warnings { get; set; }
    public int AuditSet { get; set; }
    public int AuditNotSet { get; set; }
    public int AuditNotApplicable { get; set; }
}

public sealed class BackupRecord
{
    public string Kind { get; set; } = "";
    public string Path { get; set; } = "";
    public string Restore { get; set; } = "";
    public string RunId { get; set; } = "";

    /// <summary>
    /// First backup of its kind. Restore always uses it (OPEN_QUESTIONS 15):
    /// a later run backs up the already-changed state.
    /// </summary>
    public bool IsBaseline { get; set; }
}

public sealed class PendingReboot
{
    public string StepId { get; set; } = "";
    public DateTimeOffset RequestedAt { get; set; }

    /// <summary>When Windows last started, at the moment the reboot was requested.</summary>
    public DateTimeOffset BootTimeAtRequest { get; set; }
}
