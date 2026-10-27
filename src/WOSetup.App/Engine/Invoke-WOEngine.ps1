#requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs WO7-Setup.ps1 or WO6-Setup.ps1 for the setup wizard. Plumbing only:
    it changes nothing on the machine by itself.

.DESCRIPTION
    Why a wrapper (ARCHITECTURE section 6.3):
      * Options arrive as a JSON file and are SPLATTED. Passing them on the
        powershell.exe -File command line would turn
        "-KeepService TermService,SessionEnv" into ONE string, so the RDP
        services would be disabled although they were meant to be kept.
        Splatting also avoids quoting problems with paths such as C:\WATCHOUT 6.
      * Console output is switched to UTF-8 so accented text (e.g. Italian
        Windows error messages) reaches the wizard intact.
      * Clear exit codes: 0 = the script finished (warnings are in its result
        file), 2 = the script stopped with an error ([FATAL] line has the reason).

.PARAMETER Script
    Full path of the setup script to run.

.PARAMETER ParamsJson
    JSON object: parameter name -> value. true/false become switches,
    arrays become string arrays.
#>
param(
    [Parameter(Mandatory)] [string]$Script,
    [Parameter(Mandatory)] [string]$ParamsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# UTF-8 without BOM for everything written to the redirected console.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$splat = @{}
$data = Get-Content -Raw -LiteralPath $ParamsJson -Encoding UTF8 | ConvertFrom-Json
foreach ($p in $data.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [bool])         { $splat[$p.Name] = [switch]$v }
    elseif ($v -is [object[]]) { $splat[$p.Name] = [string[]]$v }
    elseif ($null -ne $v)      { $splat[$p.Name] = $v }
}

try {
    & $Script @splat
    exit 0
}
catch {
    Write-Host "[FATAL] $($_.Exception.Message)"
    exit 2
}
