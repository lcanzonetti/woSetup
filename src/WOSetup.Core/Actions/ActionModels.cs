using System.Net;
using System.Net.Sockets;
using System.Text.Json;

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

    public static Summary WolEnable() => new("Wake on Magic Packet",
    [
        "Sets the advanced property \"Wake on Magic Packet\" to Enabled on every physical adapter that has it (guide 10.11).",
        "The adapter's link resets briefly when the value changes.",
        "Wake-on-LAN must also be enabled in the BIOS: that part stays manual.",
    ], null);
}
