using System.ComponentModel;
using System.Windows;

namespace WOSetup.App.Views;

public sealed class PickItem(string id, string text) : INotifyPropertyChanged
{
    private bool _isChecked;
    public string Id { get; } = id;
    public string Text { get; } = text;

    public bool IsChecked
    {
        get => _isChecked;
        set { _isChecked = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked))); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>Tick several items (e.g. manual steps already done in the past). Nothing is ticked by default. View logic only.</summary>
public partial class PickManyWindow : Window
{
    private readonly List<PickItem> _items;
    public IReadOnlyList<string> Selected => _items.Where(i => i.IsChecked).Select(i => i.Id).ToList();

    public PickManyWindow(string title, string intro, IReadOnlyList<(string Id, string Text)> items, string okText)
    {
        InitializeComponent();
        Title = title;
        IntroText.Text = intro;
        OkButton.Content = okText;
        _items = items.Select(i => new PickItem(i.Id, i.Text)).ToList();
        Items.ItemsSource = _items;
    }

    private void OnAll(object sender, RoutedEventArgs e) => _items.ForEach(i => i.IsChecked = true);
    private void OnNone(object sender, RoutedEventArgs e) => _items.ForEach(i => i.IsChecked = false);
    private void OnOk(object sender, RoutedEventArgs e) => DialogResult = true;
}
