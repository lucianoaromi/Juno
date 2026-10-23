#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$restorationRoot=Split-Path $PSScriptRoot -Parent
$script:AppFolder=$env:TEMP
foreach($file in @('BackupStore.ps1','RecoveryOperations.ps1','StartupOperations.ps1','PermisosUsuario.ps1','RecoveryAdapter.ps1')){
    . (Join-Path $restorationRoot $file)
}
. (Join-Path $PSScriptRoot 'Restoration.Fake.ps1')
$isolatedLease=(Get-Command Enter-JunoLease).ScriptBlock.ToString().Replace('Global\JUNO.0.8.State',('Local\Juno.Tests.Restoration.Request.'+[Guid]::NewGuid().ToString('N')))
. ([scriptblock]::Create('function Enter-JunoLease {'+$isolatedLease+'}'))
Describe 'Restauración central: preflight, alcance y verificación sin Windows real' {
    BeforeEach {Reset-RestorationFake;Enter-JunoLease ('Local\Juno.Tests.Restoration.'+[Guid]::NewGuid().ToString('N'))}
    AfterEach {Exit-JunoLease}
    It 'consultar sin respaldos no crea datos ni ofrece acciones' {
        $r=Get-JunoRecoveryView;$r.Items.Count|Should Be 6;@($r.Items|Where-Object CanRestore).Count|Should Be 0
        $r.Outcome|Should Be Read;$global:JunoRestFake.Writes|Should Be 0;$global:JunoRestFake.History.Count|Should Be 0
    }
    It 'respaldo válido de <Kind> permite solo su recuperación' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Startup'},@{Kind='BackgroundUser'},@{Kind='BackgroundPolicy'},@{Kind='Trim'}) {
        param($Kind)Add-RestorationBackup $Kind;$r=Read-JunoRecoveryItem $Kind $true
        $r.State|Should Be Ready;$r.CanRestore|Should Be $true;$r.Token|Should Not BeNullOrEmpty;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'restaurar <Kind> verifica el original y conserva el histórico' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Startup'},@{Kind='BackgroundUser'},@{Kind='BackgroundPolicy'},@{Kind='Trim'}) {
        param($Kind)Add-RestorationBackup $Kind;$history=$global:JunoRestFake.History -join '|';$before=Read-JunoRecoveryItem $Kind $true
        # Release outer fixture lease: the request owns its production lease.
        Exit-JunoLease;$r=Invoke-JunoRecoveryRequest Restore -Id $Kind -Token $before.Token -Confirmed
        $r.Outcome|Should Be Restored;$r.Attempted|Should Be $Kind;$global:JunoRestFake.Writes|Should Be 1
        ($global:JunoRestFake.Calls -join ',')|Should Be $Kind;($global:JunoRestFake.History -join '|')|Should Be $history
        @($r.Items|Where-Object{$_.Id -eq $Kind})[0].State|Should Be Empty
    }
    It 'un archivo inválido de <Kind> bloquea esa categoría y deja consultar otras' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Startup'},@{Kind='BackgroundUser'},@{Kind='BackgroundPolicy'},@{Kind='Trim'}) {
        param($Kind)$global:JunoRestFake.Invalid=$Kind;$r=Get-JunoRecoveryView
        @($r.Items|Where-Object{$_.Id -eq $Kind})[0].State|Should Be Error;$r.Outcome|Should Be Partial;$r.Items.Count|Should Be 6;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'un conflicto de <Kind> no ofrece restauración ni altera el historial' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Startup'},@{Kind='BackgroundUser'},@{Kind='BackgroundPolicy'},@{Kind='Trim'}) {
        param($Kind)Add-RestorationBackup $Kind;$history=$global:JunoRestFake.History -join '|';$global:JunoRestFake.Allowed=$false
        if($Kind -eq 'Trim'){$global:JunoRestFake.CurrentTrim=1}
        $r=Read-JunoRecoveryItem $Kind $true;$r.CanRestore|Should Be $false;$global:JunoRestFake.Writes|Should Be 0;($global:JunoRestFake.History -join '|')|Should Be $history
    }
    It 'sin elevación no consulta ni ofrece restauraciones de equipo' {
        $global:JunoRestFake.Admin=$false;$global:JunoRestFake.Invalid='Power';$r=Get-JunoRecoveryView
        $r.MachineChecked|Should Be $false;@($r.Items|Where-Object{$_.Id -in @('Power','BackgroundPolicy','Trim') -and $_.State -ne 'Empty'}).Count|Should Be 0
    }
    It 'rechaza histórico sin atribución de <Kind> y nunca importa al consultar' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Trim'},@{Kind='BackgroundPolicy'}) {
        param($Kind)Add-RestorationBackup $Kind;$global:JunoRestFake.Legacy=$Kind
        if($Kind -in @('Trim','BackgroundPolicy')){$field=if($Kind -eq 'Trim'){'Trim'}else{'Policy'};$global:JunoRestFake.$field.PSObject.Properties.Remove('Transaction')}
        (Read-JunoRecoveryItem $Kind $true).CanRestore|Should Be $false;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'un fallo de consulta no se presenta como restauración disponible' {
        Add-RestorationBackup Transparency;$global:JunoRestFake.ViewFailure='Transparency';(Read-JunoRecoveryItem Transparency $true).State|Should Be Error
    }
    It 'sin confirmación no adquiere exclusión ni escribe' {
        Exit-JunoLease
        (Invoke-JunoRecoveryRequest Restore -Id Power -Token TOKEN).Outcome|Should Be Cancelled
        $script:JunoLease|Should BeNullOrEmpty;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'un token cambiado impide escribir' {
        Add-RestorationBackup Transparency;$token=(Read-JunoRecoveryItem Transparency $true).Token;$global:JunoRestFake.General.TransparencyBackup.Value='0';Exit-JunoLease
        (Invoke-JunoRecoveryRequest Restore -Id Transparency -Token $token -Confirmed).Outcome|Should Be Conflict;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'no permite recuperar una categoría sin respaldo' {
        Exit-JunoLease;(Invoke-JunoRecoveryRequest Restore -Id Power -Token TOKEN -Confirmed).Outcome|Should Be Blocked;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'rechaza módulos nuevos, aplicar y efectos visuales' {
        {Invoke-JunoRecoveryRequest Restore -Id Visual -Confirmed}|Should Throw
        {Invoke-JunoRecoveryRequest Apply -Id Power -Confirmed}|Should Throw;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'un no-op, borrado de metadatos o resultado parcial nunca informa éxito: <Mode>' -TestCases @(@{Mode='NoOp'},@{Mode='ClearOnly'},@{Mode='Partial'}) {
        param($Mode)Add-RestorationBackup Transparency;$token=(Read-JunoRecoveryItem Transparency $true).Token;$global:JunoRestFake.Mode=$Mode;Exit-JunoLease
        (Invoke-JunoRecoveryRequest Restore -Id Transparency -Token $token -Confirmed).Outcome|Should Be Partial
    }
    It 'un fallo deja el respaldo y permite volver a consultar' {
        Add-RestorationBackup Power;$token=(Read-JunoRecoveryItem Power $true).Token;$global:JunoRestFake.Mode='Fail';Exit-JunoLease
        $r=Invoke-JunoRecoveryRequest Restore -Id Power -Token $token -Confirmed;$r.Outcome|Should Be Failed;$r.Attempted|Should Be Power
        (Invoke-JunoRecoveryRequest Read).Outcome|Should Be Read;$global:JunoRestFake.Power.PowerScheme|Should Not BeNullOrEmpty
    }
    It 'recuperar una categoría no toca las otras cinco' {
        foreach($kind in @('Power','Transparency','Startup','BackgroundUser','BackgroundPolicy','Trim')){Add-RestorationBackup $kind}
        $r=Get-JunoRecoveryView;$token=@($r.Items|Where-Object Id -eq Transparency)[0].Token;Exit-JunoLease
        $after=Invoke-JunoRecoveryRequest Restore -Id Transparency -Token $token -Confirmed
        $after.Outcome|Should Be Restored;@($after.Items|Where-Object CanRestore).Count|Should Be 5;($global:JunoRestFake.Calls -join ',')|Should Be Transparency
    }
    It 'el token representa el contenido completo, no solo su nombre' {
        (Get-JunoRecoveryToken ([pscustomobject]@{Value=1}))|Should Not Be (Get-JunoRecoveryToken ([pscustomobject]@{Value=2}))
    }
    It 'un fallo de lectura de inicio no atribuye falsamente cambios externos' {
        Add-RestorationBackup Startup;Mock Read-StartupRegValue {throw [UnauthorizedAccessException]::new('SIMULATED denied')}
        $r=Read-JunoRecoveryItem Startup $true;$r.State|Should Be Blocked;$r.CanRestore|Should Be $false;$global:JunoRestFake.Writes|Should Be 0
    }
    It 'un histórico de <Kind> sin equipo verificable queda supervisado y no se migra' -TestCases @(@{Kind='Startup'},@{Kind='BackgroundUser'}) {
        param($Kind)Add-RestorationBackup $Kind;$global:JunoRestFake.Legacy='UnverifiableUser'
        $r=Read-JunoRecoveryItem $Kind $true;$r.State|Should Be Blocked;$r.CanRestore|Should Be $false;$global:JunoRestFake.Writes|Should Be 0
    }
}
