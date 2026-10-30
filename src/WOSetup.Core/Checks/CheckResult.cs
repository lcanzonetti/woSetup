using System.Text.Json;
using System.Text.Json.Serialization;
using WOSetup.Core.Scripts;

namespace WOSetup.Core.Checks;

/// <summary>Outcome of a read-only check (Engine/WO-Checks.ps1, a native check, or a script audit).</summary>
public enum CheckState { Done, NotDone, NotApplicable, CantCheck }

public sealed record CheckResult(string Id, CheckState State, string Detail)
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    /// <summary>Reads WO-Checks.ps1's result file (a JSON array of { Id, State, Detail }).</summary>
    public static List<CheckResult> ParseMany(string json)
    {
        var list = JsonSerializer.Deserialize<List<CheckResult>>(json, Json) ?? [];
        return list.Select(r => r with { Detail = r.Detail ?? "" }).ToList();
    }

    /// <summary>
    /// A script audit as a check: done only when the run completed and no
    /// item is "Not set". A failed or missing audit can never be "done".
    /// </summary>
    public static CheckResult FromAudits(string id, IReadOnlyList<(string Phase, EngineResult? Result)> audits)
    {
        var notSet = new List<string>();
        foreach (var (phase, r) in audits)
        {
            if (r is null) return new CheckResult(id, CheckState.CantCheck, $"The {phase} audit wrote no result.");
            if (r.Failed) return new CheckResult(id, CheckState.CantCheck, $"The {phase} audit failed: {r.Fatal}");
            notSet.AddRange(r.Audit.Where(a => a.State == "NotSet").Select(a => $"{phase}: {a.Item}"));
        }
        var set = audits.Sum(a => a.Result!.AuditCount("Set"));
        if (notSet.Count == 0)
            return new CheckResult(id, CheckState.Done, $"Audit: {set} item(s) set, none missing.");
        // Say what was found as well as what is missing: a step done partly by
        // hand (e.g. two of the three PreUpdate settings) must not read as "nothing found".
        var first = string.Join("; ", notSet.Take(5));
        return new CheckResult(id, CheckState.NotDone,
            $"Audit: {set} item(s) already set, {notSet.Count} NOT set: {first}{(notSet.Count > 5 ? $"; ... ({notSet.Count - 5} more in the audit list)" : "")}. " +
            "Running the step sets only what is missing.");
    }
}
