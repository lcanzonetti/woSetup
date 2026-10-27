using System.Text.Json;
using System.Text.Json.Serialization;

namespace WOSetup.Core.State;

public sealed record StateLoadResult(WizardState? State, string? Warning, string? Error);

/// <summary>
/// Reads and writes state.json. Writes are atomic (temp file, flush to disk,
/// replace, keeping state.json.bak), so a reboot or power cut never leaves a
/// half-written file (ARCHITECTURE §5.1).
/// </summary>
public sealed class JsonStateStore(string path)
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public string Path { get; } = path;
    public string BackupPath => Path + ".bak";

    public bool Exists => File.Exists(Path);

    public StateLoadResult Load()
    {
        if (!File.Exists(Path)) return new StateLoadResult(null, null, null);
        var (state, error) = TryRead(Path);
        if (state is not null) return CheckVersion(state, null);

        // Main file unreadable: fall back to the previous copy, and say so.
        if (File.Exists(BackupPath))
        {
            var (bak, _) = TryRead(BackupPath);
            if (bak is not null)
                return CheckVersion(bak, $"state.json could not be read ({error}); the previous copy (state.json.bak) was used. The last change may be missing.");
        }
        return new StateLoadResult(null, null, $"state.json could not be read: {error}");
    }

    private static StateLoadResult CheckVersion(WizardState state, string? warning) =>
        state.SchemaVersion > WizardState.CurrentSchemaVersion
            ? new StateLoadResult(null, null,
                $"state.json was written by a newer version of the wizard (state schema {state.SchemaVersion}, " +
                $"this version reads up to {WizardState.CurrentSchemaVersion}). Use the newer wizard exe.")
            : new StateLoadResult(state, warning, null);

    private static (WizardState?, string?) TryRead(string file)
    {
        try
        {
            var state = JsonSerializer.Deserialize<WizardState>(File.ReadAllText(file), Json);
            return state is null ? (null, "empty file") : (state, null);
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            return (null, ex.Message);
        }
    }

    public void Save(WizardState state)
    {
        var dir = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(dir);
        var tmp = Path + ".tmp";
        var json = JsonSerializer.Serialize(state, Json);
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var w = new StreamWriter(fs, new System.Text.UTF8Encoding(false)))
        {
            w.Write(json);
            w.Flush();
            fs.Flush(flushToDisk: true);
        }
        if (File.Exists(Path)) File.Replace(tmp, Path, BackupPath);
        else File.Move(tmp, Path);
    }

    /// <summary>"Start over": keeps the old state next to the new one instead of deleting it.</summary>
    public string? Archive(DateTimeOffset now)
    {
        if (!File.Exists(Path)) return null;
        var target = Path.Replace("state.json", $"state_{now:yyyyMMdd_HHmmss}.json.old", StringComparison.Ordinal);
        File.Move(Path, target);
        if (File.Exists(BackupPath)) File.Delete(BackupPath);
        return target;
    }
}
