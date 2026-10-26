# Pester 5 tests for the pure functions of WO7-Setup.ps1 and WO6-Setup.ps1.
#
# The scripts cannot be dot-sourced in a test: their top level has a
# mandatory -Phase, #requires -RunAsAdministrator and Start-Transcript.
# Instead each script is parsed and only the function definitions under
# test are loaded from its syntax tree, so nothing on the machine changes.
#
# Run (Windows PowerShell 5.1 or PowerShell 7, Pester 5):
#   Invoke-Pester -Path .\tests\pester -Output Detailed

Describe '<_>' -ForEach @('WO7-Setup.ps1', 'WO6-Setup.ps1') {

    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot "..\..\scripts\$_"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Parse errors in ${_}: $($parseErrors[0].Message)" }

        $wanted = 'Add-Policy', 'ConvertTo-LgpoText'
        $defs = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object { $wanted -contains $_.Name }
        foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

        # Splits rendered text into lines, independent of CRLF/LF.
        function Get-Lines([string]$Text) { $Text -split "\r?\n" }
    }

    BeforeEach {
        # Add-Policy queues into $script:Policies, as in the scripts.
        $script:Policies = New-Object System.Collections.Generic.List[object]
    }

    It 'parses without errors and defines both functions' {
        Get-Command Add-Policy -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-LgpoText -CommandType Function | Should -Not -BeNullOrEmpty
    }

    Context 'Add-Policy de-duplication' {
        It 'keeps only the last definition of the same Scope+Key+Name' {
            Add-Policy Computer 'Software\Policies\Test' 'Value1' 1 'first'
            Add-Policy Computer 'Software\Policies\Test' 'Value1' 2 'second'
            $script:Policies.Count | Should -Be 1
            $script:Policies[0].Value | Should -Be 2
            $script:Policies[0].Comment | Should -Be 'second'
        }

        It 'keeps entries that differ only in Scope' {
            Add-Policy Computer 'Software\Policies\Test' 'Value1' 1 'computer'
            Add-Policy User     'Software\Policies\Test' 'Value1' 1 'user'
            $script:Policies.Count | Should -Be 2
        }

        It 'keeps entries that differ only in Name' {
            Add-Policy Computer 'Software\Policies\Test' 'A' 1 'a'
            Add-Policy Computer 'Software\Policies\Test' 'B' 1 'b'
            $script:Policies.Count | Should -Be 2
        }

        It 'defaults to DWORD and accepts SZ' {
            Add-Policy Computer 'Software\Policies\Test' 'D' 1 'dword'
            Add-Policy Computer 'Software\Policies\Test' 'S' 'Windows 11' 'string' -Type SZ
            ($script:Policies | Where-Object Name -eq 'D').Type | Should -Be 'DWORD'
            ($script:Policies | Where-Object Name -eq 'S').Type | Should -Be 'SZ'
        }
    }

    Context 'ConvertTo-LgpoText' {
        It 'renders one block per policy in LGPO text format' {
            Add-Policy Computer 'Software\Policies\Microsoft\Windows\DriverSearching' 'DontPromptForWindowsUpdate' 1 '7.3.2 test'
            $lines = Get-Lines (ConvertTo-LgpoText -Policies $script:Policies)
            $lines[0] | Should -Be '; 7.3.2 test'
            $lines[1] | Should -Be 'Computer'
            $lines[2] | Should -Be 'Software\Policies\Microsoft\Windows\DriverSearching'
            $lines[3] | Should -Be 'DontPromptForWindowsUpdate'
            $lines[4] | Should -Be 'DWORD:1'
            $lines[5] | Should -Be ''
        }

        It 'writes DWORD values in decimal and SZ values as text' {
            Add-Policy Computer 'Software\Policies\Test' 'Autoplay' 255 'dword'
            Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate' 'TargetReleaseVersionInfo' '25H2' 'sz' -Type SZ
            $lines = Get-Lines (ConvertTo-LgpoText -Policies $script:Policies)
            $lines | Should -Contain 'DWORD:255'
            $lines | Should -Contain 'SZ:25H2'
        }

        It 'puts Computer entries before User entries' {
            Add-Policy User     'Software\Policies\Test' 'U' 1 'user first'
            Add-Policy Computer 'Software\Policies\Test' 'C' 1 'computer second'
            $lines = Get-Lines (ConvertTo-LgpoText -Policies $script:Policies)
            $scopes = $lines | Where-Object { $_ -eq 'Computer' -or $_ -eq 'User' }
            $scopes | Should -Be @('Computer', 'User')
        }

        It 'renders only the surviving entry after de-duplication' {
            Add-Policy Computer 'Software\Policies\Test' 'V' 1 'old'
            Add-Policy Computer 'Software\Policies\Test' 'V' 0 'new'
            $text = ConvertTo-LgpoText -Policies $script:Policies
            $text | Should -Match 'DWORD:0'
            $text | Should -Not -Match 'DWORD:1'
            $text | Should -Not -Match '; old'
        }
    }
}
