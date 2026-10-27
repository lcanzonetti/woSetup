using System.Windows;
using Microsoft.Win32;
using WOSetup.App.Views;

namespace WOSetup.App.Services;

/// <summary>Dialogs used by the view models, kept behind an interface so the view models hold no window code.</summary>
public interface IDialogService
{
    /// <summary>Shows the lines; with <paramref name="typedWord"/> the operator must type it to continue.</summary>
    bool Confirm(string title, string intro, IReadOnlyList<string> lines, string? typedWord, string okText);

    /// <summary>Asks for a short text (e.g. a reason). Null when cancelled; empty input is refused.</summary>
    string? Prompt(string title, string message);

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

    public string? Prompt(string title, string message)
    {
        var dlg = new PromptWindow(title, message) { Owner = Owner };
        return dlg.ShowDialog() == true ? dlg.Answer : null;
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
