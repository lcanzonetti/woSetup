using WOSetup.Core.Flow;
using WOSetup.Core.State;

namespace WOSetup.Core.Tests;

public sealed class StateStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "wosetup-tests-" + Guid.NewGuid().ToString("N"));
    private string StatePath => Path.Combine(_dir, "state.json");

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private static WizardState Sample() => new()
    {
        Profile = Profile.WO6,
        Role = Role.Production,
        WizardVersion = "0.1.0",
        Steps = { ["WO6-03.2"] = new StepState { Status = StepStatus.Done, Note = "ok" } },
        Options = { KeepService = ["TermService", "SessionEnv"], StartDelay = 15 },
    };

    [Fact]
    public void Missing_file_loads_as_no_state()
    {
        var r = new JsonStateStore(StatePath).Load();
        Assert.Null(r.State);
        Assert.Null(r.Error);
    }

    [Fact]
    public void Round_trip_keeps_everything()
    {
        var store = new JsonStateStore(StatePath);
        store.Save(Sample());
        var r = store.Load();
        Assert.Null(r.Error);
        Assert.Equal(Profile.WO6, r.State!.Profile);
        Assert.Equal(Role.Production, r.State.Role);
        Assert.Equal(StepStatus.Done, r.State.StatusOf("WO6-03.2"));
        Assert.Equal(["TermService", "SessionEnv"], r.State.Options.KeepService);
        Assert.Equal(15, r.State.Options.StartDelay);
    }

    [Fact]
    public void Enums_are_saved_as_text()
    {
        var store = new JsonStateStore(StatePath);
        store.Save(Sample());
        var json = File.ReadAllText(StatePath);
        Assert.Contains("\"Production\"", json);
        Assert.Contains("\"Done\"", json);
    }

    [Fact]
    public void Second_save_keeps_a_backup_and_leaves_no_temp_file()
    {
        var store = new JsonStateStore(StatePath);
        store.Save(Sample());
        store.Save(Sample());
        Assert.True(File.Exists(store.BackupPath));
        Assert.False(File.Exists(StatePath + ".tmp"));
    }

    [Fact]
    public void Corrupt_file_falls_back_to_backup_with_a_warning()
    {
        var store = new JsonStateStore(StatePath);
        store.Save(Sample());
        store.Save(Sample());
        File.WriteAllText(StatePath, "{ this is not json");
        var r = store.Load();
        Assert.NotNull(r.State);
        Assert.NotNull(r.Warning);
    }

    [Fact]
    public void Corrupt_file_without_backup_is_an_error()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(StatePath, "{ broken");
        var r = new JsonStateStore(StatePath).Load();
        Assert.Null(r.State);
        Assert.NotNull(r.Error);
    }

    [Fact]
    public void Newer_schema_is_refused()
    {
        var store = new JsonStateStore(StatePath);
        var s = Sample();
        s.SchemaVersion = WizardState.CurrentSchemaVersion + 1;
        store.Save(s);
        var r = store.Load();
        Assert.Null(r.State);
        Assert.Contains("newer version", r.Error);
    }

    [Fact]
    public void Archive_moves_the_state_aside()
    {
        var store = new JsonStateStore(StatePath);
        store.Save(Sample());
        var archived = store.Archive(new DateTimeOffset(2026, 10, 27, 10, 0, 0, TimeSpan.Zero));
        Assert.False(store.Exists);
        Assert.True(File.Exists(archived));
    }
}
