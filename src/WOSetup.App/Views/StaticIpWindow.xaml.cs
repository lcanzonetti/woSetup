using System.Windows;
using WOSetup.Core.Actions;

namespace WOSetup.App.Views;

/// <summary>One editable adapter row.</summary>
public sealed class StaticIpRow
{
    public bool Use { get; set; }
    public string Name { get; init; } = "";
    public string Current { get; init; } = "";
    public string IPAddress { get; set; } = "";
    public string PrefixLength { get; set; } = "24";
    public string Gateway { get; set; } = "";
    public string Dns { get; set; } = "";
}

/// <summary>Collects the static-ip input. View logic only; validation is StaticIpEntry.ValidateAll.</summary>
public partial class StaticIpWindow : Window
{
    private readonly List<StaticIpRow> _rows;
    public IReadOnlyList<StaticIpEntry>? Result { get; private set; }

    public StaticIpWindow(IReadOnlyList<AdapterInfo> adapters)
    {
        InitializeComponent();
        _rows = adapters.Select(a => new StaticIpRow
        {
            Name = a.Name,
            Current = $"{a.Description} · {a.Status} · " +
                      (a.Dhcp == "Enabled" ? "DHCP" : "static") + (a.IPAddress.Length > 0 ? $" {a.IPAddress}/{a.PrefixLength}" : ""),
            // A DHCP or self-assigned (169.254) address is not a useful start value.
            IPAddress = a.Dhcp == "Disabled" && !a.IPAddress.StartsWith("169.254.", StringComparison.Ordinal) ? a.IPAddress : "",
            PrefixLength = a.PrefixLength.ToString(),
            Gateway = a.Dhcp == "Disabled" ? a.Gateway : "",
            Dns = a.Dhcp == "Disabled" ? a.Dns : "",
            Use = false,
        }).ToList();
        Rows.ItemsSource = _rows;
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        var errors = new List<string>();
        var entries = new List<StaticIpEntry>();
        foreach (var r in _rows.Where(r => r.Use))
        {
            if (!int.TryParse(r.PrefixLength.Trim(), out var prefix)) { errors.Add($"{r.Name}: prefix length must be a number."); continue; }
            entries.Add(new StaticIpEntry(r.Name, r.IPAddress.Trim(), prefix, r.Gateway.Trim(), r.Dns.Trim()));
        }
        errors.AddRange(StaticIpEntry.ValidateAll(entries));
        if (errors.Count > 0)
        {
            ErrorText.Text = string.Join("\n", errors.Distinct());
            return;
        }
        Result = entries;
        DialogResult = true;
    }
}
