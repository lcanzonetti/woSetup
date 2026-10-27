using System.Text.RegularExpressions;

namespace WOSetup.Core.Flow;

/// <summary>
/// Finds the Windows consoles and settings pages a step mentions (e.g.
/// ncpa.cpl, ms-settings:display), so the step can offer an "Open" button.
/// Only these kinds of targets are matched: a button can open a settings
/// page or console, never run a command.
/// </summary>
public static partial class OpenTargets
{
    [GeneratedRegex(@"(?<![\w\\/.-])(?<t>[A-Za-z0-9]+\.(?:msc|cpl)|ms-settings:[a-z0-9\-]+|windowsdefender://[a-z]+|netplwiz|dfrgui|UserAccountControlSettings\.exe|SystemProperties[A-Za-z]+\.exe)(?![\w-])")]
    private static partial Regex Target();

    public static IReadOnlyList<string> Extract(string text)
    {
        var found = new List<string>();
        foreach (Match m in Target().Matches(text))
        {
            var t = m.Groups["t"].Value;
            if (!found.Contains(t, StringComparer.OrdinalIgnoreCase)) found.Add(t);
        }
        return found;
    }
}
