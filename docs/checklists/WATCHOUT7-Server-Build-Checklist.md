# WATCHOUT 7 Server Build Checklist

Oct 14, 2026 · @Lorenzo

Tick each box in order on every new WATCHOUT 7 display server: Windows 11 Pro (MicroWin), AMD RAID system and media arrays, WO7-Setup.ps1 for driver lockdown and the Dataton GPO set. Written for WATCHOUT 7.8.4 and Windows 11 25H2.

## Before you start

This checklist starts on a machine where Windows is already installed (BIOS, RAID arrays and Windows Setup notes: `docs/PROJECT_CONTEXT.md` §2). Have ready on the USB stick: the setup wizard (or WO7-Setup.ps1 + LGPO.exe), the NIC driver, the RAID driver package and management app (if the machine has RAID), chipset/capture/audio drivers, and the NVIDIA driver at the version listed in the WATCHOUT release notes (not "latest").

## 1. First boot, still offline

Keep the network cable unplugged until driver search is locked, or Windows Update may install its own GPU and chipset drivers.

- [ ] Log in with the show (auto-logon) account
- [ ] Elevated PowerShell: `.\WO7-Setup.ps1 -Phase PreUpdate`
- [ ] Reboot (cable still unplugged)
- [ ] Install the NIC driver from USB: `pnputil /add-driver <path>\*.inf /subdirs /install`
- [ ] Check the adapter in Device Manager (no warning icon)
- [ ] Plug in the network cable

## 2. Updates and drivers

- [ ] Windows Update: install everything, reboot, repeat until nothing is left
- [ ] RAID driver, if the machine has a RAID controller: install the vendor's package (same driver version you loaded in Setup); Device Manager > Storage controllers shows it without a warning
- [ ] RAID management app (RAIDXpert2, Broadcom tool...), if the machine has RAID
- [ ] Chipset and storage drivers
- [ ] NVIDIA driver at the version tested for your WATCHOUT release
- [ ] Capture and audio drivers; test each in the vendor's own app

## 3. Disks

Windows 11 24H2 and later turn on device encryption by default; a BIOS or RAID change can then lock the machine at a recovery-key prompt.

- [ ] `manage-bde -status C:` → if not "Fully Decrypted", run `manage-bde -off C:` and wait
- [ ] Disk Management: initialise the RAID0 as GPT, format NTFS (64 KB allocation unit optional)
- [ ] Turn off indexing on the RAID0 drive
- [ ] RAID management app: array healthy; write-back cache and read-ahead optional

## 4. WinUtil debloat

Run after updates and drivers, before WATCHOUT. Errors about wermgr, PeriodInNanoSeconds, store.db, FileCoAuth and `$Env:OneDrive` are harmless on a stripped install.

- [ ] Run WinUtil with this selection (one session):
  - Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer folder discovery, Hibernation, Location, Store search results, Services to Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive removal, System Tray notifications, Windows AI
  - Also tick: **BitLocker - Disable**, Visual Effects - Best Performance, Storage Sense - Disable
  - Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off, Game Mode off
  - Leave unticked: Edge removal (keeps WebView2), IPv6 disable, UTC time, O&O ShutUp10++, "Disable all updates" (PostInstall does the same, after all updates are in)
  - Do NOT click either Ultimate Performance button (PostInstall makes its own plan)
  - Multiplane Overlay: leave Enabled; disable only if the soak test shows flicker or blackouts

## 5. WATCHOUT 7 and NVIDIA

- [ ] Install WATCHOUT
- [ ] Create a folder on the RAID0, then Nodes → Node Properties → **Change Working Directory** to it
- [ ] Auto-logon with `netplwiz` (checkbox missing → Settings → Accounts → Sign-in options → turn off "only allow Windows Hello sign-in")
- [ ] NVIDIA Control Panel: global profile "Workstation – Dynamic Streaming"
- [ ] Then confirm Power Management Mode = Prefer Maximum Performance and Vertical Sync = Off
- [ ] Network: static IPs; all nodes on one subnet; IGMP snooping or multicast forwarding for 239.2.2.2 on managed switches

## 6. Windows settings from the Dataton guide

The guide's chapters 10–13 adapted to Windows 11 and WATCHOUT 7. Guide section numbers in brackets.

Applied by PostInstall (section 7), same as the WATCHOUT 6 script: UAC never notify (10.8), visual effects "Adjust for best performance" (10.3), Remote Assistance off (10.4), sound scheme "No Sounds" (10.7), scheduled disk optimisation off (10.9), USB notifications off (10.12), taskbar badges off (10.13), indexing off by disabling the Windows Search service (10.15), and 100 % / 96 DPI values (12.3). They are checked after the reboot in section 8.

### Settings (manual)

- [ ] Startup apps: Settings → Apps → Startup → turn off everything not needed, above all anything that can steal focus (10.14)
- [ ] Display scale 100% on every output: Settings → System → Display → Scale (12.3; PostInstall also writes the 96 DPI values, but each display keeps its own scale)
- [ ] Network: `ncpa.cpl` → each show adapter → untick everything except IPv4 (10.10); keep Client for Microsoft Networks and File and Printer Sharing if you use network shares
- [ ] Wake-on-LAN: enable it in the BIOS and set the NIC's "Wake on Magic Packet" advanced property to Enabled (10.11)

The chapter 12 registry values (TdrDelay, TdrDdiDelay, SystemResponsiveness, Win32PrioritySeparation) are applied by PostInstall and checked in section 8.

Skip from the guide: DirectShow ThreadPriority (WATCHOUT 6 DirectShow playback), ForcePcieLinkSpeed (2018 AMD GPU / X99 workaround), HideAutoLogonUI (Windows Embedded key, likely no effect on Pro).

### Services and tasks

- [ ] Services: WinUtil's "Set to Manual" covers the WATCHOUT 7 routine; optionally disable Print Spooler, Fax and Bluetooth services (11). Never disable any WATCHOUT or Dataton service (Windows Update is disabled by PostInstall)
- [ ] No auto-start task: WATCHOUT 7 runs as Windows services, so the guide's WATCHPOINT logon task (13.1) is not needed

Already handled elsewhere: group policies (ch. 7), AutoPlay (10.1), power plan and USB selective suspend (10.5), PCIe link power management (AMD equivalent of 10.6) and hibernation by PostInstall; apps, OneDrive and Cortana by WinUtil; auto-logon (10.2) in section 5.

## 7. PostInstall

Applies power plan, NIC power settings, network location, notifications, the chapter 10 settings and indexing off (section 6), the Dataton chapter 7 GPO set (Win11-adapted), the update freeze (automatic updates off, version pinned, notifications off, update services and tasks disabled), the chapter 12 registry values and Defender settings.

- [ ] Windows Security → Virus & threat protection → Manage settings → **Tamper Protection Off**
- [ ] Elevated, from the show account: `.\WO7-Setup.ps1 -Phase PostInstall`
- [ ] Read the warnings summary at the end; fix and re-run if needed (safe to repeat)
- [ ] Reboot

| Option | Use when |
| --- | --- |
| `-KeepFirewall` | Leave Windows Firewall on; WATCHOUT 7 manages its own rules |
| `-Role Production` | Production PC: skips Ctrl+Alt+Del and thumbnail policies |
| `-DefenderMode Exclusions` | Keep Defender on, exclude WATCHOUT folders and processes |
| `-WorkingDirectory <path>` | Working directory is not the default `.wo` folder |
| -PinVersion 25H2 | Pin to a version other than the one installed (default: installed version) |
| -KeepUpdateService | Keep the Windows Update services and tasks running (default: fully disabled, as WinUtil's "Disable all updates") |

## 8. Verify, soak test, image

- [ ] `Get-MpComputerStatus | Select IsTamperProtected, RealTimeProtectionEnabled, BehaviorMonitorEnabled, OnAccessProtectionEnabled` → all False (Off mode)
- [ ] `powercfg /getactivescheme` → "WATCHOUT 7"
- [ ] `manage-bde -status C:` → Protection Off
- [ ] GPU timeouts for slow multi-output mode changes (12.2): `reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDelay` → 15 (0xf) and `/v TdrDdiDelay` → 60 (0x3c)
- [ ] Multimedia CPU reserve (12.1): `reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness` → 10 (0xa) (the guide says 5; Windows is reported to treat values under 10 as 10)
- [ ] Production PC only (12.3): `reg query "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation` → 40 (0x28, equal foreground and background time)
- [ ] Open Performance Options (`SystemPropertiesPerformance.exe`) once and confirm "Adjust for best performance" is selected and every effect unticked (10.3)
- [ ] Settings → Bluetooth & devices → USB: notifications shown as off (10.12)
- [ ] `Get-Service WSearch` → StartType Disabled (10.15)
- [ ] All nodes discover each other; asset transfer to the RAID0 works
- [ ] Optional: secpol.msc → Network List Manager Policies → User cannot change location
- [ ] Soak test: representative show for several hours on all outputs
- [ ] Image the system disk (System Restore is off; the image is your rollback)

## 9. Maintenance

- [ ] No in-place updates: Windows Update is disabled for good. To move to a newer Windows, reinstall from a newer ISO and rebuild with this checklist. Check activation with `slmgr /xpr` (the Settings Activation page errors with updates disabled)
- [ ] NVIDIA: update only to versions tested for your WATCHOUT release
- [ ] Before any RAID driver or BIOS update: image first; keep RAID driver and BIOS RAID module versions matched
- [ ] Array shows Offline after no change of yours: check the drive in RAIDXpert2 (event log, health)

## Sources

- [WATCHOUT 7 User Guide – Firewall Configuration](https://docs.dataton.com/guide/watchout/network-setup/firewall-configuration.html) (v7.8.2, July 2026)
- [WATCHOUT 7 User Guide – Working Directory Management](https://docs.dataton.com/guide/watchout/network-setup/working-directory-management.html) (v7.8.2, July 2026)
- [WATCHOUT 7 System Requirements](https://docs.dataton.com/watchout-7-new/watchout/getting-started/system-requirements.html)
- [Dataton KB – GPU & Display Driver Best Practices](https://knowledge.dataton.com/knowledge/articles/gpu-display-driver-best-practices)
- [Dell KB 000443715 – Configure RAID with AMD RAIDXpert2](https://www.dell.com/support/kbdoc/en-us/000443715/how-to-configure-raid-with-amd-raidxpert2?lang=en) (24 May 2026)
- [Windows Latest – Windows 11 24H2 device encryption by default](https://windowslatest.com/2024/05/08/microsoft-confirms-windows-11-24h2-turns-on-device-encryption-by-default) (8 May 2024)
- Dataton WATCHOUT Windows 10 Enterprise Tweaking Guide, doc. 3749 rev 1.3 (2018)
