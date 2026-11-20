#!/usr/bin/env python3
"""Step lists of the setup wizard: the single source for the app and for
docs/WIZARD_FLOW.md.

Order and wording follow the build checklists in docs/checklists/ (sections 1
to 8; the old "Before you start" and "Install Windows" sections were removed
in Oct 2026 because the wizard runs on a machine that already has Windows).

Every step is one of:
  automated  the wizard does it after the operator confirms (script phase,
             restart, or one of the commands in Engine/WO-Actions.ps1)
  manual     the operator does it, then confirms
  check      read-only verification only (section 8 mostly)
Any step can carry a `check`: a read-only test (Engine/WO-Checks.ps1, or
"audit:<phase>" = the script's -Audit mode, or a native check in the app)
that tells whether the step is already done. "Check this machine" runs all of
them, marks what is done and jumps to what is missing.

Run after editing and commit the output:
    python3 tools/flowgen/generate_flows.py
Writes src/WOSetup.Core/Flows/wo7.flow.json, wo6.flow.json and
docs/WIZARD_FLOW.md. FlowTests checks the JSON.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "src" / "WOSetup.Core" / "Flows"
DOC = ROOT / "docs" / "WIZARD_FLOW.md"

BOTH = ["Display", "Production"]


def step(id, title, kind, details="", check=None, action=None, after=None, roles=BOTH,
         internet=False, offline=False, confirm=False, uncertain=False, options=False,
         auto_done=False, informational=False):
    # informational: a check step that is done once its check has run
    # (e.g. the audit before PostInstall: its job is to show what would change).
    s = {
        "id": id, "title": title, "kind": kind, "details": details,
        "roles": roles, "needsInternet": internet, "mustBeOffline": offline,
        "confirm": confirm, "uncertain": uncertain, "optionsStep": options, "autoDone": auto_done,
        "informational": informational,
    }
    if check: s["check"] = check
    if action: s["action"] = action
    if after: s["after"] = after
    return s


def script(phase):  return {"type": "script", "phase": phase}
def command(name):  return {"type": "command", "name": name}
RESTART = {"type": "restart"}
FINISH = {"type": "finish"}


def start_section():
    return {"id": "W-00", "number": 0, "title": "Wizard start", "steps": [
        step("W-00.1", "Choose profile (WATCHOUT 7 / WATCHOUT 6) and role (Display / Production)", "manual",
             "Done on the start screen. The profile is locked after the first script run (Start over to change it).",
             auto_done=True),
        step("W-00.2", "LGPO.exe available", "check",
             "LGPO.exe writes the scripts' policies into the Local Group Policy, so they show in gpedit.msc. "
             "Bundled in the exe when built with it, otherwise put LGPO.exe next to WOSetupWizard.exe. "
             "Without it the scripts write the policies straight to the registry (User policies then reach only this account).",
             check="lgpo"),
        step("W-00.3", "Pre-flight: administrator, Windows PowerShell 5.1, execution policy, Windows version", "check",
             "Read-only. Execution policy must not be forced by Group Policy (that would override -ExecutionPolicy Bypass).",
             check="preflight"),
        step("W-00.4", "Wizard folder %ProgramData%\\WOSetupWizard (state, logs)", "automated",
             "Created at start. Nothing is installed and nothing starts by itself: after every restart, start the exe again from the USB stick.",
             auto_done=True),
        step("W-00.5", "Record machine info (model, BIOS, Windows build)", "check",
             "For the build record and the support bundle.", check="machine-info"),
    ]}


def finish_section():
    return {"id": "W-99", "number": 99, "title": "Finish", "steps": [
        step("W-99", "Finish the build", "automated",
             "Marks the build complete and offers the support bundle (state, logs, every script run).", action=FINISH),
    ]}


def first_boot(p, script_name):
    return {"id": f"{p}-01", "number": 1, "title": "First boot, still offline", "steps": [
        step(f"{p}-01.1", "Log in with the show account", "manual",
             "The account the machine will run the show with (auto-logon account). The scripts write per-user settings "
             "to the account that runs them, so the wizard must run from it.",
             check="show-account"),
        step(f"{p}-01.2", "PreUpdate: driver search lockdown", "automated",
             f"Runs {script_name} -Phase PreUpdate: SearchOrderConfig = 0, \"Do not include drivers with Windows Updates\", "
             "driver-search prompt off. Network cable must still be unplugged. Check: the script's audit.",
             check="audit:PreUpdate", action=script("PreUpdate"), offline=True),
        step(f"{p}-01.3", "Restart (cable still unplugged)", "automated",
             "Restart after PreUpdate. Then start the wizard again from the USB stick.",
             action=RESTART, after=f"{p}-01.2", offline=True),
        step(f"{p}-01.4", "Install the NIC driver from the USB stick", "manual",
             "pnputil /add-driver <path>\\*.inf /subdirs /install (elevated prompt), or the vendor's installer. "
             "Check: a physical network adapter is present and has no driver problem.",
             check="nic-driver"),
        step(f"{p}-01.5", "Network adapter shows without a warning icon", "check",
             "Same as Device Manager (devmgmt.msc) without a warning icon.", check="nic-driver"),
        step(f"{p}-01.6", "Plug in the network cable", "manual",
             "Only now: driver search is locked. Check: a physical adapter has link.", check="nic-link-up"),
    ]}


def winutil(p, wo6):
    # One step (owner, Oct 2026): the skip list, the Ultimate Performance and
    # Multiplane Overlay lines are reminders for the same WinUtil session, so
    # they are part of its instructions instead of separate steps.
    plan = '"WATCHOUT 6"' if wo6 else '"WATCHOUT 7"'
    details = "\n".join([
        "Run after updates and drivers, before WATCHOUT. Needs internet (irm christitus.com/win | iex), or a local copy of winutil.ps1.",
        "",
        "Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer folder discovery, Hibernation, Location, "
        "Store search results, Services to Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive removal, "
        "System Tray notifications, Windows AI.",
        "Also tick: BitLocker - Disable, Visual Effects - Best Performance, Storage Sense - Disable.",
        "Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off, Game Mode off.",
        "",
        "Leave unticked: Edge removal (keeps WebView2), IPv6 disable" + (" (the script unbinds it per adapter)" if wo6 else "") +
        ", UTC time, O&O ShutUp10++, \"Disable all updates\" (PostInstall does the same, after all updates are in).",
        "Do NOT click either Ultimate Performance button: PostInstall makes its own " + plan + " plan.",
        "Multiplane Overlay: leave Enabled; disable it only if the soak test shows flicker or blackouts "
        "(the registry method is reportedly ignored on 24H2+ [Uncertain]).",
        "",
        "Errors about wermgr, PeriodInNanoSeconds, store.db, FileCoAuth and $Env:OneDrive are harmless on a stripped install.",
    ])
    return {"id": f"{p}-04", "number": 4, "title": "WinUtil debloat", "steps": [
        step(f"{p}-04.1", "WinUtil: tick the tweaks and preferences listed below, then run them", "manual", details,
             internet=True, uncertain=True),
    ]}


BITLOCKER = ("BitLocker / device encryption off", "automated",
             "Windows 11 24H2+ turns on device encryption by default; a BIOS or RAID change can then lock the machine at "
             "a recovery-key prompt. Runs manage-bde -off C:. Decryption continues in the background; check again "
             "until it reports fully decrypted.")
MEDIA = ("Media drive: initialise GPT, format NTFS", "automated",
         "You pick the disk: only disks that are not initialised (RAW, no partitions) are offered, never the system "
         "disk. One NTFS partition over the whole disk, 64 KB allocation unit optional. Asks you to type the disk number.")
AUDIT_BEFORE = ("Audit before applying (read-only): what PostInstall would change", "check",
                "Runs the script with -Audit and the same options: every item is Set, Not set or N/A. Nothing is changed.")


def wo7():
    p = "WO7"
    s = "WO7-Setup.ps1"
    return [
        first_boot(p, s),
        {"id": "WO7-02", "number": 2, "title": "Updates and drivers", "steps": [
            step("WO7-02.1", "Windows Update: install everything, restart, repeat until nothing is left", "manual",
                 "Settings > Windows Update (ms-settings:windowsupdate). Driver updates are excluded by PreUpdate. "
                 "Check: shows the last installed update and whether a restart is pending (it cannot tell if more updates exist).",
                 check="updates", internet=True),
            step("WO7-02.2", "RAID driver installed, if the machine has a RAID controller", "manual",
                 "If the machine has a RAID controller (AMD RAIDXpert2, Broadcom MegaRAID, ...), install the vendor's RAID driver "
                 "package from the USB stick, the same version you loaded in Windows Setup. Not applicable without RAID. "
                 "Check: every RAID controller Windows sees has the vendor's driver (a warning if it is missing or Windows' own) "
                 "[Uncertain on real RAID hardware].",
                 check="raid-driver", uncertain=True),
            step("WO7-02.3", "RAID management app installed (RAIDXpert2, Broadcom tool...), if the machine has RAID", "manual"),
            step("WO7-02.4", "Chipset and storage drivers", "manual"),
            step("WO7-02.5", "NVIDIA driver at the version tested for your WATCHOUT release", "manual",
                 "Check: an NVIDIA driver is installed and shows its version (compare it with the release notes).",
                 check="nvidia-driver"),
            step("WO7-02.6", "Capture and audio drivers; test each in the vendor's own app", "manual"),
        ]},
        {"id": "WO7-03", "number": 3, "title": "Disks", "steps": [
            step("WO7-03.1", *BITLOCKER, check="bitlocker-off", action=command("bitlocker-off"), confirm=True),
            step("WO7-03.2", *MEDIA, check="media-volume", action=command("media-disk-init"), confirm=True),
            step("WO7-03.3", "Indexing off on the media drive", "automated",
                 "Unticks \"Allow files on this drive to have contents indexed\" on every fixed drive except C: "
                 "(as Explorer's \"Apply changes to this drive only\"). Check: the drive's root folder carries the "
                 "\"not content indexed\" attribute [Uncertain: confirm it matches the box in the drive's Properties].",
                 check="media-indexing-off", action=command("indexing-off"), uncertain=True),
            step("WO7-03.4", "RAID management app: array healthy; write-back cache and read-ahead optional", "manual",
                 "Check: Windows reports every disk online and healthy (the RAID app itself is the reference).",
                 check="disks-healthy"),
        ]},
        winutil(p, False),
        {"id": "WO7-05", "number": 5, "title": "WATCHOUT 7 and NVIDIA", "steps": [
            step("WO7-05.1", "Install WATCHOUT 7 into a folder on the RAID0 (e.g. D:\\WATCHOUT 7)", "manual",
                 "The factory image covers C: and the RAID0, so a factory reset also replaces the WATCHOUT install "
                 "(owner, Nov 2026; OPEN_QUESTIONS 29)."),
            step("WO7-05.2", "Separate folder on the RAID0, outside the WATCHOUT folder, then Nodes > Node Properties > "
                 "Change Working Directory to it", "manual",
                 "Done in WATCHOUT. Put the same folder in Options (-WorkingDirectory) so PostInstall's Defender "
                 "exclusion and this check use it.", check="wo7-workdir", options=True),
            step("WO7-05.3", "Auto-logon", "manual",
                 "Not needed when the show account has no password: Windows then signs in by itself. Otherwise netplwiz "
                 "(checkbox missing > Settings > Accounts > Sign-in options > turn off \"only allow Windows Hello sign-in\")."),
            step("WO7-05.4", "NVIDIA Control Panel: global profile \"Workstation – Dynamic Streaming\"", "manual"),
            step("WO7-05.5", "Then confirm Power Management Mode = Prefer Maximum Performance and Vertical Sync = Off", "manual"),
            step("WO7-05.6", "Static IPs on the show adapters; all nodes on one subnet", "automated",
                 "You enter IP / prefix (and gateway / DNS if needed) per connected adapter. Changing them resets the link. "
                 "IGMP snooping or multicast forwarding for 239.2.2.2 on managed switches stays a switch setting.",
                 check="static-ip", action=command("static-ip"), confirm=True),
        ]},
        {"id": "WO7-06", "number": 6, "title": "Windows settings from the Dataton guide", "steps": [
            step("WO7-06.1", "Startup apps: turn off everything not needed, above all anything that can steal focus (10.14)", "manual",
                 "Settings > Apps > Startup (ms-settings:startupapps). UAC, visual effects, Remote Assistance, sounds, "
                 "defrag schedule, USB notifications, badges, indexing and 96 DPI are applied by PostInstall and checked in section 8."),
            step("WO7-06.2", "Display scale 100 % on every output (12.3)", "manual",
                 "Settings > System > Display > Scale (ms-settings:display). PostInstall writes the 96 DPI values, "
                 "but each display keeps its own scale.", check="display-scale"),
            step("WO7-06.3", "Network: each show adapter IPv4 only (10.10); keep Client for Microsoft Networks and File and "
                 "Printer Sharing if you use network shares", "manual",
                 "Open ncpa.cpl. Check: IPv6, QoS, LLTD, LLDP and Multiplexor unbound on every physical adapter.",
                 check="ipv4-only-bindings"),
            step("WO7-06.4", "Wake-on-LAN: NIC \"Wake on Magic Packet\" = Enabled (10.11)", "automated",
                 "Sets the adapter property on every physical adapter that has it. Wake-on-LAN in the BIOS stays manual.",
                 check="wol-magic-packet", action=command("wol-enable")),
            step("WO7-06.5", "Services: optionally disable Print Spooler, Fax and Bluetooth (11); never any WATCHOUT or Dataton service", "manual",
                 "WinUtil's \"Set to Manual\" covers the WATCHOUT 7 routine (services.msc)."),
            step("WO7-06.6", "No auto-start task: WATCHOUT 7 runs as Windows services (13.1 not needed)", "manual"),
        ]},
        {"id": "WO7-07", "number": 7, "title": "PostInstall", "steps": [
            step("WO7-07.1", "Windows Security > Virus & threat protection > Manage settings > Tamper Protection Off", "manual",
                 "Microsoft blocks scripting this. Needed only with -DefenderMode Off.", check="tamper-off"),
            step("WO7-07.2", "Review the options (role, Defender, firewall, Windows Update, paths)", "manual",
                 "Options page: one option per script parameter, with the exact command line.", options=True,
                 after="WO7-07.4"),
            step("WO7-07.3", *AUDIT_BEFORE, check="audit:PostInstall", informational=True),
            step("WO7-07.4", "PostInstall: power, network, policies, update freeze, Windows settings, Defender", "automated",
                 f"Runs {s} -Phase PostInstall with the options. Security-reducing: asks you to type APPLY. "
                 "Check: the script's audit.", check="audit:PostInstall", action=script("PostInstall"), confirm=True),
            step("WO7-07.5", "Read the warnings; fix and run again if needed (safe to repeat)", "manual",
                 after="WO7-07.4"),
            step("WO7-07.6", "Restart", "automated", "Then start the wizard again from the USB stick.",
                 action=RESTART, after="WO7-07.4"),
        ]},
        {"id": "WO7-08", "number": 8, "title": "Verify, soak test, factory image", "steps": [
            step("WO7-08.1", "Defender off (or exclusions present with -DefenderMode Exclusions)", "check", check="defender-off"),
            step("WO7-08.2", "Power plan \"WATCHOUT 7\" active", "check", check="power-plan"),
            step("WO7-08.3", "BitLocker protection off", "check", check="bitlocker-off"),
            step("WO7-08.4", "Update services still disabled (WaaSMedicSvc can re-enable wuauserv)", "check",
                 check="update-services-disabled", uncertain=True),
            step("WO7-08.5", "GPU timeouts TdrDelay = 15, TdrDdiDelay = 60 (12.2)", "check", check="reg-tdr"),
            step("WO7-08.6", "SystemResponsiveness = 10 (12.1; values under 10 reportedly treated as 10 [Uncertain])", "check",
                 check="reg-sysresp", uncertain=True),
            step("WO7-08.7", "Production PC: Win32PrioritySeparation = 40 (0x28) (12.3)", "check", check="reg-priosep",
                 roles=["Production"]),
            step("WO7-08.8", "Performance Options: \"Adjust for best performance\", every effect unticked (10.3)", "manual",
                 "Open SystemPropertiesPerformance.exe once and look. UserPreferencesMask is [Uncertain].",
                 check="visual-effects", uncertain=True),
            step("WO7-08.9", "USB notifications off (10.12)", "check", check="usb-notify-off", uncertain=True),
            step("WO7-08.10", "Windows Search service disabled (10.15)", "check",
                 "The indexing service itself. The per-drive box is checked in the next step.", check="wsearch-disabled"),
            step("WO7-08.10a", "Contents indexing off on every data drive (10.15, per drive)", "check",
                 "Same check as step 3.3: \"Allow files on this drive to have contents indexed\" unticked on every fixed "
                 "drive except C: [Uncertain].", check="media-indexing-off", uncertain=True),
            step("WO7-08.11", "Full audit: both script phases report every item Set", "check",
                 "Read-only. Anything Not set is listed.", check="audit:Both"),
            step("WO7-08.12", "Optional: secpol.msc > Network List Manager Policies > User cannot change location", "manual"),
            # Factory image (owner, Nov 2026; OPEN_QUESTIONS 29): the machine as it is at the end of the
            # build, C: and the RAID0, captured before any show and then tested by the soak test.
            # Manual until the recovery toolkit in recovery/ is ported and tested.
            step("WO7-08.13", "Recovery partition WO_RECOVERY present after C: (created in Windows Setup)", "manual",
                 "Get-Partition shows it as type Recovery, about 45 GB, no drive letter. "
                 "Commands for Windows Setup: docs/PROJECT_CONTEXT.md section 2a."),
            step("WO7-08.14", "Install the recovery boot: WinPE (with the RAID driver) on the recovery partition and its boot entry", "manual",
                 "Recovery toolkit in recovery/ (untested templates). System Restore is off and \"Reset this PC\" is not used: "
                 "a factory reset puts this image back."),
            step("WO7-08.15", "Capture the factory image of C: and the RAID0, before any show or asset is loaded", "manual",
                 "Restart into the recovery, choose Capture. BitLocker must be off (step 8.3); no Sysprep; the working "
                 "directory must be empty. Name it WO7.<version>_W11-25H2_<YYYY-MM-DD>. A factory reset erases C: and D: "
                 "and puts this image back (shows and assets are uploaded again)."),
            step("WO7-08.16", "All nodes discover each other; asset transfer to the RAID0 works", "manual"),
            step("WO7-08.17", "Soak test: representative show for several hours on all outputs", "manual",
                 "Passed: the factory image is valid. A change is needed: factory reset, make the change before loading "
                 "any show, capture again, soak test again."),
            step("WO7-08.18", "Copy the valid factory image off the machine (recovery USB stick or NAS)", "manual",
                 "An image on the same array as C: does not survive an array failure."),
        ]},
    ]


def wo6():
    p = "WO6"
    s = "WO6-Setup.ps1"
    return [
        first_boot(p, s),
        {"id": "WO6-02", "number": 2, "title": "Updates and drivers", "steps": [
            step("WO6-02.1", "Windows Update: install everything, restart, repeat until nothing is left", "manual",
                 "Settings > Windows Update (ms-settings:windowsupdate). Check: last installed update and pending restart.",
                 check="updates", internet=True),
            step("WO6-02.2", "RAID driver installed, if the machine has a RAID controller", "manual",
                 "If the machine has a RAID controller (AMD RAIDXpert2, Broadcom MegaRAID, ...), install the vendor's RAID driver "
                 "package from the USB stick, the same version you loaded in Windows Setup. Not applicable without RAID. "
                 "Check: every RAID controller Windows sees has the vendor's driver (a warning if it is missing or Windows' own) "
                 "[Uncertain on real RAID hardware].",
                 check="raid-driver", uncertain=True),
            step("WO6-02.3", "RAID management app installed (RAIDXpert2, Broadcom tool...), if the machine has RAID", "manual"),
            step("WO6-02.4", "Chipset and storage drivers", "manual"),
            step("WO6-02.5", "NVIDIA driver at the version tested with your WATCHOUT 6 release", "manual", check="nvidia-driver"),
            step("WO6-02.6", "Capture and audio drivers; test each card in its vendor app before WATCHOUT", "manual"),
            step("WO6-02.7", "Unplug the network cable again if the machine will stay offline (guide ch. 8)", "manual",
                 "If WinUtil is launched online in section 4, plug it in briefly there."),
        ]},
        {"id": "WO6-03", "number": 3, "title": "Disks", "steps": [
            step("WO6-03.1", *BITLOCKER, check="bitlocker-off", action=command("bitlocker-off"), confirm=True),
            step("WO6-03.2", *MEDIA, check="media-volume", action=command("media-disk-init"), confirm=True),
            step("WO6-03.3", "Decide: WATCHOUT 6 on the media drive (e.g. D:\\WATCHOUT 6), or C:\\WATCHOUT 6 + a Shows folder "
                 "on the media drive", "manual",
                 "Put the choice in Options (-WatchoutPath / -ShowsPath).", options=True),
            step("WO6-03.4", "RAID management app: array healthy", "manual", check="disks-healthy"),
        ]},
        winutil(p, True),
        {"id": "WO6-05", "number": 5, "title": "WATCHOUT 6, licence and NVIDIA", "steps": [
            step("WO6-05.1", "Install WATCHOUT 6 to the folder chosen in section 3", "manual",
                 "Check: WATCHPOINT.exe or WATCHMAKER.exe found (same lookup as the script).", check="watchout-installed"),
            step("WO6-05.2", "Plug in the licence key directly (no USB hub; rear ports preferred)", "manual"),
            step("WO6-05.3", "Key detected: CodeMeter Control Center shows the licence", "manual"),
            step("WO6-05.4", "No Startup-folder shortcut to WATCHPOINT (PostInstall creates the auto-start task)", "check",
                 check="no-watchpoint-shortcut"),
            step("WO6-05.5", "Auto-logon", "manual",
                 "Not needed when the show account has no password. Otherwise netplwiz."),
            step("WO6-05.6", "NVIDIA Control Panel: Power Management Mode = Prefer Maximum Performance, Vertical Sync = Off", "manual"),
            step("WO6-05.7", "Display resolution and refresh set manually per output", "manual"),
            step("WO6-05.8", "Production PC: Mouse > \"Scroll inactive windows when hovering over them\" Off", "manual",
                 "Settings > Bluetooth & devices > Mouse (ms-settings:mousetouchpad).", roles=["Production"]),
            step("WO6-05.9", "Fixed IPs on the show adapters, one subnet, no Wi-Fi for show traffic", "automated",
                 "You enter IP / prefix (and gateway / DNS if needed) per connected adapter. Changing them resets the link.",
                 check="static-ip", action=command("static-ip"), confirm=True),
        ]},
        {"id": "WO6-06", "number": 6, "title": "PostInstall", "steps": [
            step("WO6-06.1", "Windows Security > Virus & threat protection > Manage settings > Tamper Protection Off", "manual",
                 "Needed only with -DefenderMode Off.", check="tamper-off"),
            step("WO6-06.2", "Network cable to show devices unplugged or idle (bindings and NIC changes reset the link)", "manual",
                 after="WO6-06.4"),
            step("WO6-06.3", "Review the options (role, Shows path, start delay, kept services, bindings, firewall, Defender)", "manual",
                 "Options page: one option per script parameter, with the exact command line.", options=True,
                 after="WO6-06.4"),
            step("WO6-06.3a", *AUDIT_BEFORE, check="audit:PostInstall", informational=True),
            step("WO6-06.4", "PostInstall: the whole tweaking guide Windows 11 still honours", "automated",
                 f"Runs {s} -Phase PostInstall with the options: ch. 7 policies, ch. 10 settings, ch. 11 services, "
                 "ch. 12 registry, ch. 13 WATCHPOINT task, power, NIC, Windows Update off, Defender. Asks you to type APPLY. "
                 "Check: the script's audit.", check="audit:PostInstall", action=script("PostInstall"), confirm=True),
            step("WO6-06.5", "Read the warnings; fix and run again with the SAME options if needed", "manual", after="WO6-06.4"),
            step("WO6-06.6", "Backups kept (Services_Backup_*.csv, LGPO_Backup_*): in the run folder and the support bundle", "manual",
                 after="WO6-06.4"),
            step("WO6-06.7", "Restart", "automated", "Then start the wizard again from the USB stick.",
                 action=RESTART, after="WO6-06.4"),
        ]},
        {"id": "WO6-07", "number": 7, "title": "Manual steps", "steps": [
            step("WO6-07.1", "Display scale 100 % on every output", "manual",
                 "Settings > System > Display > Scale (ms-settings:display). Remote Access misaligns otherwise.",
                 check="display-scale"),
            step("WO6-07.2", "Startup apps: off for anything that can steal focus from WATCHPOINT (10.14)", "manual",
                 "Settings > Apps > Startup (ms-settings:startupapps)."),
            step("WO6-07.3", "Vendor services if installed: Intel Content Protection HDCP / HECI, NVIDIA telemetry > Disabled (11)", "manual",
                 "services.msc. Check: lists those services and their start type (vendor names vary).", check="vendor-services"),
            step("WO6-07.4", "Wake-on-LAN: NIC \"Wake on Magic Packet\" = Enabled (10.11)", "automated",
                 "Sets the adapter property where it exists. Wake-on-LAN in the BIOS stays manual.",
                 check="wol-magic-packet", action=command("wol-enable")),
            step("WO6-07.5", "Optional: secpol.msc > Network List Manager Policies > User cannot change location (7.2)", "manual"),
            step("WO6-07.6", "After the restart, Performance Options shows \"Adjust for best performance\" (10.3)", "manual",
                 "Open SystemPropertiesPerformance.exe once and look. UserPreferencesMask is [Uncertain].",
                 check="visual-effects", uncertain=True),
            step("WO6-07.7", "USB notifications off (10.12)", "check", check="usb-notify-off", uncertain=True),
        ]},
        {"id": "WO6-08", "number": 8, "title": "Verify, soak test, image", "steps": [
            step("WO6-08.1", "Restart > auto-logon > WATCHPOINT starts full screen on its own", "manual",
                 "Use \"Restart Windows\", watch WATCHPOINT start, then start the wizard again.", roles=["Display"]),
            step("WO6-08.2", "Task \\WATCHOUT\\WATCHPOINT auto-start: running (0x41301), no time limit", "check",
                 check="watchpoint-task", roles=["Display"]),
            step("WO6-08.3", "Defender off (or exclusions present with -DefenderMode Exclusions)", "check", check="defender-off"),
            step("WO6-08.4", "Power plan \"WATCHOUT 6\" active", "check", check="power-plan"),
            step("WO6-08.5", "BitLocker protection off", "check", check="bitlocker-off"),
            step("WO6-08.6", "Update services still disabled (WaaSMedicSvc can re-enable wuauserv)", "check",
                 check="update-services-disabled", uncertain=True),
            step("WO6-08.7", "Full audit: both script phases report every item Set", "check", check="audit:Both"),
            step("WO6-08.8", "Production PC goes online: every display computer found, media transfers complete", "manual"),
            step("WO6-08.9", "Remote Access from the production PC lines up with the display", "manual"),
            step("WO6-08.10", "Soak test: representative show for several hours on all outputs", "manual"),
            step("WO6-08.11", "Image the system disk (System Restore is off; the image is your rollback)", "manual"),
        ]},
    ]


META = {
    "WO7": ("WATCHOUT 7", "WO7-Setup.ps1", "docs/checklists/WATCHOUT7-Server-Build-Checklist.md", wo7),
    "WO6": ("WATCHOUT 6", "WO6-Setup.ps1", "docs/checklists/WATCHOUT6-Server-Build-Checklist.md", wo6),
}


def build(profile):
    title, scr, checklist, fn = META[profile]
    return {
        "schemaVersion": 2, "profile": profile, "title": title, "script": scr,
        "checklist": checklist, "generatedBy": "tools/flowgen/generate_flows.py",
        "sections": [start_section()] + fn() + [finish_section()],
    }


def kind_label(s):
    k = {"automated": "Automatic", "manual": "Manual", "check": "Check"}[s["kind"]]
    a = s.get("action")
    if a:
        k += {"script": f" — script {a.get('phase', '')}", "restart": " — restart", "finish": "",
              "command": f" — {a.get('name', '')}"}[a["type"]]
    return k


def md(flows):
    out = ["# Wizard flow", "",
           "Generated by `tools/flowgen/generate_flows.py` (the source of the app's step lists). Do not edit by hand.", "",
           "Order and wording follow the checklists in `docs/checklists/`. The wizard runs on a machine where Windows is "
           "already installed; it starts at checklist section 1 (First boot).", "",
           "- **Automatic**: the wizard does it after you confirm (🔒 = typed confirmation / security-reducing).",
           "- **Manual**: you do it, then confirm.",
           "- **Check**: read-only verification.",
           "- **Check** column: the test that tells whether the step is already done (`audit:` = the script's `-Audit` "
           "mode). **Check this machine** runs every check, marks what is done and jumps to what is missing.",
           "- **After**: the step is only needed when that step was run now (e.g. a restart after PostInstall); "
           "when the earlier step was found already done, this one is marked not needed.", ""]
    for profile, flow in flows.items():
        out += [f"## {flow['title']} profile", ""]
        for sec in flow["sections"]:
            name = sec["title"] if sec["number"] in (0, 99) else f"{sec['number']}. {sec['title']}"
            out += [f"### {name}", "", "| Id | Step | Type | Check | Notes |", "| --- | --- | --- | --- | --- |"]
            for s in sec["steps"]:
                notes = []
                if s["roles"] != BOTH: notes.append(f"{s['roles'][0]} only")
                if s["needsInternet"]: notes.append("needs internet")
                if s["mustBeOffline"]: notes.append("cable unplugged")
                if s["confirm"]: notes.append("🔒")
                if s.get("after"): notes.append(f"after {s['after']}")
                if s["uncertain"]: notes.append("[Uncertain]")
                cell = lambda t: t.replace("|", "\\|")
                out.append(f"| {s['id']} | {cell(s['title'])} | {kind_label(s)} | {('`' + s['check'] + '`') if s.get('check') else '—'} | {', '.join(notes)} |")
            out.append("")
    return "\n".join(out) + "\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    flows = {p: build(p) for p in META}
    for p, f in flows.items():
        path = OUT / f"{p.lower()}.flow.json"
        path.write_text(json.dumps(f, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        n = sum(len(s["steps"]) for s in f["sections"])
        print(f"{path.relative_to(ROOT)}: {len(f['sections'])} sections, {n} steps")
    DOC.write_text(md(flows), encoding="utf-8")
    print(f"{DOC.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
