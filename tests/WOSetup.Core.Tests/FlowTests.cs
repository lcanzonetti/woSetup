using WOSetup.Core.Flow;

namespace WOSetup.Core.Tests;

public class FlowTests
{
    [Theory]
    [InlineData(Profile.WO7)]
    [InlineData(Profile.WO6)]
    public void Embedded_flow_loads_and_is_valid(Profile profile)
    {
        var flow = FlowLoader.Load(profile);
        Assert.Equal(profile, flow.Profile);
        Assert.Empty(FlowValidator.Validate(flow));
        Assert.True(flow.AllSteps.Count() > 70);
    }

    [Theory]
    [InlineData(Profile.WO7, "WO7-03.2", "WO7-09.3")]
    [InlineData(Profile.WO6, "WO6-03.2", "WO6-08.4")]
    public void Script_phases_are_automated_steps_in_checklist_order(Profile profile, string preUpdate, string postInstall)
    {
        var flow = FlowLoader.Load(profile);
        var pre = Assert.IsType<AutomatedStep>(flow.Find(preUpdate));
        var post = Assert.IsType<AutomatedStep>(flow.Find(postInstall));
        Assert.Equal(EnginePhase.PreUpdate, pre.Engine!.Phase);
        Assert.Equal(EnginePhase.PostInstall, post.Engine!.Phase);
        Assert.False(pre.Engine.Audit);
        var ids = flow.AllSteps.Select(s => s.Id).ToList();
        Assert.True(ids.IndexOf(preUpdate) < ids.IndexOf(postInstall));
    }

    [Theory]
    [InlineData(Profile.WO7, "WO7-09.2a", "WO7-09.3")]
    [InlineData(Profile.WO6, "WO6-08.3a", "WO6-08.4")]
    public void Audit_before_applying_comes_right_before_PostInstall(Profile profile, string audit, string run)
    {
        var flow = FlowLoader.Load(profile);
        var step = Assert.IsType<CheckStep>(flow.Find(audit));
        Assert.True(step.Engine!.Audit);
        var ids = flow.AllSteps.Select(s => s.Id).ToList();
        Assert.Equal(ids.IndexOf(run) - 1, ids.IndexOf(audit));
    }

    [Fact]
    public void Sections_follow_the_checklist_and_steps_know_their_section()
    {
        var flow = FlowLoader.Load(Profile.WO7);
        Assert.Equal(0, flow.Sections[0].Number);
        Assert.Equal(99, flow.Sections[^1].Number);
        Assert.All(flow.AllSteps, s => Assert.Contains(s, s.Section.Steps));
    }

    [Fact]
    public void Role_specific_steps_are_marked()
    {
        var wo6 = FlowLoader.Load(Profile.WO6);
        Assert.Equal([Role.Display], wo6.Find("WO6-10.2")!.Roles);
        Assert.Equal([Role.Production], wo6.Find("WO6-07.8")!.Roles);
    }

    [Fact]
    public void WO6_has_its_own_WinUtil_steps()
    {
        var wo6 = FlowLoader.Load(Profile.WO6);
        Assert.Contains("WATCHOUT 6", wo6.Find("WO6-06.5")!.Title);
        Assert.NotNull(wo6.Find("WO6-06.1"));
    }
}

public class OpenTargetTests
{
    [Fact]
    public void Open_mentions_become_buttons()
    {
        Assert.Equal(["ncpa.cpl"], OpenTargets.Extract("Open `ncpa.cpl`. C†: `Get-NetAdapterBinding` per physical adapter"));
        Assert.Equal(["netplwiz", "ms-settings:signinoptions"], OpenTargets.Extract("Open `netplwiz`, `ms-settings:signinoptions`. C†: `HKLM\\...`"));
    }

    [Fact]
    public void Commands_in_checks_are_never_offered()
    {
        Assert.Empty(OpenTargets.Extract("`pnputil /enum-drivers | findstr /i rcraid` → all three found"));
        Assert.Empty(OpenTargets.Extract("C: `Get-MpComputerStatus | Select IsTamperProtected` → False"));
    }

    [Fact]
    public void Every_flow_step_offers_only_known_kinds_of_targets()
    {
        foreach (var p in new[] { Profile.WO7, Profile.WO6 })
            foreach (var s in FlowLoader.Load(p).AllSteps)
                foreach (var t in OpenTargets.Extract(s.Title + " " + s.Details))
                    Assert.Matches(@"^([A-Za-z0-9]+\.(msc|cpl)|ms-settings:.+|windowsdefender://.+|netplwiz|dfrgui|UserAccountControlSettings\.exe|SystemProperties\w+\.exe)$", t);
    }
}
