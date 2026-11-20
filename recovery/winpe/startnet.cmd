@echo off
REM ============================================================================
REM  startnet.cmd - goes INTO boot.wim at \Windows\System32\startnet.cmd
REM  (tools/recovery/Build-WinPE.ps1 puts it there).
REM  Initialises WinPE, keeps the machine awake during long DISM runs, then
REM  starts the WATCHOUT factory recovery (Start-WORecovery.ps1, also in
REM  boot.wim). If that fails, this command prompt stays open.
REM ============================================================================
wpeinit
REM High performance power plan: no sleep in the middle of a capture or restore.
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
if exist X:\WORecovery\Start-WORecovery.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\WORecovery\Start-WORecovery.ps1
echo.
echo WATCHOUT recovery ended or could not start.
echo Command prompt: "wpeutil reboot" restarts the machine.
