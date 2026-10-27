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
        var ids = flow.AllSteps.Select(s => s.Id).ToList();
        foreach (var dup in ids.GroupBy(i => i).Where(g => g.Count() > 1))
            errors.Add($"Duplicate step id {dup.Key}");

        // Sections must follow the checklist order.
        for (var i = 1; i < flow.Sections.Count; i++)
            if (flow.Sections[i].Number <= flow.Sections[i - 1].Number)
                errors.Add($"Section {flow.Sections[i].Id} is out of order");

        foreach (var step in flow.AllSteps)
        {
            if (string.IsNullOrWhiteSpace(step.Title)) errors.Add($"{step.Id}: empty title");
            if (step.Roles.Count == 0) errors.Add($"{step.Id}: applies to no role");
            if (step.RebootStep && step.Kind != StepKind.Manual) errors.Add($"{step.Id}: reboot steps must be manual");
            if (step.Engine is { Audit: false } && step.Kind != StepKind.Automated)
                errors.Add($"{step.Id}: a real script run must be an automated step");
            if (step.Engine is { Audit: true } && step.Kind != StepKind.Check)
                errors.Add($"{step.Id}: an audit must be a check step");
            if (step.Engine is { Audit: false, Phase: EnginePhase.Both })
                errors.Add($"{step.Id}: only audits can cover both phases");
        }

        // Each profile must contain exactly one real run of each phase.
        foreach (var phase in new[] { EnginePhase.PreUpdate, EnginePhase.PostInstall })
        {
            var n = flow.AllSteps.Count(s => s.Engine is { Audit: false } e && e.Phase == phase);
            if (n != 1) errors.Add($"Expected one {phase} run step, found {n}");
        }

        // PreUpdate must come before PostInstall (AGENTS.md rule 1).
        var pre = ids.FindIndex(id => flow.Find(id)!.Engine is { Audit: false, Phase: EnginePhase.PreUpdate });
        var post = ids.FindIndex(id => flow.Find(id)!.Engine is { Audit: false, Phase: EnginePhase.PostInstall });
        if (pre >= 0 && post >= 0 && pre > post) errors.Add("PreUpdate comes after PostInstall");
        return errors;
    }
}
