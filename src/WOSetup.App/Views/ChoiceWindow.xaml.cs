using System.Windows;
using System.Windows.Controls;

namespace WOSetup.App.Views;

/// <summary>Text plus a row of buttons; Choice = index of the button pressed, -1 when closed. View logic only.</summary>
public partial class ChoiceWindow : Window
{
    public int Choice { get; private set; } = -1;

    public ChoiceWindow(string title, string intro, IReadOnlyList<string> lines, IReadOnlyList<string> buttons)
    {
        InitializeComponent();
        Title = title;
        IntroText.Text = intro;
        LinesList.ItemsSource = lines;
        for (var i = 0; i < buttons.Count; i++)
        {
            var index = i;
            var b = new Button { Content = buttons[i], MinWidth = 100, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(0, 0, 8, 0) };
            if (i == 0) b.FontWeight = FontWeights.SemiBold;
            b.Click += (_, _) => { Choice = index; DialogResult = true; };
            ButtonsPanel.Children.Add(b);
        }
    }
}
