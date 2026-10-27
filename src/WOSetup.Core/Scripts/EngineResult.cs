using System.Text.Json;
using System.Text.Json.Serialization;

namespace WOSetup.Core.Scripts;

/// <summary>
/// The JSON summary a script writes with -ResultPath (schema 1 or 2, see
/// ARCHITECTURE §6.4). Only the fields the wizard uses are modelled.
/// </summary>
public sealed class EngineResult
{
    public int SchemaVersion { get; init; }
    public string Script { get; init; } = "";
    public string Phase { get; init; } = "";

    /// <summary>"Apply" or "Audit" (schema 2). Missing in schema 1 = Apply.</summary>
    public string Mode { get; init; } = "Apply";

    /// <summary>"Completed" or "Failed".</summary>
    public string Status { get; init; } = "";
    public string? Fatal { get; init; }
    public List<string> Warnings { get; init; } = [];
    public List<BackupEntry> Backups { get; init; } = [];
    public List<AuditEntry> Audit { get; init; } = [];
    public string? Transcript { get; init; }

    public bool Failed => string.Equals(Status, "Failed", StringComparison.OrdinalIgnoreCase);
    public int AuditCount(string state) => Audit.Count(a => string.Equals(a.State, state, StringComparison.OrdinalIgnoreCase));

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static EngineResult Parse(string json) =>
        JsonSerializer.Deserialize<EngineResult>(json, Json) ?? throw new InvalidDataException("Result file is empty.");
}

public sealed class BackupEntry
{
    public string Kind { get; init; } = "";
    public string Path { get; init; } = "";
    public string Restore { get; init; } = "";
}

public sealed class AuditEntry
{
    public string Section { get; init; } = "";
    public string Item { get; init; } = "";

    /// <summary>"Set", "NotSet" or "NA".</summary>
    public string State { get; init; } = "";
    public string? Detail { get; init; }
}
