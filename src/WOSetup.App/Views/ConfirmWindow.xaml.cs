using System.Windows;
using System.Windows.Controls;

namespace WOSetup.App.Views;

/// <summary>
/// "Show before changing" (AGENTS.md rule 3): the plain-language list of what
/// will change. For security-reducing steps the OK button only enables once
/// the operator has typed the confirmation word. View logic only.
/// </summary>
public partial class ConfirmWindow : Window
{
    private readonly string? _typedWord;

    public ConfirmWindow(string title, string intro, IReadOnlyList<string> lines, string? typedWord, string okText)
    {
        InitializeComponent();
        Title = title;
        IntroText.Text = intro;
        LinesList.ItemsSource = lines;
        OkButton.Content = okText;
        _typedWord = typedWord;
        if (typedWord is not null)
        {
            TypedPanel.Visibility = Visibility.Visible;
            TypedLabel.Text = $"Type {typedWord} to continue:";
            OkButton.IsEnabled = false;
            Loaded += (_, _) => TypedBox.Focus();
        }
    }

    private void OnTypedChanged(object sender, TextChangedEventArgs e) =>
        OkButton.IsEnabled = string.Equals(TypedBox.Text.Trim(), _typedWord, StringComparison.Ordinal);

    private void OnOk(object sender, RoutedEventArgs e) => DialogResult = true;
}
