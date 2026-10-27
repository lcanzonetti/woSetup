using WOSetup.Core.Flow;
using WOSetup.Core.Options;
using WOSetup.Core.Scripts;

namespace WOSetup.Core.Checks;

/// <summary>
/// What "Check this machine" has to run for a set of steps, and how the
/// answers map back to steps. Several steps can share one check (e.g. the
/// BitLocker step and its verification later): each check runs once.
/// </summary>
public sealed class CheckPlan
{
    /// <summary>Checks done inside the wizard itself, not by WO-Checks.ps1.</summary>
    public static readonly IReadOnlySet<string> NativeChecks = new HashSet<string> { "lgpo", "display-scale" };

    public IReadOnlyList<StepDefinition> Steps { get; }

    /// <summary>Ids for Engine/WO-Checks.ps1, de-duplicated, in step order.</summary>
    public IReadOnlyList<string> ScriptChecks { get; }
    public IReadOnlyList<string> Native { get; }

    /// <summary>Script phases whose -Audit is needed (PreUpdate, PostInstall).</summary>
    public IReadOnlyList<EnginePhase> AuditPhases { get; }

    public CheckPlan(IEnumerable<StepDefinition> steps)
    {
        Steps = steps.Where(s => s.HasCheck).ToList();
        ScriptChecks = Steps.Where(s => !s.IsAuditCheck && !NativeChecks.Contains(s.Check!)).Select(s => s.Check!).Distinct().ToList();
        Native = Steps.Where(s => NativeChecks.Contains(s.Check!)).Select(s => s.Check!).Distinct().ToList();
        var phases = new List<EnginePhase>();
        foreach (var p in Steps.Where(s => s.IsAuditCheck).Select(s => s.AuditPhase))
        {
            if (p is EnginePhase.PreUpdate or EnginePhase.Both && !phases.Contains(EnginePhase.PreUpdate)) phases.Add(EnginePhase.PreUpdate);
            if (p is EnginePhase.PostInstall or EnginePhase.Both && !phases.Contains(EnginePhase.PostInstall)) phases.Add(EnginePhase.PostInstall);
        }
        AuditPhases = phases;
    }

    /// <summary>
    /// One result per step. <paramref name="byCheck"/> holds script and native
    /// results by check id; <paramref name="audits"/> the audit results by phase
    /// (null = the audit wrote no result). A check that produced nothing is
    /// "can't check", never "done".
    /// </summary>
    public List<CheckResult> ForSteps(IReadOnlyDictionary<string, CheckResult> byCheck,
                                      IReadOnlyDictionary<EnginePhase, EngineResult?> audits)
    {
        var list = new List<CheckResult>();
        foreach (var s in Steps)
        {
            if (s.IsAuditCheck)
            {
                var phases = s.AuditPhase == EnginePhase.Both ? new[] { EnginePhase.PreUpdate, EnginePhase.PostInstall } : [s.AuditPhase!.Value];
                var parts = phases.Select(p => (p.ToString(), audits.TryGetValue(p, out var r) ? r : null)).ToList();
                list.Add(CheckResult.FromAudits(s.Id, parts));
            }
            else if (byCheck.TryGetValue(s.Check!, out var r))
            {
                list.Add(r with { Id = s.Id });
            }
            else
            {
                list.Add(new CheckResult(s.Id, CheckState.CantCheck, $"The check '{s.Check}' returned no result."));
            }
        }
        return list;
    }
}

/// <summary>Context passed to WO-Checks.ps1 (-ParamsJson): the checks depend on the profile and some options.</summary>
public static class CheckContext
{
    public static Dictionary<string, object> Build(Profile profile, Role role, EngineOptions o) => new()
    {
        ["Profile"] = profile.ToString(),
        ["Role"] = role.ToString(),
        ["Options"] = new Dictionary<string, object?>
        {
            ["DefenderMode"] = o.DefenderMode.ToString(),
            ["KeepUpdateService"] = o.KeepUpdateService,
            ["WorkingDirectory"] = o.WorkingDirectory,
            ["WatchoutPath"] = o.WatchoutPath,
            ["ShowsPath"] = o.ShowsPath,
        },
    };
}
