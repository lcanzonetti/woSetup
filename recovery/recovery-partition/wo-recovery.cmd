@echo off
REM ============================================================================
REM  wo-recovery.cmd  -  WATCHOUT media server "factory" capture / restore tool
REM ----------------------------------------------------------------------------
REM  Runs INSIDE WinPE (booted from the on-disk recovery entry or from USB).
REM  Lives on the recovery partition / USB stick, NOT inside boot.wim, so you
REM  can edit it without rebuilding WinPE (startnet.cmd just calls it).
REM
REM  Volume detection is done with marker files instead of drive letters,
REM  because WinPE assigns letters in its own order and they WILL differ from
REM  what you see in Windows:
REM     <Windows volume>\WO_SYSTEM.tag      -> the C: you want to restore
REM     <recovery volume>\WO_RECOVERY.tag   -> holds \Images\factory.wim
REM  Create both tags once, from Windows:
REM     echo.> C:\WO_SYSTEM.tag
REM     echo.> R:\WO_RECOVERY.tag        (R: = recovery partition / USB stick)
REM  WO_SYSTEM.tag gets captured into the image, so it survives every restore.
REM
REM  What this touches:   ONLY the volume holding WO_SYSTEM.tag (normally C:).
REM  What it never touches: the media/show volume (D:), EFI partition, BCD.
REM  Because the partition layout and the EFI/BCD are left as they are, the
REM  existing boot entry still points at the same partition after a restore,
REM  so no bcdboot is needed (it's offered as option 4 if boot is broken).
REM
REM  UNTESTED TEMPLATE: dry-run it on a spare disk before trusting it in the field.
REM ============================================================================
setlocal EnableDelayedExpansion
title WATCHOUT Recovery

:FIND
set "SYS="
set /a N=0
REM X: is the WinPE RAM disk itself - skip it.
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\WO_SYSTEM.tag   set "SYS=%%d:"
    if exist %%d:\WO_RECOVERY.tag (
        set /a N+=1
        set "LOC!N!=%%d:"
    )
)

:MENU
cls
echo  ==========================================================
echo   WATCHOUT media server - recovery
echo  ==========================================================
echo   System volume (WO_SYSTEM.tag) : %SYS%
echo   Image locations found         : %N%
for /l %%i in (1,1,%N%) do (
    set "L=!LOC%%i!"
    if exist "!L!\Images\factory.wim" (echo     [%%i] !L!\Images\factory.wim) else (echo     [%%i] !L!  ^(no factory.wim yet^))
)
echo.
echo   1  Restore factory image  (ERASES the system volume)
echo   2  Capture current system as new factory image
echo   3  Show image info
echo   4  Repair boot files (bcdboot) - only if Windows won't boot after restore
echo   5  Command prompt
echo   6  Reboot
echo.
set "OPT="
set /p OPT=Choice:
if "%OPT%"=="1" goto RESTORE
if "%OPT%"=="2" goto CAPTURE
if "%OPT%"=="3" goto INFO
if "%OPT%"=="4" goto BOOTFIX
if "%OPT%"=="5" (cmd /k & goto MENU)
if "%OPT%"=="6" (wpeutil reboot)
goto MENU

REM ---------------------------------------------------------------------------
:PICKLOC
REM Lets the operator choose internal partition vs USB when both are present.
REM Always RETURNS (never jumps to MENU from inside a CALL, which would nest
REM batch contexts); callers check "if not defined REC".
set "REC="
set "PICK="
if %N%==0 (echo No WO_RECOVERY.tag volume found. & pause & goto :eof)
if %N%==1 (set "REC=!LOC1!" & goto :eof)
set /p PICK=Which image location [1-%N%]: 
if defined PICK set "REC=!LOC%PICK%!"
if not defined REC (echo Invalid choice. & pause)
goto :eof

REM ---------------------------------------------------------------------------
:RESTORE
if not defined SYS (echo WO_SYSTEM.tag not found - refusing to guess which volume to wipe. & pause & goto MENU)
call :PICKLOC
if not defined REC goto MENU
set "IMG=%REC%\Images\factory.wim"
if not exist "%IMG%" (echo %IMG% not found. & pause & goto MENU)
echo.
echo  !!! %SYS% will be FORMATTED and replaced with %IMG% !!!
echo  Other volumes (show media) are not touched.
set "ANS="
set /p ANS=Type RESTORE to continue:
if /i not "%ANS%"=="RESTORE" goto MENU

REM diskpart is used instead of FORMAT.COM because FORMAT can stop and ask
REM for the current volume label, which would hang an unattended run.
> X:\fmt.txt  echo select volume %SYS:~0,1%
>> X:\fmt.txt echo format fs=ntfs quick label=Windows
diskpart /s X:\fmt.txt || (echo Format failed. & pause & goto MENU)

dism /Apply-Image /ImageFile:"%IMG%" /Index:1 /ApplyDir:%SYS%\ /CheckIntegrity /Verify
if errorlevel 1 (echo DISM apply FAILED - system volume is now empty/partial. Retry or use USB. & pause & goto MENU)
echo.
echo Restore complete. Remove the USB stick if used, then reboot.
pause
goto MENU

REM ---------------------------------------------------------------------------
:CAPTURE
if not defined SYS (echo WO_SYSTEM.tag not found. & pause & goto MENU)
call :PICKLOC
if not defined REC goto MENU
if not exist "%REC%\Images" md "%REC%\Images"
REM Name the image with what's inside it - you'll thank yourself later.
set "LBL="
set /p LBL=Image name (e.g. WO7.4_W11-24H2_2026-11-20):
if not defined LBL set "LBL=WO-factory"
REM Write to a temp file first; only replace factory.wim once DISM succeeded.
REM The previous image is kept as factory_prev.wim (one level of rollback).
dism /Capture-Image /ImageFile:"%REC%\Images\new.wim" /CaptureDir:%SYS%\ /Name:"%LBL%" /Compress:max /CheckIntegrity /Verify
if errorlevel 1 (echo Capture FAILED - existing factory.wim kept. & del "%REC%\Images\new.wim" 2>nul & pause & goto MENU)
if exist "%REC%\Images\factory_prev.wim" del "%REC%\Images\factory_prev.wim"
if exist "%REC%\Images\factory.wim" ren "%REC%\Images\factory.wim" factory_prev.wim
ren "%REC%\Images\new.wim" factory.wim
echo Capture complete: %REC%\Images\factory.wim  (%LBL%)
pause
goto MENU

REM ---------------------------------------------------------------------------
:INFO
call :PICKLOC
if not defined REC goto MENU
dism /Get-ImageInfo /ImageFile:"%REC%\Images\factory.wim" /Index:1
pause
goto MENU

REM ---------------------------------------------------------------------------
:BOOTFIX
if not defined SYS (echo WO_SYSTEM.tag not found. & pause & goto MENU)
REM mountvol /s mounts the EFI System Partition (UEFI systems only).
mountvol S: /s
bcdboot %SYS%\Windows /s S: /f UEFI
echo NOTE: bcdboot may re-order the boot menu; re-run install-recovery-boot.cmd
echo       from Windows if the "Factory Restore" entry disappeared.
pause
goto MENU
