# Pester 5 smoke tests for the wizard's helper scripts (src/WOSetup.App/Engine):
#   WO-Checks.ps1   every check, really run (all checks are read-only)
#   WO-Actions.ps1  only the two read-only queries (list-disks, list-adapters)
#
# The actions that change the machine are never run here.
# Needs an elevated Windows PowerShell 5.1 (GitHub's windows-latest runner is
# elevated). On a CI runner most checks answer NotDone / NotApplicable: the
# test only proves that every check runs without a script error and writes
# a valid result, not that the answers are right for a WATCHOUT machine.

BeforeAll {
    $engine = Join-Path $PSScriptRoot '..\..\src\WOSetup.App\Engine'
    $checksPs1 = (Resolve-Path (Join-Path $engine 'WO-Checks.ps1')).Path
    $actionsPs1 = (Resolve-Path (Join-Path $engine 'WO-Actions.ps1')).Path
    $work = Join-Path ([IO.Path]::GetTempPath()) ("wosetup-pester-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null

    # Every check id, read from the $Checks table ('id' = { ... }).
    $allIds = @([regex]::Matches((Get-Content -Raw $checksPs1), "(?m)^\s{4}'([a-z0-9-]+)'\s*=\s*\{") | ForEach-Object { $_.Groups[1].Value })

    function Invoke-Checks([string]$ProfileName, [string[]]$Ids) {
        $params = Join-Path $work "ctx-$ProfileName.json"
        $result = Join-Path $work "checks-$ProfileName.json"
        @{ Profile = $ProfileName; Role = 'Display'; Options = @{ DefenderMode = 'Off'; KeepUpdateService = $false } } |
            ConvertTo-Json -Depth 4 | Set-Content -Path $params -Encoding UTF8
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $checksPs1 -Ids ($Ids -join ',') -ParamsJson $params -ResultPath $result | Out-Host
        $exit = $LASTEXITCODE
        # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE
        # object; ForEach-Object unrolls it into its elements.
        [pscustomobject]@{ Exit = $exit; Results = @(Get-Content -Raw $result | ConvertFrom-Json | ForEach-Object { $_ }) }
    }

    function Invoke-Query([string]$Name) {
        $result = Join-Path $work "$Name.json"
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $actionsPs1 -Action $Name -ResultPath $result | Out-Host
        $exit = $LASTEXITCODE
        [pscustomobject]@{ Exit = $exit; Result = (Get-Content -Raw $result | ConvertFrom-Json) }
    }
}

AfterAll {
    if ($work -and (Test-Path $work)) { Remove-Item -Recurse -Force $work }
}

Describe 'WO-Checks.ps1 (<_>)' -ForEach @('WO7', 'WO6') {

    BeforeAll {
        $run = Invoke-Checks -ProfileName $_ -Ids $allIds
    }

    It 'finds the check table' {
        $allIds.Count | Should -BeGreaterThan 25
    }

    It 'exits 0 and answers every check once' {
        $run.Exit | Should -Be 0
        @($run.Results | ForEach-Object { $_.Id }) | Should -Be $allIds
    }

    It 'uses only the four states' {
        $run.Results | ForEach-Object { $_.State | Should -BeIn @('Done', 'NotDone', 'NotApplicable', 'CantCheck') }
    }

    It 'has no check that crashed (a crash is reported as "The check failed")' {
        $crashed = @($run.Results | Where-Object { "$($_.Detail)" -like 'The check failed*' } | ForEach-Object { "$($_.Id): $($_.Detail)" })
        $run.Results | ForEach-Object { Write-Host ("    {0,-26} {1,-13} {2}" -f $_.Id, $_.State, $_.Detail) }
        $crashed | Should -BeNullOrEmpty
    }
}

Describe 'WO-Checks.ps1 input' {
    It 'reports an unknown id as CantCheck instead of failing' {
        $r = Invoke-Checks -ProfileName 'WO7' -Ids @('no-such-check', 'preflight')
        $r.Exit | Should -Be 0
        $r.Results[0].State | Should -Be 'CantCheck'
        $r.Results[1].Id | Should -Be 'preflight'
    }
}

Describe 'WO-Actions.ps1 read-only queries' {
    It 'list-disks never offers the system disk' {
        $q = Invoke-Query 'list-disks'
        $q.Exit | Should -Be 0
        $q.Result.Status | Should -Be 'Completed'
        $system = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
        @($q.Result.Data | ForEach-Object { $_ } | Where-Object { $_.Number -eq $system }) | Should -BeNullOrEmpty
    }

    It 'list-adapters returns the physical adapters' {
        $q = Invoke-Query 'list-adapters'
        $q.Exit | Should -Be 0
        $q.Result.Status | Should -Be 'Completed'
        @($q.Result.Data | ForEach-Object { $_ }).Count | Should -Be @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' }).Count
    }

    It 'refuses an unknown action' {
        $q = Invoke-Query 'format-everything'
        $q.Exit | Should -Be 2
        $q.Result.Status | Should -Be 'Failed'
    }
}

# The setup scripts' result file (-ResultPath), written at the end of every
# run. Exercised with -Audit, which is read-only, on a copy of each script
# (the transcript is written next to the script).
Describe 'Result file of <_>' -ForEach @('WO7-Setup.ps1', 'WO6-Setup.ps1') {

    BeforeAll {
        $name = $_
        $dir = Join-Path $work ("result-" + [IO.Path]::GetFileNameWithoutExtension($name))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir $name
        Copy-Item (Join-Path $PSScriptRoot "..\..\scripts\$name") $copy

        function Invoke-Audit([string]$Phase) {
            $result = Join-Path $dir "result-$Phase.json"
            $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy -Phase $Phase -Audit -ResultPath $result 2>&1
            $out | Out-Host
            [pscustomobject]@{
                Exit       = $LASTEXITCODE
                Path       = $result
                NotWritten = @($out | Where-Object { "$_" -match 'Result file not written' })
            }
        }
    }

    It 'writes a readable result file for <Phase>' -ForEach @(@{ Phase = 'PreUpdate' }, @{ Phase = 'PostInstall' }) {
        $r = Invoke-Audit $Phase
        $r.NotWritten | Should -BeNullOrEmpty
        Test-Path $r.Path | Should -BeTrue
        $json = Get-Content -Raw $r.Path | ConvertFrom-Json
        $json.schemaVersion | Should -Be 2
        $json.phase | Should -Be $Phase
        $json.mode | Should -Be 'Audit'
        $json.parameters.Phase | Should -Be $Phase
        $json.parameters.Audit | Should -BeTrue
    }
}
