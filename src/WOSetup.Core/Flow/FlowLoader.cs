using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WOSetup.Core.Flow;

/// <summary>Loads the embedded step lists (flows/wo7.flow.json, flows/wo6.flow.json).</summary>
public static class FlowLoader
{
    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        // The generator writes "kind" after "id" and "title".
        AllowOutOfOrderMetadataProperties = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static FlowDefinition Load(Profile profile)
    {
        var name = $"flows/{profile.ToString().ToLowerInvariant()}.flow.json";
        using var stream = typeof(FlowLoader).Assembly.GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"Embedded flow '{name}' not found.");
        return Parse(stream);
    }

    public static FlowDefinition Parse(Stream json)
    {
        var flow = JsonSerializer.Deserialize<FlowDefinition>(json, Json)
            ?? throw new InvalidDataException("Flow file is empty.");
        foreach (var section in flow.Sections)
            foreach (var step in section.Steps)
                step.Section = section;
        return flow;
    }
}

/// <summary>Consistency checks on a flow; a unit test runs them on both embedded flows.</summary>
public static class FlowValidator
{
    public static IReadOnlyList<string> Validate(FlowDefinition flow)
    {
        var errors = new List<string>();
        var steps = flow.AllSteps.ToList();
        var ids = steps.Select(s => s.Id).ToList();
        foreach (var dup in ids.GroupBy(i => i).Where(g => g.Count() > 1))
            errors.Add($"Duplicate step id {dup.Key}");

        // Sections must follow the checklist order.
        for (var i = 1; i < flow.Sections.Count; i++)
            if (flow.Sections[i].Number <= flow.Sections[i - 1].Number)
                errors.Add($"Section {flow.Sections[i].Id} is out of order");

        foreach (var s in steps)
        {
            if (string.IsNullOrWhiteSpace(s.Title)) errors.Add($"{s.Id}: empty title");
            if (s.Roles.Count == 0) errors.Add($"{s.Id}: applies to no role");
            if (s.Kind == StepKind.Automated && s.Action is null && !s.AutoDone) errors.Add($"{s.Id}: automated step without an action");
            if (s.Kind != StepKind.Automated && s.Action is not null) errors.Add($"{s.Id}: only automated steps have an action");
            if (s.Kind == StepKind.Check && !s.HasCheck) errors.Add($"{s.Id}: check step without a check");
            if (s.IsAuditCheck && s.AuditPhase is null) errors.Add($"{s.Id}: unknown audit '{s.Check}'");
            if (s.IsScriptRun && s.Action!.Phase is not (EnginePhase.PreUpdate or EnginePhase.PostInstall))
                errors.Add($"{s.Id}: a script run needs PreUpdate or PostInstall");
            if (s.IsCommand && string.IsNullOrWhiteSpace(s.Action!.Name)) errors.Add($"{s.Id}: command without a name");
            if (s.After is not null && !ids.Contains(s.After)) errors.Add($"{s.Id}: 'after' points to unknown step {s.After}");
        }

        // Exactly one real run of each phase.
        foreach (var phase in new[] { EnginePhase.PreUpdate, EnginePhase.PostInstall })
        {
            var n = steps.Count(s => s.IsScriptRun && s.Action!.Phase == phase);
            if (n != 1) errors.Add($"Expected one {phase} run step, found {n}");
        }

        // PreUpdate before PostInstall (AGENTS.md rule 1).
        var pre = steps.FindIndex(s => s.IsScriptRun && s.Action!.Phase == EnginePhase.PreUpdate);
        var post = steps.FindIndex(s => s.IsScriptRun && s.Action!.Phase == EnginePhase.PostInstall);
        if (pre >= 0 && post >= 0 && pre > post) errors.Add("PreUpdate comes after PostInstall");
        return errors;
    }
}
