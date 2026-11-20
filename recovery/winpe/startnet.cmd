@echo off
REM ============================================================================
REM  startnet.cmd  -  goes INTO boot.wim at \Windows\System32\startnet.cmd
REM ----------------------------------------------------------------------------
REM  Kept deliberately dumb: init WinPE, then find and run wo-recovery.cmd from
REM  whichever volume carries WO_RECOVERY.tag. All logic stays on the recovery
REM  partition / USB so boot.wim rarely needs rebuilding.
REM
REM  How to inject (technician PC with Windows ADK + WinPE add-on installed,
REM  from "Deployment and Imaging Tools Environment" as admin):
REM     copype amd64 C:\WinPE_amd64
REM     dism /Mount-Image /ImageFile:C:\WinPE_amd64\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_amd64\mount
REM     copy /y startnet.cmd C:\WinPE_amd64\mount\Windows\System32\startnet.cmd
REM     dism /Unmount-Image /MountDir:C:\WinPE_amd64\mount /Commit
REM     MakeWinPEMedia /UFD C:\WinPE_amd64 F:      (F: = USB stick, gets wiped)
REM ============================================================================
wpeinit
REM Make sure the console isn't put to sleep mid-DISM.
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\WO_RECOVERY.tag if exist %%d:\wo-recovery.cmd (
        call %%d:\wo-recovery.cmd
        goto :eof
    )
)
echo wo-recovery.cmd not found on any volume with WO_RECOVERY.tag.
echo Dropping to command prompt.
