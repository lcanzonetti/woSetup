using System.Windows;
using System.Windows.Controls;

namespace WOSetup.App.Views;

/// <summary>Asks for a short text such as the reason for skipping a step. View logic only.</summary>
public partial class PromptWindow : Window
{
    public string Answer => AnswerBox.Text.Trim();

    public PromptWindow(string title, string message)
    {
        InitializeComponent();
        Title = title;
        MessageText.Text = message;
        Loaded += (_, _) => AnswerBox.Focus();
    }

    private void OnChanged(object sender, TextChangedEventArgs e) => OkButton.IsEnabled = Answer.Length > 0;

    private void OnOk(object sender, RoutedEventArgs e) => DialogResult = true;
}
