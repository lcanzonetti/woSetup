using CommunityToolkit.Mvvm.ComponentModel;
using WOSetup.Core.Flow;
using WOSetup.Core.Options;

namespace WOSetup.App.ViewModels;

/// <summary>
/// Editable copy of the script options (1:1 with the script parameters).
/// Nothing is saved until the operator presses Save.
/// </summary>
public sealed partial class OptionsViewModel : ObservableObject
{
    public OptionsViewModel(Profile profile, Role role, EngineOptions options, bool postInstallHasRun)
    {
        Profile = profile;
        PostInstallHasRun = postInstallHasRun;
        _role = role;
        _defenderMode = options.DefenderMode;
        _keepFirewall = options.KeepFirewall;
        _keepUpdateService = options.KeepUpdateService;
        _watchoutPath = options.WatchoutPath ?? "";
        _workingDirectory = options.WorkingDirectory ?? "";
        _showsPath = options.ShowsPath ?? "";
        _startDelay = options.StartDelay.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _keepServices = options.KeepServices;
        _keepService = string.Join(", ", options.KeepService);
        _keepAdapterBindings = options.KeepAdapterBindings;
        _forcePcieLinkSpeed = options.ForcePcieLinkSpeed;
    }

    public Profile Profile { get; }
    public bool IsWO7 => Profile == Profile.WO7;
    public bool IsWO6 => Profile == Profile.WO6;
    public bool PostInstallHasRun { get; }
    public string ScriptName => IsWO7 ? "WO7-Setup.ps1" : "WO6-Setup.ps1";

    public IReadOnlyList<Role> Roles { get; } = [Role.Display, Role.Production];
    public IReadOnlyList<DefenderMode> DefenderModes { get; } = [DefenderMode.Off, DefenderMode.Exclusions, DefenderMode.Skip];

    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private Role _role;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private DefenderMode _defenderMode;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private bool _keepFirewall;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private bool _keepUpdateService;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private string _watchoutPath;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private string _workingDirectory;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private string _showsPath;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private string _startDelay;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private bool _keepServices;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private string _keepService;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private bool _keepAdapterBindings;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Preview), nameof(Errors))] private bool _forcePcieLinkSpeed;

    /// <summary>Remote Desktop services, as suggested in the WO6 checklist option table.</summary>
    [CommunityToolkit.Mvvm.Input.RelayCommand]
    private void KeepRemoteDesktop()
    {
        var list = ParseList(KeepService);
        foreach (var s in new[] { "TermService", "SessionEnv", "UmRdpService" })
            if (!list.Contains(s, StringComparer.OrdinalIgnoreCase)) list.Add(s);
        KeepService = string.Join(", ", list);
    }

    private static List<string> ParseList(string text) =>
        text.Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    private bool StartDelayIsNumber(out int value) =>
        int.TryParse(StartDelay, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out value);

    public EngineOptions ToOptions()
    {
        StartDelayIsNumber(out var delay);
        return new EngineOptions
        {
            DefenderMode = DefenderMode,
            KeepFirewall = KeepFirewall,
            KeepUpdateService = KeepUpdateService,
            WatchoutPath = Blank(WatchoutPath),
            WorkingDirectory = Blank(WorkingDirectory),
            ShowsPath = Blank(ShowsPath),
            StartDelay = delay,
            KeepServices = KeepServices,
            KeepService = ParseList(KeepService),
            KeepAdapterBindings = KeepAdapterBindings,
            ForcePcieLinkSpeed = ForcePcieLinkSpeed,
        };
    }

    private static string? Blank(string s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    public IReadOnlyList<string> Errors
    {
        get
        {
            var errors = new List<string>();
            if (IsWO6 && !StartDelayIsNumber(out _)) errors.Add("Start delay must be a whole number of seconds.");
            else errors.AddRange(OptionsValidator.Validate(Profile, ToOptions()));
            return errors;
        }
    }

    public string Preview => ScriptArgumentBuilder.CommandLine(ScriptName,
        ScriptArgumentBuilder.Build(Profile, Role, EnginePhase.PostInstall, ToOptions(), audit: false, resultPath: null));
}
