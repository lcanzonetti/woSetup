@echo off
REM ============================================================================
REM  install-recovery-boot.cmd  -  run ONCE in Windows, as Administrator
REM ----------------------------------------------------------------------------
REM  Adds a hidden "WATCHOUT Factory Restore" entry to the boot manager that
REM  boots the customized WinPE boot.wim from the recovery partition (RAM disk
REM  boot), and creates a one-shot launcher (FactoryRestore.cmd).
REM
REM  Design choice: the entry is NOT added to the visible boot menu, so a
REM  show machine boots straight to Windows with no menu/timeout on screen.
REM  It's reached with "bcdedit /bootsequence" (next boot only) from
REM  FactoryRestore.cmd. If Windows itself won't boot, use the USB stick.
REM
REM  Prerequisites:
REM    - Recovery partition exists and is temporarily mounted as R:
REM      (e.g. diskpart > select volume N > assign letter=R)
REM    - R:\Recovery\boot.wim  = your customized WinPE boot.wim
REM    - R:\Recovery\boot.sdi  = from <ADK>\...\Windows Preinstallation
REM                              Environment\amd64\Media\Boot\boot.sdi
REM    - R:\WO_RECOVERY.tag, R:\wo-recovery.cmd, R:\Images\factory.wim
REM  UEFI only (winload.efi). UNTESTED TEMPLATE - verify on a spare machine.
REM ============================================================================
setlocal EnableDelayedExpansion
set "R=R:"
if not exist %R%\Recovery\boot.wim (echo %R%\Recovery\boot.wim missing & exit /b 1)
if not exist %R%\Recovery\boot.sdi (echo %R%\Recovery\boot.sdi missing & exit /b 1)

REM Backup the BCD store first - restore with: bcdedit /import C:\bcd-backup.bcd
bcdedit /export C:\bcd-backup.bcd || exit /b 1

REM {ramdiskoptions} is a well-known GUID; it may already exist (e.g. WinRE),
REM so try to create it and ignore the error if it does.
bcdedit /create {ramdiskoptions} /d "WO Ramdisk Options" >nul 2>&1
bcdedit /set {ramdiskoptions} ramdisksdidevice partition=%R%
bcdedit /set {ramdiskoptions} ramdisksdipath \Recovery\boot.sdi

REM Create the loader entry and capture the GUID bcdedit prints.
for /f "tokens=2 delims={}" %%g in ('bcdedit /create /d "WATCHOUT Factory Restore" /application osloader') do set "GUID={%%g}"
if not defined GUID (echo Could not create loader entry & exit /b 1)
echo Created entry %GUID%

bcdedit /set %GUID% device   ramdisk=[%R%]\Recovery\boot.wim,{ramdiskoptions}
bcdedit /set %GUID% osdevice ramdisk=[%R%]\Recovery\boot.wim,{ramdiskoptions}
bcdedit /set %GUID% path \windows\system32\boot\winload.efi
bcdedit /set %GUID% systemroot \windows
bcdedit /set %GUID% winpe yes
bcdedit /set %GUID% detecthal yes
REM Deliberately NOT added to /displayorder -> invisible at normal boot.

REM One-shot launcher: boots the restore environment on the NEXT boot only.
> "%PUBLIC%\Desktop\FactoryRestore.cmd" (
  echo @echo off
  echo REM Requires admin. Reboots ONCE into the WATCHOUT recovery environment.
  echo bcdedit /bootsequence %GUID% ^&^& shutdown /r /t 5 /c "Rebooting into WATCHOUT recovery"
)

echo.
echo Done. Now remove R: so Windows/WATCHOUT never see the partition:
echo    mountvol %R% /d
echo The BCD references the partition itself, not the letter, so this is safe.
