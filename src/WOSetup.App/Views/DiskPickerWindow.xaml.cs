using System.Windows;
using WOSetup.Core.Actions;

namespace WOSetup.App.Views;

/// <summary>Picks the RAW disk and format settings for media-disk-init. View logic only; rules are in MediaDiskInput.</summary>
public partial class DiskPickerWindow : Window
{
    public MediaDiskInput? Result { get; private set; }
    public DiskInfo? Disk => DiskList.SelectedItem as DiskInfo;

    public DiskPickerWindow(IReadOnlyList<DiskInfo> disks)
    {
        InitializeComponent();
        DiskList.ItemsSource = disks;
        if (disks.Count == 1) DiskList.SelectedIndex = 0;
        // Checklist: "format NTFS (64 KB allocation unit optional)".
        UnitBox.ItemsSource = new[] { "64 KB (large media files)", "4 KB (Windows default)" };
        UnitBox.SelectedIndex = 0;
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        var input = new MediaDiskInput(Disk?.Number ?? -1, LabelBox.Text.Trim(), UnitBox.SelectedIndex == 1 ? 4096 : 65536);
        var errors = input.Validate();
        if (errors.Count > 0)
        {
            ErrorText.Text = string.Join("\n", errors);
            return;
        }
        Result = input;
        DialogResult = true;
    }
}
