# WATCHOUT 6 Server Build Checklist

Oct 23, 2026 · @Lorenzo

Tick each box in order on every WATCHOUT 6 display server or production PC: Windows 11 Pro 64-bit 25H2 (MicroWin), WO6-Setup.ps1 for the full Dataton tweaking guide. WATCHOUT 6 has no official Windows 11 certification, though Dataton reports it works on Windows 11 Pro; if a machine is unstable, Dataton suggests Windows 11 IoT Enterprise LTSC.

## Before you start

This checklist starts on a machine where Windows is already installed, with a local account named for the show (BIOS, RAID arrays and Windows Setup notes: `docs/PROJECT_CONTEXT.md` §2). Have ready on the USB stick: the setup wizard (or WO6-Setup.ps1 + LGPO.exe), the WATCHOUT 6 installer (same version on every machine), the licence key for this machine, the NIC driver, the RAID management app, chipset/capture/audio drivers (Windows 11 versions) and the NVIDIA driver at a version tested with your WATCHOUT 6 release. Plan a separate drive or partition for WATCHOUT and its Shows folder (guide ch. 1 and 9).

## 1. First boot, still offline

The Dataton guide wants the machine offline during setup. Keep the cable unplugged until driver search is locked.

- [ ] Log in with the show account
- [ ] Elevated PowerShell: `.\WO6-Setup.ps1 -Phase PreUpdate`
- [ ] Reboot (cable still unplugged)
- [ ] NIC driver from USB: `pnputil /add-driver <path>\*.inf /subdirs /install`
- [ ] Adapter shows in Device Manager without a warning icon
- [ ] Plug in the network cable

## 2. Updates and drivers

The 2018 guide installs only hand-picked updates; on a 25H2 base, install the current cumulative update once, then freeze.

- [ ] Windows Update: install everything, reboot, repeat until nothing is left
- [ ] RAID drivers present (AMD: `pnputil /enum-drivers | findstr /i /c:"rcbottom" /c:"rcraid" /c:"rccfg"`), then the RAID management app
- [ ] Chipset and storage drivers
- [ ] NVIDIA driver at the tested version
- [ ] Capture and audio drivers; test each card in its vendor app before WATCHOUT
- [ ] Unplug the network cable again if the machine will stay offline (guide ch. 8: most security features end up disabled)

## 3. Disks

WATCHOUT 6 keeps transferred shows and media in a "Shows" folder inside its install folder; put the install on the media drive, or move Shows there with `-ShowsPath`.

- [ ] `manage-bde -status C:` → if not "Fully Decrypted", `manage-bde -off C:` and wait
- [ ] Media volume: GPT, NTFS (64 KB allocation unit optional)
- [ ] Decide: install WATCHOUT on the media drive (e.g. `D:\WATCHOUT 6`), or default `C:\WATCHOUT 6` + a Shows folder on the media drive
- [ ] RAID management app: array healthy

## 4. WinUtil debloat

Same selection as the WATCHOUT 7 build; it covers the guide's chapters 4–6 (hibernation, app removal, OneDrive). Errors about wermgr, PeriodInNanoSeconds, store.db, FileCoAuth and `$Env:OneDrive` are harmless.

- [ ] Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer folder discovery, Hibernation, Location, Store search results, Services to Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive removal, System Tray notifications, Windows AI
- [ ] Also tick: **BitLocker - Disable**, Visual Effects - Best Performance, Storage Sense - Disable
- [ ] Skip: Edge removal (keeps WebView2), IPv6 disable (the script unbinds it per adapter), UTC time, O&O ShutUp10++, "Disable all updates" (PostInstall does the same, after all updates are in)
- [ ] Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off, Game Mode off
- [ ] Do NOT click either Ultimate Performance button (PostInstall makes its own "WATCHOUT 6" plan)
- [ ] Multiplane Overlay: leave Enabled; disable only if the soak test shows flicker or blackouts

## 5. WATCHOUT 6, licence and NVIDIA

- [ ] Install WATCHOUT 6 to the folder chosen in section 3
- [ ] Plug in the licence key directly (no USB hub; rear ports preferred)
- [ ] Key detected: open CodeMeter Control Center and check the licence appears (runtime normally installed with WATCHOUT)
- [ ] Do NOT create a Startup-folder shortcut to WATCHPOINT: PostInstall creates the auto-start task (a shortcut too would start it twice)
- [ ] Auto-logon with `netplwiz` (checkbox missing → Settings → Accounts → Sign-in options → turn off "only allow Windows Hello sign-in")
- [ ] NVIDIA Control Panel: Power Management Mode = Prefer Maximum Performance, Vertical Sync = Off
- [ ] Display resolution and refresh set manually per output (WATCHOUT 6 User Guide: preferable to letting WATCHOUT set it)
- [ ] Production PC: Settings → Bluetooth & devices → Mouse → "Scroll inactive windows when hovering over them" Off
- [ ] Network: fixed IPs (or access display computers by name), one subnet, no Wi-Fi for show traffic

## 6. PostInstall

Applies the whole tweaking guide that Windows 11 still honours: chapter 7 GPOs, chapter 10 settings, chapter 11 services, chapter 12 registry and chapter 13 tasks, plus power, NIC, notifications, Windows Update fully disabled, and Defender.

- [ ] Windows Security → Virus & threat protection → Manage settings → **Tamper Protection Off**
- [ ] Network cable to show devices unplugged or idle (bindings and NIC changes reset the link)
- [ ] Elevated, from the show account: `.\WO6-Setup.ps1 -Phase PostInstall` (+ options below)
- [ ] Read the warnings summary; fix and re-run with the SAME options if needed
- [ ] Keep `Services_Backup_<timestamp>.csv` and the `LGPO_Backup_<timestamp>` folder with the machine's notes
- [ ] Reboot

| Applied by PostInstall | Guide |
| --- | --- |
| Firewall off (or program rules with -KeepFirewall) | 7.1 |
| All Administrative Templates policies, Win11-adapted | 7.3–7.7 |
| Updates: automatic off, version pinned, notifications off; BITS, wuauserv, UsoSvc and update tasks disabled | 7.4.11 |
| Power plan "WATCHOUT 6", hibernation, disk/display never, USB suspend off | 4, 10.5 |
| PCIe link power management off (AMD/NVMe equivalent of RST setting) | 10.6 |
| IPv4-only bindings on physical adapters | 10.10 |
| UAC never notify, visual effects, Remote Assistance off, No Sounds, defrag schedule off, USB notifications off, badges off | 10.3–10.13 |
| Services disabled (CSV backup) | 11 |
| DirectShow priority, SystemResponsiveness, TDR timeouts, HideAutoLogonUI, 96 DPI | 12 |
| WATCHPOINT logon task (highest privileges, no time limit, -Delay 8) | 13 |

| Option | Use when |
| --- | --- |
| `-Role Production` | WATCHMAKER PC: no WATCHPOINT task, no Ctrl+Alt+Del/thumbnail policies, CPU priority 0x28 |
| `-ShowsPath 'E:\Shows'` | Shows folder outside the install folder |
| `-StartDelay 15` | Default delay is 8 s; raise it if another program still pulls WATCHPOINT out of full screen (0 = no delay) |
| `-KeepService TermService,SessionEnv,UmRdpService` | Keep Remote Desktop for maintenance (or any other listed service) |
| `-KeepAdapterBindings` | Machine needs file shares or IPv6 |
| `-KeepFirewall` | Firewall stays on with WATCHOUT 6 program rules |
| `-DefenderMode Exclusions` | Keep Defender on, WATCHOUT folders and programs excluded |
| `-KeepUpdateService` | Keep the Windows Update services and tasks running (default: fully disabled, as WinUtil and guide ch. 11) |
| `-ForcePcieLinkSpeed` | AMD GPU only; can crash some AMD drivers at boot |
| `-WatchoutPath`, `-PinVersion` | Install not auto-detected / pin a different version |

## 7. Manual steps

The guide items no script can set reliably.

- [ ] Display scale 100% on every output: Settings → System → Display → Scale (WATCHOUT 6 Remote Access misaligns otherwise)
- [ ] Startup apps: Settings → Apps → Startup → off for anything that can steal focus from WATCHPOINT (10.14)
- [ ] Vendor services, if installed: Intel Content Protection HDCP / HECI and NVIDIA telemetry → Disabled in `services.msc` (11)
- [ ] Wake-on-LAN: BIOS + NIC advanced property "Wake on Magic Packet" = Enabled (10.11)
- [ ] Optional: secpol.msc → Network List Manager Policies → User cannot change location (7.2)
- [ ] After the reboot, open Performance Options once and confirm "Adjust for best performance" is selected (10.3)
- [ ] Settings → Bluetooth & devices → USB: notifications off (10.12)

## 8. Verify, soak test, image

- [ ] Reboot → auto-logon → WATCHPOINT starts full screen on its own
- [ ] Task Scheduler → WATCHOUT → "WATCHPOINT auto-start": last result 0x41301 (running) and no time limit
- [ ] `Get-MpComputerStatus | Select IsTamperProtected, RealTimeProtectionEnabled, BehaviorMonitorEnabled, OnAccessProtectionEnabled` → all False (Off mode)
- [ ] `powercfg /getactivescheme` → "WATCHOUT 6"
- [ ] `manage-bde -status C:` → Protection Off
- [ ] Production PC goes online: every display computer found, media transfers complete
- [ ] Remote Access from the production PC lines up with the display
- [ ] Soak test: representative show for several hours on all outputs
- [ ] Image the system disk (System Restore is off; the image is your rollback)

## 9. Maintenance

- [ ] No in-place updates: Windows Update is disabled for good. To move to a newer Windows, reinstall from a newer ISO and rebuild with this checklist. Check activation with `slmgr /xpr` (the Settings Activation page errors with updates disabled)
- [ ] NVIDIA: update only to versions tested with your WATCHOUT 6 release
- [ ] Before any RAID driver or BIOS update: image first; keep RAID driver and BIOS RAID module versions matched
- [ ] Before 25H2 support ends (about 24 months for Pro, so late 2027; check Microsoft's release information), plan the rebuild from a newer ISO if the servers are still in service
- [ ] Re-run PostInstall with the same options after any big change; re-image when verified

## Sources

- [Dataton KB – Running WATCHOUT 6 on Windows 11](https://knowledge.dataton.com/knowledge/running-watchout-6-on-windows-11) (30 Mar 2026)
- [Dataton KB – What network ports are used by WATCHOUT](https://knowledge.dataton.com/knowledge/what-network-ports-are-used-by-watchout) (11 Jun 2019)
- [Dataton KB – Troubleshooting "License key not found"](https://knowledge.dataton.com/knowledge/troubleshooting-license-key-not-found-errors) (30 Mar 2026)
- [Dataton KB – GPU & Display Driver Best Practices](https://knowledge.dataton.com/knowledge/articles/gpu-display-driver-best-practices)
- [Dell KB 000443715 – Configure RAID with AMD RAIDXpert2](https://www.dell.com/support/kbdoc/en-us/000443715/how-to-configure-raid-with-amd-raidxpert2?lang=en) (24 May 2026)
- Dataton WATCHOUT 6.7 User Guide (Installation, Command Line Options)
- Dataton WATCHOUT Windows 10 Enterprise Tweaking Guide, doc. 3749 rev 1.3 (2018)
