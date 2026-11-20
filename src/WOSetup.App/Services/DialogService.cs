using System.Windows;
using Microsoft.Win32;
using WOSetup.App.Views;
using WOSetup.Core.Actions;

namespace WOSetup.App.Services;

/// <summary>Dialogs used by the view models, kept behind an interface so the view models hold no window code.</summary>
public interface IDialogService
{
    /// <summary>Shows the lines; with <paramref name="typedWord"/> the operator must type it to continue.</summary>
    bool Confirm(string title, string intro, IReadOnlyList<string> lines, string? typedWord, string okText);

    /// <summary>Asks for a short text (e.g. a reason), pre-filled with <paramref name="initial"/>. Null when cancelled; empty input is refused.</summary>
    string? Prompt(string title, string message, string initial = "");

    /// <summary>Buttons in a row; returns the index pressed, -1 when the window is closed.</summary>
    int Choose(string title, string intro, IReadOnlyList<string> lines, IReadOnlyList<string> buttons);

    /// <summary>Tick several items; null when cancelled.</summary>
    IReadOnlyList<string>? PickMany(string title, string intro, IReadOnlyList<(string Id, string Text)> items, string okText);

    /// <summary>Disk and format settings for the media drive; null when cancelled.</summary>
    (DiskInfo Disk, MediaDiskInput Input)? PickMediaDisk(IReadOnlyList<DiskInfo> disks);

    /// <summary>Static addresses for the ticked adapters; null when cancelled.</summary>
    IReadOnlyList<StaticIpEntry>? EditStaticIps(IReadOnlyList<AdapterInfo> adapters);

    void Info(string title, string message);
    void Error(string title, string message);
    string? SaveFile(string title, string fileName, string filter);
}

public sealed class DialogService : IDialogService
{
    private static Window? Owner => Application.Current?.MainWindow is { IsVisible: true } w ? w : null;

    public bool Confirm(string title, string intro, IReadOnlyList<string> lines, string? typedWord, string okText)
    {
        var dlg = new ConfirmWindow(title, intro, lines, typedWord, okText) { Owner = Owner };
        return dlg.ShowDialog() == true;
    }

    public string? Prompt(string title, string message, string initial = "")
    {
        var dlg = new PromptWindow(title, message, initial) { Owner = Owner };
        return dlg.ShowDialog() == true ? dlg.Answer : null;
    }

    public int Choose(string title, string intro, IReadOnlyList<string> lines, IReadOnlyList<string> buttons)
    {
        var dlg = new ChoiceWindow(title, intro, lines, buttons) { Owner = Owner };
        return dlg.ShowDialog() == true ? dlg.Choice : -1;
    }

    public IReadOnlyList<string>? PickMany(string title, string intro, IReadOnlyList<(string Id, string Text)> items, string okText)
    {
        var dlg = new PickManyWindow(title, intro, items, okText) { Owner = Owner };
        return dlg.ShowDialog() == true ? dlg.Selected : null;
    }

    public (DiskInfo Disk, MediaDiskInput Input)? PickMediaDisk(IReadOnlyList<DiskInfo> disks)
    {
        var dlg = new DiskPickerWindow(disks) { Owner = Owner };
        return dlg.ShowDialog() == true && dlg.Result is { } r && dlg.Disk is { } d ? (d, r) : null;
    }

    public IReadOnlyList<StaticIpEntry>? EditStaticIps(IReadOnlyList<AdapterInfo> adapters)
    {
        var dlg = new StaticIpWindow(adapters) { Owner = Owner };
        return dlg.ShowDialog() == true ? dlg.Result : null;
    }

    public void Info(string title, string message) => Show(title, message, MessageBoxImage.Information);

    public void Error(string title, string message) => Show(title, message, MessageBoxImage.Warning);

    private static void Show(string title, string message, MessageBoxImage icon)
    {
        if (Owner is { } owner) MessageBox.Show(owner, message, title, MessageBoxButton.OK, icon);
        else MessageBox.Show(message, title, MessageBoxButton.OK, icon);
    }

    public string? SaveFile(string title, string fileName, string filter)
    {
        var dlg = new SaveFileDialog { Title = title, FileName = fileName, Filter = filter, OverwritePrompt = true };
        return dlg.ShowDialog(Owner) == true ? dlg.FileName : null;
    }
}
