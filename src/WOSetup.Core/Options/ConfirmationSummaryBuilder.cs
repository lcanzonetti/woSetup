using WOSetup.Core.Flow;

namespace WOSetup.Core.Options;

/// <summary>
/// Plain-language summary shown before a script run (AGENTS.md rule 3: show
/// before changing). Every line describes what the scripts do with these
/// options; it adds nothing the scripts do not do.
/// </summary>
public static class ConfirmationSummaryBuilder
{
    public sealed record Summary(string Title, IReadOnlyList<string> Lines, bool RequiresTypedConfirmation);

    public static Summary Build(Profile profile, Role role, EnginePhase phase, EngineOptions o, bool lgpoAvailable)
    {
        var lines = new List<string>();
        if (phase == EnginePhase.PreUpdate)
        {
            lines.Add("Windows will no longer download drivers by itself: driver search off (SearchOrderConfig = 0), " +
                      "\"Do not include drivers with Windows Updates\" and the driver-search prompt off.");
            lines.Add("Windows Update itself stays on: the next steps install every update.");
            lines.Add("Run this BEFORE plugging in the network cable and before installing any driver.");
            AddLgpo(lines, lgpoAvailable);
            return new Summary("PreUpdate: driver search lockdown", lines, RequiresTypedConfirmation: false);
        }

        // PostInstall
        lines.Add(o.KeepFirewall
            ? (profile == Profile.WO6
                ? "Windows Firewall stays ON; inbound allow rules are added for WATCHPOINT, WATCHMAKER and ImageServer."
                : "Windows Firewall stays ON (WATCHOUT 7 manages its own rules).")
            : "Windows Firewall will be turned OFF on all profiles (guide 7.1).");
        lines.Add(o.DefenderMode switch
        {
            DefenderMode.Off => "Microsoft Defender real-time protection will be turned OFF by policy (guide 7.4.8). " +
                                "Requires Tamper Protection OFF first; WATCHOUT folders are also excluded.",
            DefenderMode.Exclusions => "Microsoft Defender stays ON; WATCHOUT folders and programs are excluded, scheduled scans off.",
            _ => "Microsoft Defender is not touched.",
        });
        lines.Add(o.KeepUpdateService
            ? "Windows Update: automatic updates OFF, feature version pinned, notifications off. The update services keep running."
            : "Windows Update will be DISABLED FOR GOOD: automatic updates off, version pinned, BITS / wuauserv / UsoSvc " +
              "and update tasks disabled, downloaded updates deleted. No security updates from now on.");
        lines.Add("UAC set to \"Never notify\", Remote Assistance off, visual effects for best performance, no sounds, " +
                  "scheduled defrag off, USB and badge notifications off (guide ch. 10).");
        if (profile == Profile.WO7)
        {
            lines.Add("Windows Search service DISABLED: no indexing on any drive (guide 10.15).");
        }
        else
        {
            lines.Add(o.KeepServices
                ? "Guide chapter 11 services are left as they are (-KeepServices)."
                : "Guide chapter 11 services present on this machine (up to 41, incl. Windows Search, Print Spooler, " +
                  "Remote Desktop, Bluetooth, Xbox) will be DISABLED" +
                  (o.KeepService.Count > 0 ? $", except: {string.Join(", ", o.KeepService)}." : "."));
            lines.Add(o.KeepAdapterBindings
                ? "Network adapter bindings are left as they are (-KeepAdapterBindings)."
                : "On every physical network adapter everything except IPv4 will be UNBOUND: file shares and IPv6 stop working there.");
            if (role == Role.Display)
                lines.Add($"WATCHPOINT will start at logon from a scheduled task (delay {o.StartDelay} s).");
        }
        lines.Add("Power plan, network adapter power saving, notifications, policies and registry values from the Dataton guide are applied.");
        lines.Add("Network adapters briefly lose link while their settings change. Do not run during a show.");
        lines.Add("Run it from the show account. Switching an option later does NOT undo what this run applies.");
        AddLgpo(lines, lgpoAvailable);
        return new Summary("PostInstall: OS hardening (security-reducing)", lines, RequiresTypedConfirmation: true);
    }

    private static void AddLgpo(List<string> lines, bool lgpoAvailable)
    {
        if (!lgpoAvailable)
            lines.Add("LGPO.exe NOT FOUND: policies are written directly to the registry (not visible in gpedit; " +
                      "User policies reach only the account running the script).");
    }
}
