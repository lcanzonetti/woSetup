namespace WOSetup.Core.Scripts;

public enum LineKind { Text, StepHeader, Ok, Warning, NotPresent, Info, Set, NotSet, NotApplicable, Fatal, Error }

/// <summary>
/// Classifies the scripts' console lines by their fixed prefixes
/// ("=== ", "  [OK]   ", "  [WARN] ", ...). Used to colour the live log and
/// to cross-check the result file's warning count ("never pretend").
/// </summary>
public static class EngineOutputParser
{
    public static LineKind Classify(string line)
    {
        var t = line.TrimStart();
        if (t.StartsWith("=== ", StringComparison.Ordinal)) return LineKind.StepHeader;
        if (t.StartsWith("[OK]", StringComparison.Ordinal)) return LineKind.Ok;
        if (t.StartsWith("[WARN]", StringComparison.Ordinal)) return LineKind.Warning;
        if (t.StartsWith("[--]", StringComparison.Ordinal)) return LineKind.NotPresent;
        if (t.StartsWith("[i]", StringComparison.Ordinal)) return LineKind.Info;
        if (t.StartsWith("[SET]", StringComparison.Ordinal)) return LineKind.Set;
        if (t.StartsWith("[NOT SET]", StringComparison.Ordinal)) return LineKind.NotSet;
        if (t.StartsWith("[N/A]", StringComparison.Ordinal)) return LineKind.NotApplicable;
        if (t.StartsWith("[FATAL]", StringComparison.Ordinal)) return LineKind.Fatal;
        return LineKind.Text;
    }

    /// <summary>
    /// Warnings counted from the console, for comparison with the result
    /// file. "Result file not written" is the result writer's own line and is
    /// not one of the script's warnings.
    /// </summary>
    public static int CountWarnings(IEnumerable<string> lines) =>
        lines.Count(l => Classify(l) == LineKind.Warning && !l.Contains("Result file not written", StringComparison.Ordinal));
}
