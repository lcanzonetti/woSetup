using WOSetup.Core.Checks;
using WOSetup.Core.Engine;
using WOSetup.Core.Flow;
using WOSetup.Core.Scripts;
using WOSetup.Core.State;

namespace WOSetup.Core.Tests;

public sealed class SessionTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "wosetup-tests-" + Guid.NewGuid().ToString("N"));
    private DateTimeOffset _now = new(2026, 10, 27, 9, 0, 0, TimeSpan.FromHours(1));

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private WizardSession NewSession(Profile profile = Profile.WO6, Role role = Role.Display)
    {
        var flow = FlowLoader.Load(profile);
        var state = WizardSession.CreateState(flow, role, "WO-DISP-01", "WO-DISP-01\\show", "0.1.0", _now);
        return new WizardSession(flow, state, new JsonStateStore(Path.Combine(_dir, "state.json")), () => _now);
    }

    [Fact]
    public void New_state_completes_the_wizard_start_steps_and_starts_at_the_next_one()
    {
        var s = NewSession();
        Assert.Equal(StepStatus.Done, s.State.StatusOf("W-00.1"));
        Assert.Equal(StepStatus.Done, s.State.StatusOf("W-00.4"));
        Assert.Equal("W-00.2", s.CurrentStep!.Id);
    }

    [Fact]
    public void Steps_for_the_other_role_are_not_applicable_and_come_back_on_switch()
    {
        var s = NewSession(Profile.WO6, Role.Display);
        Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf("WO6-05.8"));   // production only
        Assert.Equal(StepStatus.NotStarted, s.State.StatusOf("WO6-08.2"));      // display only
        s.ChangeRole(Role.Production);
        Assert.Equal(StepStatus.NotStarted, s.State.StatusOf("WO6-05.8"));
        Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf("WO6-08.2"));
    }

    [Fact]
    public void Role_switch_does_not_override_an_operator_decision()
    {
        var s = NewSession(Profile.WO6, Role.Display);
        s.SetNotApplicable("WO6-08.2", "Tested elsewhere");
        s.ChangeRole(Role.Production);
        s.ChangeRole(Role.Display);
        Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf("WO6-08.2"));
        Assert.Equal("Tested elsewhere", s.State.Step("WO6-08.2").Note);
    }

    [Fact]
    public void Unfinished_earlier_steps_are_listed_in_order()
    {
        var s = NewSession();
        var before = s.UnfinishedBefore("WO6-06.4");
        Assert.Equal("W-00.2", before[0].Id);
        Assert.DoesNotContain(before, x => x.Id == "W-00.1");
        Assert.DoesNotContain(before, x => x.Id == "WO6-06.4");
    }

    [Fact]
    public void Skip_needs_a_reason()
    {
        var s = NewSession();
        Assert.Throws<ArgumentException>(() => s.Skip("W-00.2", " "));
        s.Skip("W-00.2", "No LGPO yet");
        Assert.Equal(StepStatus.Skipped, s.State.StatusOf("W-00.2"));
    }

    [Fact]
    public void Every_change_is_saved()
    {
        var s = NewSession();
        s.MarkDone("W-00.2");
        var reloaded = new JsonStateStore(Path.Combine(_dir, "state.json")).Load().State!;
        Assert.Equal(StepStatus.Done, reloaded.StatusOf("W-00.2"));
    }

    [Fact]
    public void Reboot_is_confirmed_only_after_Windows_really_restarted()
    {
        var s = NewSession();
        var boot = _now.AddHours(-3);
        s.RequestReboot("WO6-01.3", boot);
        Assert.Equal(StepStatus.AwaitingReboot, s.State.StatusOf("WO6-01.3"));

        // Same boot (uptime-based time may jitter by seconds): not confirmed.
        Assert.Null(s.ConfirmReboot(boot.AddSeconds(20)));
        Assert.Equal(StepStatus.AwaitingReboot, s.State.StatusOf("WO6-01.3"));

        _now = _now.AddMinutes(5);
        Assert.Equal("WO6-01.3", s.ConfirmReboot(_now.AddMinutes(-1)));
        Assert.Equal(StepStatus.Done, s.State.StatusOf("WO6-01.3"));
        Assert.Null(s.State.PendingReboot);
    }

    [Fact]
    public void Interrupted_runs_are_marked_at_start()
    {
        var s = NewSession();
        s.BeginRun("WO6-01.2", new RunRecord { RunId = "r1", Phase = "PreUpdate" });
        s.MarkInterruptedRuns();
        Assert.Equal(StepStatus.Interrupted, s.State.StatusOf("WO6-01.2"));
        Assert.Equal(StepStatus.Interrupted, s.State.Runs[0].Outcome);
    }

    [Fact]
    public void Real_run_locks_the_profile_but_an_audit_does_not()
    {
        var s = NewSession();
        s.BeginRun("WO6-06.3a", new RunRecord { RunId = "a1", Phase = "PostInstall", Audit = true });
        Assert.False(s.State.ProfileLocked);
        s.BeginRun("WO6-01.2", new RunRecord { RunId = "r1", Phase = "PreUpdate" });
        Assert.True(s.State.ProfileLocked);
    }

    [Fact]
    public void First_backup_of_each_kind_is_the_baseline()
    {
        var s = NewSession();
        var r1 = new RunRecord { RunId = "r1" };
        var r2 = new RunRecord { RunId = "r2" };
        var result = new EngineResult { Status = "Completed", Backups = [new BackupEntry { Kind = "ServicesCsv", Path = "a.csv" }] };
        s.RecordRun(r1, result, StepStatus.Done, []);
        s.RecordRun(r2, result, StepStatus.Done, []);
        Assert.True(s.State.Backups[0].IsBaseline);
        Assert.False(s.State.Backups[1].IsBaseline);
    }

    // ------------------------------------------------------------ checks

    private static CheckResult R(string id, CheckState st, string d = "detail") => new(id, st, d);

    [Fact]
    public void A_step_found_done_is_marked_done_and_the_wizard_jumps_past_it()
    {
        var s = NewSession(Profile.WO7);
        s.ApplyChecks([R("W-00.2", CheckState.Done), R("W-00.3", CheckState.Done), R("W-00.5", CheckState.Done),
                       R("WO7-01.1", CheckState.Done)]);
        Assert.Equal(StepStatus.Done, s.State.StatusOf("WO7-01.1"));
        Assert.True(s.State.Step("WO7-01.1").Detected);
        Assert.Equal(CheckState.Done, s.State.Step("WO7-01.1").CheckState);
        Assert.Equal("WO7-01.2", s.CurrentStep!.Id);
    }

    [Fact]
    public void A_done_step_whose_check_now_fails_becomes_not_done()
    {
        var s = NewSession(Profile.WO7);
        s.MarkDone("WO7-03.1");
        s.ApplyChecks([R("WO7-03.1", CheckState.NotDone, "C: protection on")]);
        Assert.Equal(StepStatus.NotDone, s.State.StatusOf("WO7-03.1"));
        Assert.Equal("C: protection on", s.State.Step("WO7-03.1").Note);
        Assert.Contains(s.MissingSteps(), x => x.Id == "WO7-03.1");
    }

    [Fact]
    public void Operator_decisions_survive_a_check()
    {
        var s = NewSession(Profile.WO7);
        s.Skip("WO7-03.3", "No media drive on this PC");
        s.ApplyChecks([R("WO7-03.3", CheckState.NotDone), R("WO7-03.1", CheckState.CantCheck, "WMI error")]);
        Assert.Equal(StepStatus.Skipped, s.State.StatusOf("WO7-03.3"));
        Assert.Equal(StepStatus.NotStarted, s.State.StatusOf("WO7-03.1"));
        Assert.Equal("WMI error", s.State.Step("WO7-03.1").CheckDetail);
    }

    [Fact]
    public void Role_not_applicable_steps_stay_so_after_a_check()
    {
        var s = NewSession(Profile.WO7, Role.Display);
        s.ApplyChecks([R("WO7-08.7", CheckState.NotDone)]);   // Win32PrioritySeparation, production only
        Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf("WO7-08.7"));
    }

    [Fact]
    public void Not_applicable_check_closes_an_open_step()
    {
        var s = NewSession(Profile.WO7);
        s.ApplyChecks([R("WO7-06.4", CheckState.NotApplicable, "No adapter exposes Wake on Magic Packet")]);
        Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf("WO7-06.4"));
    }

    [Fact]
    public void Informational_audit_is_done_once_it_ran()
    {
        var s = NewSession(Profile.WO7);
        s.ApplyChecks([R("WO7-07.3", CheckState.NotDone, "12 items not set")]);
        Assert.Equal(StepStatus.Done, s.State.StatusOf("WO7-07.3"));
    }

    [Fact]
    public void Steps_after_a_run_found_done_are_not_needed_and_come_back_when_it_reopens()
    {
        var s = NewSession(Profile.WO7);
        s.ApplyChecks([R("WO7-07.4", CheckState.Done, "Audit: all set")]);
        foreach (var id in new[] { "WO7-07.2", "WO7-07.5", "WO7-07.6" })
            Assert.Equal(StepStatus.NotApplicable, s.State.StatusOf(id));

        s.ApplyChecks([R("WO7-07.4", CheckState.NotDone, "Audit: 1 item not set")]);
        Assert.Equal(StepStatus.NotDone, s.State.StatusOf("WO7-07.4"));
        foreach (var id in new[] { "WO7-07.2", "WO7-07.5", "WO7-07.6" })
            Assert.Equal(StepStatus.NotStarted, s.State.StatusOf(id));
    }

    [Fact]
    public void Steps_after_a_run_done_now_stay_needed()
    {
        var s = NewSession(Profile.WO7);
        s.FinishStep("WO7-07.4", StepStatus.Done, []);
        s.ApplyAfterRules();
        Assert.Equal(StepStatus.NotStarted, s.State.StatusOf("WO7-07.6"));
    }

    [Fact]
    public void Summary_counts_found_missing_and_unverifiable_steps()
    {
        var s = NewSession(Profile.WO7);
        var results = new List<CheckResult>
        {
            R("W-00.2", CheckState.Done), R("W-00.3", CheckState.Done), R("W-00.5", CheckState.Done),
            R("WO7-01.1", CheckState.Done), R("WO7-03.1", CheckState.NotDone), R("WO7-02.1", CheckState.CantCheck),
        };
        s.ApplyChecks(results);
        var sum = s.Summarize(results);
        Assert.Equal(6, sum.Checked);
        Assert.Equal(4, sum.FoundDone);
        Assert.Equal(1, sum.NotDone);
        Assert.Equal(1, sum.CantCheck);
        Assert.Equal("WO7-01.2", sum.FirstMissing);
        Assert.Contains(s.UncheckableOpenSteps(), x => x.Id == "WO7-04.1");
        Assert.DoesNotContain(s.UncheckableOpenSteps(), x => x.Id == "WO7-03.1");
    }

    [Fact]
    public void Operator_can_confirm_several_manual_steps_at_once()
    {
        var s = NewSession(Profile.WO7);
        s.MarkManyDone(["WO7-04.1", "WO7-05.4"], "Done before the wizard was used.");
        Assert.Equal(StepStatus.Done, s.State.StatusOf("WO7-04.1"));
        Assert.False(s.State.Step("WO7-05.4").Detected);
        Assert.Equal("Done before the wizard was used.", s.State.Step("WO7-05.4").Note);
    }

    [Fact]
    public void Audits_as_a_check_need_a_clean_completed_run()
    {
        var ok = new EngineResult { Status = "Completed", Audit = [new AuditEntry { State = "Set" }, new AuditEntry { State = "NA" }] };
        var gap = new EngineResult { Status = "Completed", Audit = [new AuditEntry { State = "NotSet", Item = "TdrDelay" }] };
        var bad = new EngineResult { Status = "Failed", Fatal = "boom" };
        Assert.Equal(CheckState.Done, CheckResult.FromAudits("x", [("PreUpdate", ok)]).State);
        Assert.Equal(CheckState.NotDone, CheckResult.FromAudits("x", [("PreUpdate", ok), ("PostInstall", gap)]).State);
        Assert.Contains("TdrDelay", CheckResult.FromAudits("x", [("PostInstall", gap)]).Detail);
        var partial = new EngineResult { Status = "Completed", Audit = [new AuditEntry { State = "Set" }, new AuditEntry { State = "Set" }, new AuditEntry { State = "NotSet", Item = "7.3.2 prompt" }] };
        Assert.StartsWith("Audit: 2 item(s) already set, 1 NOT set: PreUpdate: 7.3.2 prompt", CheckResult.FromAudits("x", [("PreUpdate", partial)]).Detail);
        Assert.Equal(CheckState.CantCheck, CheckResult.FromAudits("x", [("PostInstall", bad)]).State);
        Assert.Equal(CheckState.CantCheck, CheckResult.FromAudits("x", [("PostInstall", null)]).State);
    }

    [Fact]
    public void Check_results_file_is_parsed()
    {
        var list = CheckResult.ParseMany("""[{"Id":"bitlocker-off","State":"NotDone","Detail":"C: on"},{"Id":"lgpo","State":"CantCheck","Detail":null}]""");
        Assert.Equal(2, list.Count);
        Assert.Equal(CheckState.NotDone, list[0].State);
        Assert.Equal("", list[1].Detail);
    }

    // ---------------------------------------------------------- Evaluate

    [Fact]
    public void Cancelled_run_is_interrupted()
    {
        Assert.Equal(StepStatus.Interrupted, WizardSession.Evaluate(false, null, null, 0).Status);
    }

    [Fact]
    public void Missing_result_file_after_exit_0_is_a_warning_not_done()
    {
        var (status, warnings) = WizardSession.Evaluate(false, 0, null, 0);
        Assert.Equal(StepStatus.DoneWithWarnings, status);
        Assert.Single(warnings);
    }

    [Fact]
    public void Failed_result_is_failed_with_the_scripts_message()
    {
        var (status, warnings) = WizardSession.Evaluate(false, 1, new EngineResult { Status = "Failed", Fatal = "LGPO import failed" }, 0);
        Assert.Equal(StepStatus.Failed, status);
        Assert.Equal("LGPO import failed", warnings[0]);
    }

    [Fact]
    public void Script_warnings_make_it_done_with_warnings()
    {
        var r = new EngineResult { Status = "Completed", Warnings = ["Tamper Protection is ON"] };
        var (status, warnings) = WizardSession.Evaluate(false, 0, r, 1);
        Assert.Equal(StepStatus.DoneWithWarnings, status);
        Assert.Equal(["Tamper Protection is ON"], warnings);
    }

    [Fact]
    public void Console_and_result_disagreeing_is_reported()
    {
        var r = new EngineResult { Status = "Completed" };
        var (status, warnings) = WizardSession.Evaluate(false, 0, r, 2);
        Assert.Equal(StepStatus.DoneWithWarnings, status);
        Assert.Contains("console showed 2", warnings[0]);
    }

    [Fact]
    public void Audit_with_items_not_set_is_done_with_warnings()
    {
        var r = new EngineResult
        {
            Status = "Completed",
            Mode = "Audit",
            Audit = [new AuditEntry { State = "Set" }, new AuditEntry { State = "NotSet" }, new AuditEntry { State = "NA" }],
        };
        var (status, warnings) = WizardSession.Evaluate(true, 0, r, 0);
        Assert.Equal(StepStatus.DoneWithWarnings, status);
        Assert.Contains("1 item(s) are not set", warnings[0]);
    }

    [Fact]
    public void Clean_run_is_done()
    {
        Assert.Equal(StepStatus.Done, WizardSession.Evaluate(false, 0, new EngineResult { Status = "Completed" }, 0).Status);
    }
}
