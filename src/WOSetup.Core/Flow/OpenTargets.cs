using System.Text.RegularExpressions;

namespace WOSetup.Core.Flow;

/// <summary>
/// Finds the Windows tools a step tells the operator to open (e.g. `ncpa.cpl`,
/// `ms-settings:display`), so the step can offer an "Open" button. Only
/// "Open ..." mentions are used, never commands from checks, so a button can
/// only open a settings page or console, not run anything.
/// </summary>
public static partial class OpenTargets
{
    [GeneratedRegex(@"`(?<t>[A-Za-z0-9]+\.(?:msc|cpl)|ms-settings:[a-z0-9\-]+|windowsdefender://[a-z]+|netplwiz|dfrgui|UserAccountControlSettings\.exe|SystemProperties[A-Za-z]+\.exe)`")]
    private static partial Regex Target();

    public static IReadOnlyList<string> Extract(string text)
    {
        var found = new List<string>();
        foreach (Match m in Target().Matches(text))
        {
            var t = m.Groups["t"].Value;
            // A target is offered only when the text says to open it (or it is a settings page).
            var before = text[..m.Index];
            var opens = before.LastIndexOf("Open", StringComparison.OrdinalIgnoreCase) >= Math.Max(0, before.Length - 60)
                        || t.StartsWith("ms-settings:", StringComparison.Ordinal);
            if (opens && !found.Contains(t, StringComparer.OrdinalIgnoreCase)) found.Add(t);
        }
        return found;
    }
}
