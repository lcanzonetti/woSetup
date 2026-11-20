# Pester 5 tests for the factory recovery (OPEN_QUESTIONS 29):
#   recovery/partition/WO-Recovery.ps1   pure helpers, loaded from the syntax tree
#   src/WOSetup.App/Engine/WO-Actions.ps1 boot-key and bcdedit helpers, and the
#                                         recovery actions refusing on a machine
#                                         without a WO_RECOVERY partition
#
# Nothing here formats, captures, applies an image or touches the boot
# configuration: those need a Windows 11 VM / real hardware (MILESTONES "R").

BeforeAll {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $recoveryPs1 = Join-Path $repo 'recovery\partition\WO-Recovery.ps1'
    $actionsPs1 = Join-Path $repo 'src\WOSetup.App\Engine\WO-Actions.ps1'

    # Dot-sourced here so the functions land in this scope.
    $recoveryNames = 'Test-ImageName', 'Test-DriveLetter', 'Get-Prop', 'Format-Bytes', 'ConvertTo-NormalGuid',
                     'Select-PartitionByGuid', 'Get-ImageSetFiles', 'Find-ImageSets', 'Remove-ImageSet',
                     'Invoke-ImageRotation', 'Get-CaptureEstimate', 'Get-CapturePlan', 'Get-UnexpectedDataEntries', 'Test-Target'
    $tokens = $null; $errors = $null
    foreach ($pair in @(@($recoveryPs1, $recoveryNames), @($actionsPs1, @('ConvertTo-BootKeyAction', 'Get-BcdGuid')))) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($pair[0], [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Parse errors in $($pair[0]): $($errors[0].Message)" }
        $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $pair[1] -contains $_.Name }
        foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
    }

    function New-Set([string]$Folder, [string]$Prefix, [string]$Name, [int]$Size = 10) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Folder "${Prefix}_C.wim") -Value ('C' * $Size) -NoNewline
        Set-Content -LiteralPath (Join-Path $Folder "${Prefix}_D.wim") -Value ('D' * $Size) -NoNewline
        Set-Content -LiteralPath (Join-Path $Folder "$Prefix.json") -Value (@{ Name = $Name; Computer = 'WO-TEST' } | ConvertTo-Json)
    }
}

Describe 'WO-Recovery.ps1 helpers' {

    It 'has every helper under test' {
        foreach ($n in $recoveryNames + 'ConvertTo-BootKeyAction', 'Get-BcdGuid') { Get-Command $n -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $n }
    }

    It 'accepts plain image names and refuses others' {
        Test-ImageName 'WO7.8.4_W11-25H2_2026-11-20' | Should -BeTrue
        Test-ImageName 'WO7 factory' | Should -BeFalse
        Test-ImageName '' | Should -BeFalse
        Test-ImageName '.hidden' | Should -BeFalse
        Test-ImageName ('a' * 81) | Should -BeFalse
    }

    It 'treats the character 0 as "no drive letter"' {
        Test-DriveLetter ([char]0) | Should -BeFalse
        Test-DriveLetter $null | Should -BeFalse
        Test-DriveLetter 'D' | Should -BeTrue
    }

    It 'matches partitions by GUID whatever the case and braces' {
        $parts = @([pscustomobject]@{ Guid = '{AAAAAAAA-1111-2222-3333-444444444444}'; N = 1 }, [pscustomobject]@{ Guid = '{bbbbbbbb-1111-2222-3333-444444444444}'; N = 2 })
        (Select-PartitionByGuid $parts 'bbbbbbbb-1111-2222-3333-444444444444').N | Should -Be 2
        (Select-PartitionByGuid $parts '{aaaaaaaa-1111-2222-3333-444444444444}').N | Should -Be 1
        Select-PartitionByGuid $parts '{cccccccc-1111-2222-3333-444444444444}' | Should -BeNullOrEmpty
        Select-PartitionByGuid $parts '' | Should -BeNullOrEmpty
        # MBR partitions have no GUID: an empty GUID must not pick them.
        Select-PartitionByGuid @([pscustomobject]@{ Guid = $null; N = 3 }) '' | Should -BeNullOrEmpty
    }

    It 'finds complete image sets on the partition and per machine on a stick' {
        $root = Join-Path $TestDrive 'find'
        New-Set (Join-Path $root 'Images') 'factory' 'A'
        New-Set (Join-Path $root 'Images') 'factory_prev' 'B'
        New-Set (Join-Path $root 'Images\WO-DISP-02') 'factory' 'C'
        # Incomplete: no D image.
        New-Item -ItemType Directory -Path (Join-Path $root 'Images\WO-DISP-03') | Out-Null
        Set-Content (Join-Path $root 'Images\WO-DISP-03\factory_C.wim') 'x'
        Set-Content (Join-Path $root 'Images\WO-DISP-03\factory.json') '{"Name":"D"}'
        $sets = Find-ImageSets @("$root\")
        @($sets | ForEach-Object { $_.Name }) | Sort-Object | Should -Be @('A', 'B', 'C')
    }

    It 'rotates new -> factory -> fallback and deletes the older fallback' {
        $f = Join-Path $TestDrive 'rotate'
        New-Set $f 'factory_prev' 'old'
        New-Set $f 'factory' 'current'
        New-Set $f 'new' 'newest'
        Invoke-ImageRotation -Folder $f | Should -BeTrue
        (Get-ImageSetFiles $f 'factory').Name | Should -Be 'newest'
        (Get-ImageSetFiles $f 'factory_prev').Name | Should -Be 'current'
        (Get-ImageSetFiles $f 'new').Complete | Should -BeFalse
        @(Get-ChildItem $f).Count | Should -Be 6
    }

    It 'never replaces a good image with an incomplete new set' {
        $f = Join-Path $TestDrive 'incomplete'
        New-Set $f 'factory' 'good'
        Set-Content (Join-Path $f 'new_C.wim') 'x'
        Set-Content (Join-Path $f 'new.json') '{"Name":"bad"}'
        { Invoke-ImageRotation -Folder $f } | Should -Throw '*incomplete*'
        (Get-ImageSetFiles $f 'factory').Name | Should -Be 'good'
    }

    It 'rotates the first capture without a fallback' {
        $f = Join-Path $TestDrive 'first'
        New-Set $f 'new' 'first'
        Invoke-ImageRotation -Folder $f | Should -BeFalse
        (Get-ImageSetFiles $f 'factory').Complete | Should -BeTrue
    }

    It 'estimates the image from the used space, or from the previous image' {
        Get-CaptureEstimate -UsedBytes 30GB -PreviousImageBytes 0 | Should -Be ([long](30GB * 0.6))
        Get-CaptureEstimate -UsedBytes 30GB -PreviousImageBytes 20GB | Should -Be ([long](20GB * 1.15))
    }

    It 'plans the room: Ok, delete the fallback first, or not enough' {
        Get-CapturePlan -FreeBytes 30GB -EstimateBytes 15GB -FallbackBytes 0 | Should -Be 'Ok'
        Get-CapturePlan -FreeBytes 10GB -EstimateBytes 15GB -FallbackBytes 15GB | Should -Be 'DeleteFallback'
        Get-CapturePlan -FreeBytes 10GB -EstimateBytes 15GB -FallbackBytes 0 | Should -Be 'NotEnough'
        Get-CapturePlan -FreeBytes 2GB -EstimateBytes 15GB -FallbackBytes 5GB | Should -Be 'NotEnough'
    }

    It 'lists what on D: would wrongly become factory state' {
        $extra = Get-UnexpectedDataEntries -Entries @('WATCHOUT 7', 'WO7-Work', 'System Volume Information', '$RECYCLE.BIN', 'Shows', 'media.mov') -Allowed @('WATCHOUT 7', 'wo7-work')
        @($extra) | Should -Be @('Shows', 'media.mov')
        @(Get-UnexpectedDataEntries -Entries @('WATCHOUT 7') -Allowed @('WATCHOUT 7')).Count | Should -Be 0
    }

    It 'reports a target.json without partition GUIDs' {
        @(Test-Target $null).Count | Should -Be 1
        @(Test-Target ([pscustomobject]@{ System = [pscustomobject]@{ PartitionGuid = '{a}' } })).Count | Should -Be 1
        $ok = [pscustomobject]@{ System = [pscustomobject]@{ PartitionGuid = '{a}' }; Data = [pscustomobject]@{ PartitionGuid = '{b}' } }
        @(Test-Target $ok).Count | Should -Be 0
    }
}

Describe 'WO-Actions.ps1 boot helpers' {

    It 'builds the boot manager key code (F10 = scan code 0x44)' {
        ConvertTo-BootKeyAction 'F10' | Should -Be '0x1000044000001'
        ConvertTo-BootKeyAction 'F9' | Should -Be '0x1000043000001'
        { ConvertTo-BootKeyAction 'F12' } | Should -Throw
        { ConvertTo-BootKeyAction '' } | Should -Throw
    }

    It 'reads the GUID bcdedit prints, in any language' {
        Get-BcdGuid @('The entry {6A1B2C3D-0000-1111-2222-333344445555} was successfully created.') | Should -Be '{6a1b2c3d-0000-1111-2222-333344445555}'
        Get-BcdGuid @('La voce {6a1b2c3d-0000-1111-2222-333344445555} è stata creata.') | Should -Be '{6a1b2c3d-0000-1111-2222-333344445555}'
        Get-BcdGuid @('error') | Should -BeNullOrEmpty
    }
}

Describe 'Recovery scripts as run by the wizard and WinPE' {

    BeforeAll {
        # The wizard extracts WO-Actions.ps1 and WO-Recovery.ps1 into one run folder.
        $run = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'run')).FullName
        Copy-Item $actionsPs1, $recoveryPs1 $run
        function Invoke-Action([string]$Name, [hashtable]$Params) {
            $result = Join-Path $run "$Name.json"
            $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $run 'WO-Actions.ps1'), '-Action', $Name, '-ResultPath', $result)
            if ($Params) {
                $pj = Join-Path $run "$Name.params.json"
                $Params | ConvertTo-Json -Depth 4 | Set-Content -Path $pj -Encoding UTF8
                $argv += @('-ParamsJson', $pj)
            }
            & powershell.exe @argv | Out-Host
            [pscustomobject]@{ Exit = $LASTEXITCODE; Result = (Get-Content -Raw $result | ConvertFrom-Json) }
        }
    }

    It 'dot-sourcing WO-Recovery.ps1 defines the helpers without starting the menu' {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$recoveryPs1'; if (Get-Command Find-ImageSets -ErrorAction SilentlyContinue) { 'LOADED' }" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'LOADED'
        ($out -join "`n") | Should -Not -Match 'factory recovery'
    }

    It 'list-recovery-usb runs (no stick on CI)' {
        $r = Invoke-Action 'list-recovery-usb' $null
        $r.Exit | Should -Be 0
        $r.Result.Status | Should -Be 'Completed'
    }

    It 'recovery-install refuses without the WinPE build, before changing anything' {
        $r = Invoke-Action 'recovery-install' @{ SourceFolder = (Join-Path $run 'missing'); Hotkey = 'F9'; DataDrive = 'D' }
        $r.Exit | Should -Be 2
        $r.Result.Status | Should -Be 'Failed'
        ($r.Result.Warnings -join ' ') | Should -Match 'manifest.json'
    }

    It 'recovery-capture refuses a bad name, before changing anything' {
        $r = Invoke-Action 'recovery-capture' @{ Name = 'bad name' }
        $r.Exit | Should -Be 2
        ($r.Result.Warnings -join ' ') | Should -Match 'not valid'
    }

    It 'recovery-capture refuses without a WO_RECOVERY partition (CI runner)' {
        $r = Invoke-Action 'recovery-capture' @{ Name = 'WO7_W11-25H2_2026-11-20' }
        $r.Exit | Should -Be 2
        ($r.Result.Warnings -join ' ') | Should -Match 'WO_RECOVERY'
    }

    It 'recovery-export refuses without a WO_RECOVERY partition (CI runner)' {
        $r = Invoke-Action 'recovery-export' @{ Destination = (Join-Path $run 'out') }
        $r.Exit | Should -Be 2
        ($r.Result.Warnings -join ' ') | Should -Match 'WO_RECOVERY'
    }
}
