using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WOSetup.Core.Actions;

/// <summary>
/// Result file of Engine/WO-Actions.ps1: { Status, Warnings, Data }.
/// </summary>
public sealed class ActionResult
{
    public string Status { get; init; } = "";
    public List<string> Warnings { get; init; } = [];

    /// <summary>Query output (list-disks, list-adapters); empty for the actions.</summary>
    public JsonElement Data { get; init; }

    public bool Failed => !string.Equals(Status, "Completed", StringComparison.OrdinalIgnoreCase);

    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    public static ActionResult Parse(string json)
    {
        var r = JsonSerializer.Deserialize<ActionResult>(json, Json) ?? throw new InvalidDataException("Result file is empty.");
        return r;
    }

    /// <summary>
    /// Data as a list. Windows PowerShell 5.1 sometimes writes an array as
    /// { "value": [...], "Count": n } and a single object without brackets;
    /// both are accepted.
    /// </summary>
    public List<T> DataList<T>()
    {
        var d = Data;
        if (d.ValueKind == JsonValueKind.Object && d.TryGetProperty("value", out var inner)) d = inner;
        return d.ValueKind switch
        {
            JsonValueKind.Array => d.Deserialize<List<T>>(Json) ?? [],
            JsonValueKind.Object => [d.Deserialize<T>(Json)!],
            _ => [],
        };
    }
}

/// <summary>A disk the wizard may initialise: RAW, not boot/system, not USB (list-disks).</summary>
public sealed class DiskInfo
{
    public int Number { get; init; }
    public string Name { get; init; } = "";
    public long SizeGB { get; init; }
    public string BusType { get; init; } = "";

    public override string ToString() => $"Disk {Number}: {Name}, {SizeGB} GB, {BusType}";
}

/// <summary>A physical network adapter and its current IPv4 settings (list-adapters).</summary>
public sealed class AdapterInfo
{
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";
    public string Status { get; init; } = "";
    public string Dhcp { get; init; } = "";
    public string IPAddress { get; init; } = "";
    public int PrefixLength { get; init; } = 24;
    public string Gateway { get; init; } = "";
    public string Dns { get; init; } = "";
}

/// <summary>A recovery USB stick plugged in (list-recovery-usb; made by tools/recovery/New-RecoveryUsb.ps1).</summary>
public sealed class RecoveryUsbInfo
{
    public string Letter { get; init; } = "";
    public string Label { get; init; } = "";
    public long FreeGB { get; init; }

    /// <summary>Default folder for this machine's images on the stick: Images\&lt;COMPUTERNAME&gt;.</summary>
    public string Destination { get; init; } = "";
}

/// <summary>Inputs of the factory-recovery actions (owner, Nov 2026; OPEN_QUESTIONS 29).</summary>
public static partial class RecoveryInputs
{
    /// <summary>
    /// Keys the boot manager can bind (WO-Actions.ps1 ConvertTo-BootKeyAction), recommended first.
    /// F1, F2 and F12 are left to the firmware (setup, boot menu).
    /// </summary>
    public static readonly IReadOnlyList<string> Keys = ["F9", "F10", "F11", "F8"];

    // Same rule as Test-ImageName in recovery/partition/WO-Recovery.ps1.
    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")]
    private static partial Regex ImageNameRx();

    public static IReadOnlyList<string> ValidateImageName(string name) =>
        ImageNameRx().IsMatch(name) ? [] :
        ["Image name: letters, digits, dot, underscore and hyphen, up to 80 characters, no spaces (e.g. WO7.8.4_W11-25H2_2026-11-20)."];

    /// <summary>Suggested name; the operator adds the WATCHOUT version (WO7.8.4_...).</summary>
    public static string DefaultImageName(string profile, DateOnly date) => $"{profile}_W11-25H2_{date:yyyy-MM-dd}";

    /// <summary>
    /// The RAID0's drive letter: where the working directory (or else the WATCHOUT folder)
    /// is, D when neither is a local path.
    /// </summary>
    public static string DataDrive(string? workingDirectory, string? watchoutPath)
    {
        foreach (var path in new[] { workingDirectory, watchoutPath })
            if (path is { Length: >= 3 } && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\'
                && char.ToUpperInvariant(path[0]) != 'C')
                return char.ToUpperInvariant(path[0]).ToString();
        return "D";
    }
}

/// <summary>Input of media-disk-init.</summary>
public sealed record MediaDiskInput(int DiskNumber, string Label, int AllocationUnitSize)
{
    public static readonly int[] AllowedUnits = [4096, 65536];

    public IReadOnlyList<string> Validate()
    {
        var e = new List<string>();
        if (DiskNumber < 0) e.Add("Choose a disk.");
        if (!AllowedUnits.Contains(AllocationUnitSize)) e.Add("Allocation unit must be 4 KB or 64 KB.");
        // NTFS labels: up to 32 characters, none of these.
        if (Label.Length > 32 || Label.IndexOfAny(['*', '?', '/', '\\', '|', ',', ';', ':', '+', '=', '<', '>', '[', ']', '"']) >= 0)
            e.Add("Label: up to 32 characters, no * ? / \\ | , ; : + = < > [ ] \".");
        return e;
    }

    public Dictionary<string, object> ToParams() => new()
    {
        ["DiskNumber"] = DiskNumber, ["Label"] = Label, ["AllocationUnitSize"] = AllocationUnitSize,
    };
}

/// <summary>One adapter's static address for the static-ip action.</summary>
public sealed record StaticIpEntry(string Name, string IPAddress, int PrefixLength, string Gateway, string Dns)
{
    public IReadOnlyList<string> Validate()
    {
        var e = new List<string>();
        if (!TryV4(IPAddress, out var ip)) { e.Add($"{Name}: '{IPAddress}' is not an IPv4 address."); return e; }
        if (PrefixLength is < 1 or > 32) e.Add($"{Name}: prefix length must be 1-32.");
        if (Gateway.Length > 0)
        {
            if (!TryV4(Gateway, out var gw)) e.Add($"{Name}: gateway '{Gateway}' is not an IPv4 address.");
            else if (PrefixLength is >= 1 and <= 32 && !SameSubnet(ip, gw, PrefixLength))
                e.Add($"{Name}: gateway {Gateway} is not in {IPAddress}/{PrefixLength}.");
        }
        foreach (var d in DnsList.Where(d => !TryV4(d, out _)))
            e.Add($"{Name}: DNS '{d}' is not an IPv4 address.");
        return e;
    }

    public IEnumerable<string> DnsList => Dns.Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries);

    public Dictionary<string, object> ToParams() => new()
    {
        ["Name"] = Name, ["IPAddress"] = IPAddress.Trim(), ["PrefixLength"] = PrefixLength,
        ["Gateway"] = Gateway.Trim(), ["Dns"] = string.Join(",", DnsList),
    };

    public override string ToString() =>
        $"{Name}: {IPAddress}/{PrefixLength}" + (Gateway.Length > 0 ? $", gateway {Gateway}" : ", no gateway") +
        (Dns.Length > 0 ? $", DNS {string.Join(", ", DnsList)}" : ", no DNS");

    private static bool TryV4(string s, out uint value)
    {
        value = 0;
        if (!System.Net.IPAddress.TryParse(s.Trim(), out var a) || a.AddressFamily != AddressFamily.InterNetwork) return false;
        // IPAddress.TryParse accepts "1" or "1.2"; require four parts.
        if (s.Trim().Split('.').Length != 4) return false;
        var b = a.GetAddressBytes();
        value = (uint)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
        return true;
    }

    private static bool SameSubnet(uint a, uint b, int prefix)
    {
        var mask = prefix == 32 ? uint.MaxValue : ~(uint.MaxValue >> prefix);
        return (a & mask) == (b & mask);
    }

    /// <summary>Two adapters in the same subnet confuse routing; WATCHOUT wants the show adapters on one subnet.</summary>
    public static IReadOnlyList<string> ValidateAll(IReadOnlyList<StaticIpEntry> entries)
    {
        var e = entries.SelectMany(x => x.Validate()).ToList();
        if (entries.Count == 0) e.Add("Tick at least one adapter.");
        foreach (var dup in entries.GroupBy(x => x.IPAddress.Trim()).Where(g => g.Count() > 1))
            e.Add($"{dup.Key} is used on more than one adapter.");
        if (entries.Count(x => x.Gateway.Length > 0) > 1)
            e.Add("Only one adapter should have a default gateway.");
        return e;
    }
}

/// <summary>
/// Plain-language summary shown before each wizard action (AGENTS.md rule 3).
/// TypedWord = what the operator must type; null = a normal confirmation.
/// </summary>
public static class ActionSummaryBuilder
{
    public sealed record Summary(string Title, IReadOnlyList<string> Lines, string? TypedWord);

    public static Summary BitLockerOff() => new("BitLocker / device encryption off",
    [
        "Runs manage-bde -off on the system drive if it is encrypted. Nothing happens if it is already decrypted.",
        "Decryption runs in the background and can take a while; the machine stays usable. The step is done when the check reports the drive fully decrypted.",
        "Security: the system drive will no longer be encrypted. This is intended for show machines (a BIOS or RAID change could otherwise stop the boot at a recovery-key prompt).",
    ], "DECRYPT");

    public static Summary MediaDisk(DiskInfo disk, MediaDiskInput input) => new($"Initialise and format disk {disk.Number}",
    [
        $"{disk}.",
        $"The disk is initialised as GPT and gets one NTFS partition over the whole disk, label \"{input.Label}\", {input.AllocationUnitSize / 1024} KB clusters, with the next free drive letter.",
        "Only an empty disk (no partition table at all) is accepted; the boot/system disk and USB disks are refused. The script checks this again just before writing.",
        "Anything on this disk is lost. Nothing else is touched.",
    ], $"DISK {disk.Number}");

    public static Summary IndexingOff() => new("Indexing off on the data drives",
    [
        "Clears \"Allow files on this drive to have contents indexed\" on every fixed drive except the system drive (guide 10.15).",
        "Nothing is deleted. It can be switched back in the drive's Properties.",
    ], null);

    public static Summary StaticIp(IReadOnlyList<StaticIpEntry> entries) => new("Static IPv4 addresses",
    [
        .. entries.Select(e => e.ToString()),
        "DHCP is turned off on these adapters and their current IPv4 addresses and default route are replaced.",
        "Each adapter's link resets briefly. If you are connected remotely through one of them, you will lose the connection.",
    ], "APPLY");

    public static Summary RecoveryInstall(string key, string sourceFolder, string dataDrive) => new("Install the recovery boot",
    [
        $"Copies the recovery WinPE from {sourceFolder} and WO-Recovery.ps1 to the hidden WO_RECOVERY partition (made in Windows Setup), with target.json naming C: and {dataDrive}: by their partition IDs.",
        "Adds the boot entry \"WATCHOUT Factory Recovery\" (not in the boot menu). The boot configuration is backed up first; restore with bcdedit /import.",
        $"Ways in before Windows starts: {key} at power-on, and automatically after failed starts. [Uncertain] Both must be tested on this machine model; the USB stick always works.",
        "Puts \"Factory recovery.cmd\" on the Public Desktop: restarts once into the recovery from a running Windows.",
        "Nothing is erased. Running it again replaces the earlier entry.",
    ], "BOOT");

    public static Summary RecoveryCapture(string name, string dataDrive) => new($"Capture the factory image \"{name}\"",
    [
        $"Checks that C: and {dataDrive}: are not encrypted, that {dataDrive}: holds only the WATCHOUT folder and an empty working directory, and that the recovery partition has room.",
        $"Restarts in 30 seconds into the recovery, which captures C: and {dataDrive}: and then restarts into Windows by itself. This can take a long time: do not switch the machine off.",
        "The current factory image becomes the fallback and an older fallback is deleted (first, if room is short).",
        "A factory reset returns the machine to exactly this state: capture only before any show or asset is loaded.",
        "Start the wizard again afterwards; this step is checked then.",
    ], "CAPTURE");

    public static Summary RecoveryExport(string destination) => new("Copy the factory image off the machine",
    [
        $"Copies the factory image (C: and D: files) to {destination} and checks the copy with SHA-256.",
        "An older copy in that folder becomes its fallback. Nothing else is touched.",
        "Keep the copy away from the machine: an image on the same array as C: does not survive an array failure.",
    ], null);

    public static Summary WolEnable() => new("Wake on Magic Packet",
    [
        "Sets the advanced property \"Wake on Magic Packet\" to Enabled on every physical adapter that has it (guide 10.11).",
        "The adapter's link resets briefly when the value changes.",
        "Wake-on-LAN must also be enabled in the BIOS: that part stays manual.",
    ], null);
}
