# Recovery toolkit (factory restore) — untested templates

Committed as received from the owner on 20 Nov 2026 (`wo-recovery-toolkit.zip`,
from a design session the same day). **Not yet run on any machine.** Design,
decisions and open items: `docs/PROJECT_CONTEXT.md` §2a and §8,
`docs/OPEN_QUESTIONS.md` item 29, WO7 checklist section 8 "Factory image".

| File | Where it runs | What it does |
| --- | --- | --- |
| `winpe/startnet.cmd` | Injected into the ADK WinPE `boot.wim` (`\Windows\System32\startnet.cmd`) | `wpeinit`, High performance power plan, then runs `wo-recovery.cmd` from the first volume carrying `WO_RECOVERY.tag` |
| `recovery-partition/wo-recovery.cmd` | WinPE, from the recovery partition or a USB stick | Menu: restore `\Images\factory.wim` to the volume carrying `WO_SYSTEM.tag`, capture a new image (previous one kept as `factory_prev.wim`), image info, `bcdboot` repair, command prompt, reboot |
| `windows/install-recovery-boot.cmd` | Windows, once, as administrator, with the recovery partition mounted as `R:` | BCD backup, RAM-disk WinPE loader entry "WATCHOUT Factory Restore" (UEFI, not in the boot menu), `FactoryRestore.cmd` on the Public Desktop (`bcdedit /bootsequence` + restart) |

## Required behaviour (owner, 20 Nov 2026) — not in the templates yet

A factory reset returns the machine to the end of the build, WATCHOUT
included (WATCHOUT 7 is installed on the RAID0, D:). The templates handle C:
only; the port must:

- **Capture** C: and D: in one go, as two images with the same name and date
  (e.g. `factory_C.wim` + `factory_D.wim`), before any show is loaded. Warn
  and ask before capturing if D: holds more than the WATCHOUT folder and an
  empty working directory (show data would become factory state).
- **Restore** both: format C: and D:, apply both images, refuse if the two
  do not come from the same capture. Find D: by its partition GUID (stored
  with the system partition's in `target.json`), not by letter. The
  confirmation screen (`RESTORE`) says that D: is erased too.
- After the restore, set the D: root folder's "not content indexed"
  attribute again (OPEN_QUESTIONS 29g).
- Keep the previous pair as the fallback (`factory_prev_*`), as today for
  C: alone.

## Known issues found by reading (not fixed yet)

To be handled when the toolkit is ported to PowerShell (plan step 1); the
templates are kept unchanged here so the starting point is on record.

1. **Restore cannot find its target once C: is empty.** The target is the
   volume carrying `WO_SYSTEM.tag`, which lives on C:. If C: is corrupt, or
   a restore formatted C: and then DISM failed, the menu refuses to restore
   again ("WO_SYSTEM.tag not found"). Plan: store the system partition's
   GUID (and disk, size) in a `target.json` on the recovery partition.
   If more than one volume carries the tag, the last letter found wins
   silently.
2. **No way in when Windows does not start.** The boot entry is reachable
   only through `FactoryRestore.cmd` from a running Windows, or a USB
   stick (OPEN_QUESTIONS 29a).
3. **`FactoryRestore.cmd` needs "Run as administrator".** A double-click
   runs it without elevation, `bcdedit` is refused and nothing happens
   (safe, but confusing).
4. **`{ramdiskoptions}` is shared.** If it already exists, its SDI device
   and path are overwritten, which can break whatever else uses it
   (WinRE normally uses its own GUID **[Uncertain]**). Plan: a new device
   object for this entry.
5. **`path \windows\system32\boot\winload.efi`** **[Uncertain]**: confirm
   the file exists at that path in the ADK 26100 `boot.wim`
   (`\Windows\System32\winload.efi` is the other usual location).
6. **Space during capture:** `factory_prev.wim` is deleted only after
   `new.wim` succeeds, so the partition briefly holds three images.
   With 45 GB this needs images of about 14 GB or less, C: and D: together
   **[Uncertain: real size unknown until the first capture]**.
7. **RAID driver not in WinPE:** the `startnet.cmd` header does not inject
   drivers; without `dism /Add-Driver` (AMD `rcbottom`/`rcraid`/`rccfg`,
   Broadcom `megasas35`) WinPE cannot see C: on a RAID system array.
8. **USB stick:** `MakeWinPEMedia /UFD` makes one FAT32 partition, which
   cannot hold a `.wim` over 4 GB (OPEN_QUESTIONS 29c).
9. **Typed confirmations:** `RESTORE` is kept (owner, OPEN_QUESTIONS 29);
   capture and the boot-entry install still need theirs (proposed
   `CAPTURE`, `BOOT`).
10. **No log file:** capture and restore output is only on screen.
11. Example image name says `24H2`; the build target is 25H2
    (`WO7.8.4_W11-25H2_<date>`).
12. `bcdedit /export C:\bcd-backup.bcd` puts the BCD backup on C:, so it
    ends up inside every captured image.
