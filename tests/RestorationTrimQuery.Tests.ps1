#requires -Version 5.1
# Native query parser only, using an isolated PowerShell script in place of fsutil.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$rqRoot=Split-Path $PSScriptRoot -Parent
$rqT=$null;$rqE=$null;$rqAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $rqRoot 'RecoveryAdapter.ps1'),[ref]$rqT,[ref]$rqE)
$rqNode=$rqAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-DiskTrimState'},$true)
. ([scriptblock]::Create($rqNode.Extent.Text))
function Get-JunoSystemTool([string]$name){throw 'TEST: native tool forbidden'}
Describe 'Consulta TRIM central: solo query, salida validada y resolvedor existente' {
    BeforeEach {
        $global:JunoRestTrimQuery=[pscustomobject]@{Output='NTFS DisableDeleteNotify = 0 (Disabled)';Exit=0;Args=@()}
        $global:JunoRestTrimScript=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.ps1')
        $fake=@'
param([string]$behavior,[string]$action,[string]$setting)
if($behavior -cne 'behavior' -or $action -cne 'query' -or $setting -cne 'DisableDeleteNotify'){throw 'TEST: unsafe or unexpected native arguments'}
$global:JunoRestTrimQuery.Args=@($behavior,$action,$setting)
$global:LASTEXITCODE=$global:JunoRestTrimQuery.Exit
$global:JunoRestTrimQuery.Output
'@
        [IO.File]::WriteAllText($global:JunoRestTrimScript,$fake,[Text.UTF8Encoding]::new($true))
        Mock Get-JunoSystemTool {param($name) if($name -cne 'fsutil.exe'){throw 'TEST: unexpected tool'};return $global:JunoRestTrimScript}
    }
    It 'interpreta estado <State> con texto adicional sin ejecutar set' -TestCases @(@{State=0},@{State=1}) {
        param($State)$global:JunoRestTrimQuery.Output="NTFS DisableDeleteNotify = $State (texto de Windows)`r`nReFS DisableDeleteNotify = 0"
        (Get-DiskTrimState).State|Should Be $State;($global:JunoRestTrimQuery.Args -join ' ')|Should Be 'behavior query DisableDeleteNotify'
        Assert-MockCalled Get-JunoSystemTool -Times 1 -Exactly -Scope It
    }
    It 'rechaza una consulta que Windows no aceptó' {
        $global:JunoRestTrimQuery.Exit=5;{Get-DiskTrimState}|Should Throw
    }
    It 'no infiere un estado de salida vacía, ReFS, ruido o valor desconocido: <Output>' -TestCases @(@{Output=''},@{Output='ReFS DisableDeleteNotify = 0'},@{Output='Error: NTFS DisableDeleteNotify = 0'},@{Output='NTFS DisableDeleteNotify = 2'},@{Output='NTFS DisableDeleteNotify = 10'}) {
        param($Output)$global:JunoRestTrimQuery.Output=$Output;{Get-DiskTrimState}|Should Throw
    }
}
