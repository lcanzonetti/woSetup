using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using WOSetup.Core.State;

namespace WOSetup.App.Services;

/// <summary>Files of one script run. Everything a run produces stays in its folder for good.</summary>
public sealed record RunFolder(
    string Path, string ScriptPath, string WrapperPath, string ParamsPath, string ResultPath,
    string StdoutPath, string StderrPath, string ScriptSha256, string LgpoSource);

/// <summary>
/// Prepares a run folder: the scripts look for LGPO.exe next to themselves
/// and write their transcript and backups there (ARCHITECTURE §6.1), so each
/// run gets its own copy of the script, the wrapper and LGPO.exe.
/// </summary>
public sealed class EngineWorkspace(AppPaths paths)
{
    private static readonly Assembly Asm = typeof(EngineWorkspace).Assembly;

    public static bool LgpoBundled => Asm.GetManifestResourceInfo("engine/LGPO.exe") is not null;

    public static string LgpoBesideExe => System.IO.Path.Combine(SystemInfo.ExeDirectory, "LGPO.exe");

    /// <summary>"bundled", "next to the wizard" or "" when there is none.</summary>
    public static string LgpoSource =>
        LgpoBundled ? "bundled" : File.Exists(LgpoBesideExe) ? "next to the wizard" : "";

    public static bool LgpoAvailable => LgpoSource.Length > 0;

    public RunFolder Create(WizardState state, string script, string phase, bool audit, DateTimeOffset now)
    {
        var name = $"{now:yyyyMMdd_HHmmss}_{phase}{(audit ? "_Audit" : "")}";
        var runs = System.IO.Path.Combine(paths.MachineLogs(state), "runs");
        var dir = System.IO.Path.Combine(runs, name);
        for (var i = 2; Directory.Exists(dir); i++) dir = System.IO.Path.Combine(runs, $"{name}_{i}");
        Directory.CreateDirectory(dir);

        var scriptPath = Extract($"engine/{script}", dir, script);
        var wrapperPath = Extract("engine/Invoke-WOEngine.ps1", dir, "Invoke-WOEngine.ps1");
        if (LgpoBundled) Extract("engine/LGPO.exe", dir, "LGPO.exe");
        else if (File.Exists(LgpoBesideExe)) File.Copy(LgpoBesideExe, System.IO.Path.Combine(dir, "LGPO.exe"));

        return new RunFolder(dir, scriptPath, wrapperPath,
            System.IO.Path.Combine(dir, "params.json"), System.IO.Path.Combine(dir, "result.json"),
            System.IO.Path.Combine(dir, "stdout.log"), System.IO.Path.Combine(dir, "stderr.log"),
            Sha256(scriptPath), LgpoSource);
    }

    /// <summary>Writes the parameters in order, as one JSON object read by the wrapper.</summary>
    public static void WriteParams(RunFolder folder, IEnumerable<KeyValuePair<string, object>> parameters)
    {
        using var fs = File.Create(folder.ParamsPath);
        using var w = new Utf8JsonWriter(fs, new JsonWriterOptions { Indented = true });
        w.WriteStartObject();
        foreach (var (k, v) in parameters)
        {
            w.WritePropertyName(k);
            JsonSerializer.Serialize(w, v, v.GetType());
        }
        w.WriteEndObject();
    }

    private static string Extract(string resource, string dir, string fileName)
    {
        using var s = Asm.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException($"Embedded file '{resource}' is missing from this build.");
        var path = System.IO.Path.Combine(dir, fileName);
        using var f = File.Create(path);
        s.CopyTo(f);
        return path;
    }

    private static string Sha256(string file)
    {
        using var s = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(s));
    }
}

/// <summary>
/// Runs the wrapper under Windows PowerShell 5.1 (never pwsh) and streams its
/// output line by line (ARCHITECTURE §6.2). No timeout: gpupdate and service
/// changes can take minutes. Cancel kills the whole process tree.
/// </summary>
public sealed class PowerShellRunner
{
    public static string PowerShellPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");

    public static bool Available => File.Exists(PowerShellPath);

    /// <summary>Returns the exit code, or null when cancelled.</summary>
    public async Task<int?> RunAsync(RunFolder f, Action<string, bool> onLine, CancellationToken ct)
    {
        var utf8 = new UTF8Encoding(false);
        var psi = new ProcessStartInfo(PowerShellPath)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = f.Path,
            StandardOutputEncoding = utf8,
            StandardErrorEncoding = utf8,
        };
        foreach (var a in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", f.WrapperPath, "-Script", f.ScriptPath, "-ParamsJson", f.ParamsPath })
            psi.ArgumentList.Add(a);

        using var stdout = new StreamWriter(f.StdoutPath, append: false, utf8) { AutoFlush = true };
        using var stderr = new StreamWriter(f.StderrPath, append: false, utf8) { AutoFlush = true };
        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            lock (stdout) stdout.WriteLine(e.Data);
            onLine(e.Data, false);
        };
        p.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            lock (stderr) stderr.WriteLine(e.Data);
            onLine(e.Data, true);
        };
        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        try
        {
            await p.WaitForExitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await p.WaitForExitAsync(CancellationToken.None);
            return null;
        }
        p.WaitForExit();   // drains the remaining output events
        return p.ExitCode;
    }
}

/// <summary>Zip of the state and this machine's logs, saved where the operator chooses. Nothing is sent anywhere.</summary>
public static class SupportBundle
{
    public static void Create(AppPaths paths, WizardState state, string zipPath)
    {
        if (File.Exists(zipPath)) File.Delete(zipPath);
        using var zip = System.IO.Compression.ZipFile.Open(zipPath, System.IO.Compression.ZipArchiveMode.Create);
        foreach (var f in new[] { paths.StateFile, paths.StateFile + ".bak" }.Where(File.Exists))
            Add(zip, f, Path.GetFileName(f));
        var logs = paths.MachineLogs(state);
        if (Directory.Exists(logs))
        {
            foreach (var f in Directory.EnumerateFiles(logs, "*", SearchOption.AllDirectories))
            {
                // Copies of Microsoft's LGPO.exe add size and nothing to diagnose.
                if (string.Equals(Path.GetFileName(f), "LGPO.exe", StringComparison.OrdinalIgnoreCase)) continue;
                Add(zip, f, Path.Combine("logs", Path.GetRelativePath(logs, f)));
            }
        }
    }

    private static void Add(System.IO.Compression.ZipArchive zip, string file, string entry)
    {
        // Open with sharing so a log that is still being written does not fail the bundle.
        using var src = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var dst = zip.CreateEntry(entry.Replace('\\', '/')).Open();
        src.CopyTo(dst);
    }
}
