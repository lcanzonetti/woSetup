# Factory recovery (WATCHOUT 7)

A factory reset returns the machine to the end of the build: Windows and
WATCHOUT freshly installed and tweaked (owner, 20 Nov 2026). The factory
image is C: plus the RAID0 (D:, WATCHOUT folder + empty working directory),
captured together before any show. Shows and assets are not kept.

Decisions: `docs/OPEN_QUESTIONS.md` item 29. Design as built:
`docs/ARCHITECTURE.md` §14. Checklist: WO7 section 8 "Factory image" and
section 9. **Not yet run on Windows** (MILESTONES "R"): every DISM, format,
partition and boot-configuration step is [Uncertain] until tested on a VM
and on the ThinkStation.

| File | Runs on | What it does |
| --- | --- | --- |
| `winpe/startnet.cmd` | WinPE (inside boot.wim) | `wpeinit`, High performance plan, starts `Start-WORecovery.ps1` |
| `winpe/Start-WORecovery.ps1` | WinPE (inside boot.wim, `X:\WORecovery`) | Gives the hidden WO_RECOVERY partition a letter, runs `WO-Recovery.ps1` from it, else from the USB stick, else the copy in boot.wim |
| `partition/WO-Recovery.ps1` | WinPE; also embedded in the wizard | Menu: restore (typed `RESTORE`), capture (typed `CAPTURE`, or a request from the wizard), last result, bcdboot repair, command prompt, restart. Shared image-set helpers for the wizard |
| `../tools/recovery/Build-WinPE.ps1` | Technician PC with the ADK | Builds `WOSetupRecovery\` (WinPE + PowerShell + storage cmdlets + RAID drivers + these scripts, manifest with SHA-256s) |
| `../tools/recovery/New-RecoveryUsb.ps1` | Technician PC | Recovery USB stick: FAT32 WinPE + NTFS images (typed `USB <n>`) |
| `../src/WOSetup.App/Engine/WO-Actions.ps1` | Show machine (wizard) | `recovery-install` (typed `BOOT`), `recovery-capture` (typed `CAPTURE`), `recovery-export` |

## How it is used

1. **Technician PC, once per ADK / driver set:** `Build-WinPE.ps1
   -DriverFolder <RAID driver folder>`; put `WOSetupRecovery\` next to
   `WOSetupWizard.exe` on the USB stick. `New-RecoveryUsb.ps1 -DiskNumber <n>
   -SourceFolder .\WOSetupRecovery` for a recovery stick.
2. **Windows Setup:** create the `WO_RECOVERY` partition
   (`docs/PROJECT_CONTEXT.md` §2a).
3. **Wizard, end of the build:** install the recovery boot, test the key
   and the stick once per model, capture the factory image before any
   show, node/asset test and soak test, copy the image to the recovery
   stick.
4. **Field:** desktop `Factory recovery.cmd`, the recovery key at
   power-on, automatic after failed starts, or the USB stick → Restore →
   type `RESTORE`.

## What changed from the first templates (owner's zip, 20 Nov 2026)

The batch templates were replaced by PowerShell (WinPE-PowerShell). The
issues found when reading them are handled as follows:

1. Target found by the partition GUIDs in `target.json`, not by a tag on
   C:; by hand (sizes and labels shown) when a disk was replaced.
2. Ways in before Windows starts: recovery key and failover (plus the USB
   stick), not only the desktop file.
3. The desktop file elevates itself.
4. The boot entry has its own ramdisk device object, not `{ramdiskoptions}`.
5. `winload.efi`'s path is read from boot.wim at build time (manifest).
6. Room is checked before a capture (estimate [Uncertain]); the older
   fallback is deleted first when needed.
7. RAID drivers are injected by `Build-WinPE.ps1` (AMD order first).
8. USB stick: two partitions, images whole on NTFS.
9. Typed `RESTORE` and `CAPTURE` kept (owner decision).
10. Every run is logged on the recovery partition (`Logs\`, DISM logs,
    `last-result.json`, read back by the wizard's check).
11. Image names follow the build target (`..._W11-25H2_...`).
12. The BCD backup goes to the wizard's run folder, not to C:.
