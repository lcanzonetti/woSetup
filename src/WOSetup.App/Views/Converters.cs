using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.App.Views;

/// <summary>true → Collapsed, false → Visible.</summary>
public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>Colour of a console line in the live log.</summary>
public sealed class LineKindToBrushConverter : IValueConverter
{
    private static readonly Brush Normal = Frozen(0x20, 0x20, 0x20);

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        LineKind.StepHeader => Frozen(0x00, 0x5A, 0x9E),
        LineKind.Ok or LineKind.Set => Frozen(0x10, 0x7C, 0x10),
        LineKind.Warning or LineKind.NotSet => Frozen(0xB0, 0x5A, 0x00),
        LineKind.Fatal or LineKind.Error => Frozen(0xC4, 0x2B, 0x1C),
        LineKind.NotPresent or LineKind.Info or LineKind.NotApplicable => Frozen(0x70, 0x70, 0x70),
        _ => Normal,
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();

    private static SolidColorBrush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }
}

/// <summary>Colour of a step's status glyph.</summary>
public sealed class StatusToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        StepStatus.Done => Brushes.ForestGreen,
        StepStatus.DoneWithWarnings => Brushes.DarkOrange,
        StepStatus.Failed or StepStatus.Interrupted or StepStatus.NotDone => Brushes.Firebrick,
        StepStatus.InProgress or StepStatus.AwaitingReboot => Brushes.SteelBlue,
        StepStatus.Skipped or StepStatus.NotApplicable => Brushes.Gray,
        _ => Brushes.DimGray,
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>Audit state "Set" / "NotSet" / "NA" to a readable label.</summary>
public sealed class AuditStateTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => (value as string) switch
    {
        "Set" => "Set",
        "NotSet" => "Not set",
        "NA" => "N/A",
        var s => s ?? "",
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
