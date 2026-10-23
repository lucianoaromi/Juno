#requires -Version 5.1
# Reuse only the isolated fixture definitions and frontier mocks, never run its test cases.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$bgFixtureSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Background.Tests.ps1'))
$bgPrelude=$bgFixtureSource.Substring(0,$bgFixtureSource.IndexOf('Describe ')).Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
. ([scriptblock]::Create($bgPrelude))
. (Join-Path $backgroundRoot 'RecoveryAdapter.ps1')
$isolatedBgLease=(Get-Command Enter-JunoLease).ScriptBlock.ToString().Replace('Global\JUNO.0.8.State',('Local\Juno.Tests.Restoration.Background.'+[Guid]::NewGuid().ToString('N')))
. ([scriptblock]::Create('function Enter-JunoLease {'+$isolatedBgLease+'}'))
$bgTokens=$null;$bgErrors=$null;$bgAst=[Management.Automation.Language.Parser]::ParseInput($bgFixtureSource,[ref]$bgTokens,[ref]$bgErrors)
$bgSetup=$bgAst.Find({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'BeforeEach'},$true).CommandElements[1].ScriptBlock.Extent.Text
$bgSetup=[scriptblock]::Create($bgSetup.Substring(1,$bgSetup.Length-2))
Describe 'Restauración central con motores históricos de segundo plano reales y Windows simulado' {
    BeforeEach {
        . $bgSetup
        $global:JunoRestBackgroundPath=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.json')
        [IO.File]::WriteAllText($global:JunoRestBackgroundPath,'fixture')
        Mock Get-JunoStorePath {$global:JunoRestBackgroundPath}
        Mock Test-JunoRecoveryUserProvenance {$true} # storage is already a validated, identity-bound in-memory frontier in this fixture
    }
    AfterEach {Exit-JunoLease}
    It 'recupera los dos valores HKCU históricos sin solicitar restricciones nuevas' {
        $entry=New-BackgroundUserRecord;$before=Read-JunoRecoveryItem BackgroundUser $false
        $before.CanRestore|Should Be $true;Exit-JunoLease
        $r=Invoke-JunoRecoveryRequest Restore -Id BackgroundUser -Token $before.Token -Confirmed
        $r.Outcome|Should Be Restored;$global:JunoBackgroundFake.User.Items.Count|Should Be 0
        $global:JunoBackgroundFake.UserStates[$entry.Family].Disabled.Value|Should Be 0
        $global:JunoBackgroundFake.UserStates[$entry.Family].DisabledByUser.Exists|Should Be $true
        $global:JunoBackgroundFake.Writes|Should Be 2
        @($global:JunoBackgroundFake.History|Where-Object Kind -ne BPU).Count|Should Be 0
    }
    It 'un fallo parcial conserva originales y el diario para reintentar' {
        $entry=New-BackgroundUserRecord;$token=(Read-JunoRecoveryItem BackgroundUser $false).Token
        $global:JunoBackgroundFake.FaultWrites=@(2);Exit-JunoLease
        $r=Invoke-JunoRecoveryRequest Restore -Id BackgroundUser -Token $token -Confirmed
        $r.Outcome|Should Be Failed;$global:JunoBackgroundFake.User.Items.Count|Should Be 1
        $global:JunoBackgroundFake.User.Items[0].Disabled.Value|Should Be 0
        $global:JunoBackgroundFake.User.Items[0].DisabledByUser.Value|Should Be 0
        $global:JunoBackgroundFake.FaultWrites=@();$view=Invoke-JunoRecoveryRequest Read
        $token=@($view.Items|Where-Object Id -eq BackgroundUser)[0].Token
        (Invoke-JunoRecoveryRequest Restore -Id BackgroundUser -Token $token -Confirmed).Outcome|Should Be Restored
    }
    It 'un cambio externo del usuario impide recuperar y preserva la copia' {
        $entry=New-BackgroundUserRecord;$global:JunoBackgroundFake.UserStates[$entry.Family].Disabled.Value=4
        $before=$global:JunoBackgroundFake.User|ConvertTo-Json -Depth 24 -Compress
        (Read-JunoRecoveryItem BackgroundUser $false).CanRestore|Should Be $false
        ($global:JunoBackgroundFake.User|ConvertTo-Json -Depth 24 -Compress)|Should Be $before;$global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'recupera una directiva propia con diario y verifica originales y guardas' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $global:JunoBackgroundFake.Writes=0;$item=Read-JunoRecoveryItem BackgroundPolicy $true;$item.CanRestore|Should Be $true;$token=$item.Token;$token|Should Not BeNullOrEmpty
        Exit-JunoLease;$r=Invoke-JunoRecoveryRequest Restore -Id BackgroundPolicy -Token $token -Confirmed
        $r.Outcome|Should Be Restored;$global:JunoBackgroundFake.Policy.Owned.Count|Should Be 0
        $global:JunoBackgroundFake.PolicyState.Deny.Exists|Should Be $false;$global:JunoBackgroundFake.PolicyState.Global.Exists|Should Be $false
        $global:JunoBackgroundFake.Policy.Transaction.Phase|Should Be Restored
        @($global:JunoBackgroundFake.History|Where-Object Kind -ne Policy).Count|Should Be 0
    }
    It 'directiva histórica sin diario permanece supervisada y sin escritura' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;$global:JunoBackgroundFake.Policy.PSObject.Properties.Remove('Transaction');$global:JunoBackgroundFake.Writes=0
        (Read-JunoRecoveryItem BackgroundPolicy $true).CanRestore|Should Be $false;$global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'consulta y revalidación no debilitan las nuevas restricciones HKCU bloqueadas' {
        $null=New-BackgroundUserRecord;$null=Read-JunoRecoveryItem BackgroundUser $false
        {Disable-BPUApps @('Contoso.Chat_testpub')}|Should Throw;$global:JunoBackgroundFake.Writes|Should Be 0
    }
}
