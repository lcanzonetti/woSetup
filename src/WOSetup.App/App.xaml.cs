using System.IO;
using System.Windows;
using WOSetup.App.Services;
using WOSetup.App.ViewModels;
using WOSetup.App.Views;
using WOSetup.Core.State;

namespace WOSetup.App;

/// <summary>
/// Start-up: one window only, load state.json, open on the current step.
/// The exe is portable (OPEN_QUESTIONS 23): after every restart the operator
/// starts it again from the USB stick and it continues from the state file.
/// </summary>
public partial class App : Application
{
    private Mutex? _single;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _single = new Mutex(initiallyOwned: true, @"Global\WOSetupWizard", out var first);
        if (!first)
        {
            MessageBox.Show("The setup wizard is already open on this machine.", "WATCHOUT Server Setup Wizard",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        var paths = new AppPaths();
        Directory.CreateDirectory(paths.Root);
        var log = new FileLogger(Path.Combine(paths.MachineLogs(Environment.MachineName), "wizard.log"));
        log.Log($"Wizard {SystemInfo.WizardVersion} started from {Environment.ProcessPath} by {SystemInfo.UserName}");
        DispatcherUnhandledException += (_, args) =>
        {
            log.Log($"Unexpected error: {args.Exception}");
            MessageBox.Show($"Unexpected error: {args.Exception.Message}\n\nDetails are in wizard.log.",
                "WATCHOUT Server Setup Wizard", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        var store = new JsonStateStore(paths.StateFile);
        var loaded = store.Load();
        if (loaded.Error is not null)
        {
            log.Log($"State not loaded: {loaded.Error}");
            var newer = loaded.Error.Contains("newer version", StringComparison.Ordinal);
            if (newer)
            {
                MessageBox.Show(loaded.Error, "WATCHOUT Server Setup Wizard", MessageBoxButton.OK, MessageBoxImage.Warning);
                Shutdown();
                return;
            }
            var answer = MessageBox.Show(
                loaded.Error + "\n\nStart a new build? The unreadable file is kept next to it (state_<date>.json.old).",
                "WATCHOUT Server Setup Wizard", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (answer != MessageBoxResult.Yes)
            {
                Shutdown();
                return;
            }
            store.Archive(DateTimeOffset.Now);
            loaded = new StateLoadResult(null, null, null);
        }

        try
        {
            var vm = new MainViewModel(paths, store, log, new DialogService());
            var window = new MainWindow { DataContext = vm };
            MainWindow = window;
            window.Show();
            vm.Initialise(loaded);
        }
        catch (Exception ex)
        {
            // A start-up error must be visible and logged, never a silent exit.
            log.Log($"Start-up failed: {ex}");
            MessageBox.Show($"The wizard could not start: {ex.Message}\n\nDetails are in {Path.Combine(paths.MachineLogs(Environment.MachineName), "wizard.log")}.",
                "WATCHOUT Server Setup Wizard", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _single?.Dispose();
        base.OnExit(e);
    }
}
