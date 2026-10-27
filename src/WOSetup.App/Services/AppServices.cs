using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using WOSetup.Core.State;

namespace WOSetup.App.Services;

/// <summary>Where the wizard keeps its files: always on the machine, never on the USB stick.</summary>
public sealed class AppPaths
{
    public string Root { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WOSetupWizard");

    public string StateFile => Path.Combine(Root, "state.json");
    public string LogsRoot => Path.Combine(Root, "logs");

    public string MachineLogs(string logFolderName) => Path.Combine(LogsRoot, logFolderName);
    public string MachineLogs(WizardState s) => MachineLogs(s.Machine.LogFolderName);

    public string Relative(string fullPath) => Path.GetRelativePath(Root, fullPath);
    public string Full(string relativePath) => Path.GetFullPath(Path.Combine(Root, relativePath));
}

/// <summary>wizard.log: one line per event, local time with UTC offset.</summary>
public sealed class FileLogger
{
    private readonly object _lock = new();
    private string _file;

    public FileLogger(string file) => _file = file;

    public void MoveTo(string file)
    {
        lock (_lock) _file = file;
    }

    public void Log(string message)
    {
        try
        {
            lock (_lock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
                File.AppendAllText(_file, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}  {message}{Environment.NewLine}");
            }
        }
        catch (IOException)
        {
            // Logging must never stop the wizard.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

public static class SystemInfo
{
    /// <summary>
    /// When Windows last started, from the uptime counter. Used to confirm
    /// that a requested restart really happened. Note: with Fast Startup a
    /// "Shut down" does not reset uptime; a "Restart" does.
    /// </summary>
    public static DateTimeOffset BootTime => DateTimeOffset.Now - TimeSpan.FromMilliseconds(Environment.TickCount64);

    public static string UserName => $"{Environment.UserDomainName}\\{Environment.UserName}";

    public static bool IsElevated
    {
        get
        {
            using var id = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    public static string ExeDirectory =>
        Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;

    public static string WizardVersion =>
        typeof(SystemInfo).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
}

/// <summary>Opens settings pages, consoles and folders, and restarts Windows.</summary>
public static class ShellLauncher
{
    public static void Open(string target)
    {
        // dfrgui and netplwiz are executables without their extension in the checklists.
        var file = target is "dfrgui" or "netplwiz" ? target + ".exe" : target;
        Process.Start(new ProcessStartInfo(file) { UseShellExecute = true });
    }

    public static void OpenFolder(string folder)
    {
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    public static void Restart() =>
        Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 10 /c \"WATCHOUT setup wizard: restarting\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
}
