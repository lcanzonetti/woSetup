# WATCHOUT 7 Server Build Checklist

Oct 14, 2026 · @Lorenzo

Tick each box in order on every new WATCHOUT 7 display server: Windows 11 Pro (MicroWin), AMD RAID system and media arrays, WO7-Setup.ps1 for driver lockdown and the Dataton GPO set. Written for WATCHOUT 7.8.4 and Windows 11 25H2.

## 1. Before you start

Prepare a USB stick with everything below, then set up the BIOS and arrays.

- [ ] MicroWin installer USB (Windows 11 Pro), booted in UEFI mode
- [ ] AMD RAID drivers: rcbottom, rcraid, rccfg (.inf + .sys + .cat each), plus the AMD RAID package with RAIDXpert2
- [ ] NIC driver
- [ ] NVIDIA driver at the version listed in the WATCHOUT release notes, not "latest"
- [ ] Chipset, capture and audio drivers
- [ ] WO7-Setup.ps1 and LGPO.exe in the same folder
- [ ] BIOS: UEFI boot only (CSM off), Secure Boot as on your last good build, Fast Boot off
- [ ] BIOS: write down the BIOS version and storage/RAID mode settings
- [ ] RAID utility: create the system volume (1 TB) FIRST, then the RAID0 media array
- [ ] RAID utility: check no array shows as Offline; if one does, delete and recreate it

## 2. Install Windows

In RAID mode, never touch a disk in Setup before the RAID drivers are loaded: writing to a raw member disk can corrupt the array metadata and take the array offline.

- [ ] At the disk screen, **Load driver** in this order: rcbottom, then rcraid, then rccfg
- [ ] Confirm the disk list shows the arrays (system volume + one large RAID0 disk), not individual member disks
- [ ] Shift+F10 → `diskpart` → `clean` the system volume and the RAID0 to remove old partitions and ESPs
- [ ] Install to the unallocated space on the system volume; leave the RAID0 untouched
- [ ] First reboot: "Windows Boot Manager" appears in the boot menu (F12 on Lenovo)

If the boot entry is missing: check in diskpart that the FAT32 "System" partition is on the system volume, then run `bcdboot W:\Windows /s S: /f UEFI` and `bcdedit /enum firmware`.

## 3. First boot, still offline

Keep the network cable unplugged until driver search is locked, or Windows Update may install its own GPU and chipset drivers.

- [ ] Log in with the show (auto-logon) account
- [ ] Elevated PowerShell: `.\WO7-Setup.ps1 -Phase PreUpdate`
- [ ] Install the NIC driver from USB: `pnputil /add-driver <path>\*.inf /subdirs /install`
- [ ] Check the adapter in Device Manager (no warning icon)
- [ ] Plug in the network cable

## 4. Updates and drivers

- [ ] Windows Update: install everything, reboot, repeat until nothing is left
- [ ] RAID: `pnputil /enum-drivers | findstr /i /c:"rcbottom" /c:"rcraid" /c:"rccfg"` shows all three
- [ ] Install the AMD RAID package with RAIDXpert2 (same driver version you loaded in Setup)
- [ ] Chipset and storage drivers
- [ ] NVIDIA driver at the version tested for your WATCHOUT release
- [ ] Capture and audio drivers; test each in the vendor's own app

## 5. Disks

Windows 11 24H2 and later turn on device encryption by default; a BIOS or RAID change can then lock the machine at a recovery-key prompt.

- [ ] `manage-bde -status C:` → if not "Fully Decrypted", run `manage-bde -off C:` and wait
- [ ] Disk Management: initialise the RAID0 as GPT, format NTFS (64 KB allocation unit optional)
- [ ] Turn off indexing on the RAID0 drive
- [ ] RAIDXpert2: array healthy; write-back cache and read-ahead optional

## 6. WinUtil debloat

Run after updates and drivers, before WATCHOUT. Errors about wermgr, PeriodInNanoSeconds, store.db, FileCoAuth and `$Env:OneDrive` are harmless on a stripped install.

- [ ] Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer folder discovery, Hibernation, Location, Store search results, Services to Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive removal, System Tray notifications, Windows AI
- [ ] Also tick: **BitLocker - Disable**, Visual Effects - Best Performance, Storage Sense - Disable
- [ ] Skip: Edge removal (keeps WebView2), IPv6 disable, UTC time, O&O ShutUp10++, "Disable all updates" (PostInstall does the same, after all updates are in)
- [ ] Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off, Game Mode off
- [ ] Do NOT click either Ultimate Performance button (PostInstall makes its own plan)
- [ ] Multiplane Overlay: leave Enabled; disable only if the soak test shows flicker or blackouts

## 7. WATCHOUT 7 and NVIDIA

- [ ] Install WATCHOUT
- [ ] Create a folder on the RAID0, then Nodes → Node Properties → **Change Working Directory** to it
- [ ] Auto-logon with `netplwiz` (checkbox missing → Settings → Accounts → Sign-in options → turn off "only allow Windows Hello sign-in")
- [ ] NVIDIA Control Panel: global profile "Workstation – Dynamic Streaming"
- [ ] Then confirm Power Management Mode = Prefer Maximum Performance and Vertical Sync = Off
- [ ] Network: static IPs; all nodes on one subnet; IGMP snooping or multicast forwarding for 239.2.2.2 on managed switches

## 8. Windows settings from the Dataton guide

The guide's chapters 10–13 that PostInstall and WinUtil don't cover, adapted to Windows 11 and WATCHOUT 7. Guide section numbers in brackets.

### Settings

- [ ] UAC: Control Panel → User Accounts → Change User Account Control settings → **Never notify** (10.8)
- [ ] Visual effects: `sysdm.cpl` → Advanced → Performance → Adjust for best performance (10.3; skip if ticked in WinUtil)
- [ ] Remote Assistance: `sysdm.cpl` → Remote → untick "Allow Remote Assistance connections to this computer" (10.4)
- [ ] Sounds: `mmsys.cpl` → Sounds → Sound Scheme "No Sounds" (10.7)
- [ ] Disk optimisation: `dfrgui` → Change settings → untick "Run on a schedule" (10.9)
- [ ] USB: Settings → Bluetooth & devices → USB → connection and USB-issue notifications off (10.12)
- [ ] Taskbar: Settings → Personalization → Taskbar → Taskbar behaviors → show badges off (10.13)
- [ ] Startup apps: Settings → Apps → Startup → turn off everything not needed, above all anything that can steal focus (10.14)
- [ ] Indexing: every drive → Properties → untick "Allow files on this drive to have contents indexed" (10.15)
- [ ] Display scale 100% on every output: Settings → System → Display → Scale (replaces the guide's DPI registry values, 12.3)
- [ ] Network: `ncpa.cpl` → each show adapter → untick everything except IPv4 (10.10); keep Client for Microsoft Networks and File and Printer Sharing if you use network shares
- [ ] Wake-on-LAN: enable it in the BIOS and set the NIC's "Wake on Magic Packet" advanced property to Enabled (10.11)

### Registry (applied by PostInstall; listed to check after a reboot)

- [ ] GPU timeouts for slow multi-output mode changes (12.2): `reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDelay /t REG_DWORD /d 15 /f` and `reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDdiDelay /t REG_DWORD /d 60 /f`
- [ ] Multimedia CPU reserve (12.1): `reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 10 /f` (the guide says 5; Windows is reported to treat values under 10 as 10)
- [ ] Production PC only (12.3): `reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 40 /f` (40 = hex 28, equal foreground and background time)

Skip from the guide: DirectShow ThreadPriority (WATCHOUT 6 DirectShow playback), ForcePcieLinkSpeed (2018 AMD GPU / X99 workaround), HideAutoLogonUI (Windows Embedded key, likely no effect on Pro), Win8DpiScaling and LogPixels (use Scale 100% instead).

### Services and tasks

- [ ] Services: WinUtil's "Set to Manual" covers the WATCHOUT 7 routine; optionally disable Print Spooler, Fax and Bluetooth services (11). Never disable any WATCHOUT or Dataton service (Windows Update is disabled by PostInstall)
- [ ] No auto-start task: WATCHOUT 7 runs as Windows services, so the guide's WATCHPOINT logon task (13.1) is not needed

Already handled elsewhere: group policies (ch. 7), AutoPlay (10.1), power plan and USB selective suspend (10.5), PCIe link power management (AMD equivalent of 10.6) and hibernation by PostInstall; apps, OneDrive and Cortana by WinUtil; auto-logon (10.2) in section 7.

## 9. PostInstall

Applies power plan, NIC power settings, network location, notifications, the Dataton chapter 7 GPO set (Win11-adapted), the update freeze (automatic updates off, version pinned, notifications off, update services and tasks disabled), the chapter 12 registry values and Defender settings.

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

## 10. Verify, soak test, image

- [ ] `Get-MpComputerStatus | Select IsTamperProtected, RealTimeProtectionEnabled, BehaviorMonitorEnabled, OnAccessProtectionEnabled` → all False (Off mode)
- [ ] `powercfg /getactivescheme` → "WATCHOUT 7"
- [ ] `manage-bde -status C:` → Protection Off
- [ ] All nodes discover each other; asset transfer to the RAID0 works
- [ ] Optional: secpol.msc → Network List Manager Policies → User cannot change location
- [ ] Soak test: representative show for several hours on all outputs
- [ ] Image the system disk (System Restore is off; the image is your rollback)

## 11. Maintenance

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
