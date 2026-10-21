#requires -Version 5.1
# Pester 3.4+: importar SOLO funciones; nunca ejecutar los modulos ni la GUI.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$recoveryRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $recoveryRoot 'BackupStore.ps1')
# Identidad ficticia y cuenta no elevada: no leer SID, ACL ni MachineGuid reales.
function Get-JunoIdentity { [pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'} }
function Test-JunoAdmin { return $false }
foreach ($spec in @(
    @{ File='StartupOperations.ps1'; Names=@('Get-StartupFlag','Get-StartupBackup','Save-StartupBackup','Get-StartupApprovalSnapshot','Test-StartupApprovalSnapshot','Initialize-StartupTransaction','Sync-StartupTransaction','Write-StartupTransaction','Set-StartupState','Restore-StartupState') },
    @{ File='PermisosUsuario.ps1'; Names=@('Get-BPUBackup','Save-BPUBackup','Test-BPUValueSnapshot','Initialize-BPUTransaction','Test-BPUApplyPending','Sync-BPUTransaction','Set-BPURegistryValue','Write-BPUTransactionValue','Assert-BPUApplySupported','Disable-BPUApps','Restore-BPUApps') }
)) {
    $tokens=$null; $parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $recoveryRoot $spec.File),[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '; ') }
    foreach ($name in $spec.Names) {
        $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if ($null -eq $node) { throw "Funcion no encontrada: $name" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
# Barreras: aun sin un Mock efectivo, ninguna funcion puede abrir el Registro.
function Open-StartupRegKey([string]$hive,[string]$view,[string]$path,[bool]$write,[bool]$create) { throw 'TEST: acceso real al Registro prohibido' }
function Read-StartupRegValue([string]$hive,[string]$view,[string]$path,[string]$name) { throw 'TEST: lectura real del Registro prohibida' }
function Get-StartupSourceFingerprint($entry) { throw 'TEST: inventario real prohibido' }
function Open-BPUWriteKey([string]$family) { throw 'TEST: acceso real al Registro prohibido' }
function Get-BPUState([string]$family) { throw 'TEST: lectura real del Registro prohibida' }
function Get-BPUAccount { throw 'TEST: identidad real prohibida' }
function Test-BPULocalPolicy { throw 'TEST: directivas reales prohibidas' }
function Get-BPPPackages { throw 'TEST: inventario real prohibido' }

function Copy-RecoveryObject($value) { return ($value | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
function New-RecoveryValue([bool]$exists, $value) { return [pscustomobject]@{Exists=$exists;Value=$value} }
function Reset-RecoveryFake {
    $global:JunoRecoveryFake = [pscustomobject]@{
        Startup=[pscustomobject]@{Exists=$false;Data=$null}
        StartupDisk=[pscustomobject]@{Entries=@()}
        Bpu=@{ Test_pkg=[pscustomobject]@{Available=$true;Disabled=(New-RecoveryValue $true 0);DisabledByUser=(New-RecoveryValue $true 0);IsOff=$false} }
        BpuDisk=[pscustomobject]@{Version=1;Sid='TEST-SID';Items=@()}
        Writes=0; Saves=0; FaultWrites=@(); FaultSaves=@(); Fault='Before'; Fingerprint='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        History=@(); Targets=@(); ChangeBeforeWrite=$false
    }
    $global:JunoRecoveryEntry = [pscustomobject]@{
        Editable=$true;Id='CurrentUser|Default|Software\Microsoft\Windows\CurrentVersion\Run|ExampleStartup';Name='ExampleStartup';ApprovalHive='CurrentUser';ApprovalView='Default';ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';ApprovalValue='ExampleStartup'
        SourceType='Registro';SourceHive='CurrentUser';SourceView='Default';SourceKey='Software\Microsoft\Windows\CurrentVersion\Run';SourceValue='ExampleStartup'
    }
}
function Save-RecoveryFake([string]$module, $backup) {
    $global:JunoRecoveryFake.Saves++
    if ($global:JunoRecoveryFake.FaultSaves -contains $global:JunoRecoveryFake.Saves) { throw 'SIMULATED backup failure' }
    $copy=Copy-RecoveryObject $backup
    $global:JunoRecoveryFake.History += @($copy)
    if ($module -eq 'Startup') {
        $global:JunoRecoveryFake.StartupDisk=$copy
        if ($global:JunoRecoveryFake.ChangeBeforeWrite) {
            $global:JunoRecoveryFake.ChangeBeforeWrite=$false
            $global:JunoRecoveryFake.Startup=New-RecoveryStartupSnapshot 6
        }
    } else { $global:JunoRecoveryFake.BpuDisk=$copy }
}
function New-RecoveryStartupSnapshot([byte]$flag) {
    $bytes=New-Object byte[] 12; $bytes[0]=$flag
    return [pscustomobject]@{Exists=$true;Data=[Convert]::ToBase64String($bytes)}
}
function Invoke-RecoveryFakeWrite([string]$module,[string]$name,$target) {
    if (($module -eq 'Startup' -and $name -ne 'ExampleStartup') -or
        ($module -eq 'Bpu' -and $name -notin @('Disabled','DisabledByUser'))) { throw 'TEST: destino inesperado' }
    $global:JunoRecoveryFake.Writes++
    $global:JunoRecoveryFake.Targets += "$module/$name"
    $fault=$global:JunoRecoveryFake.FaultWrites -contains $global:JunoRecoveryFake.Writes
    if ($fault -and $global:JunoRecoveryFake.Fault -eq 'Before') { throw 'SIMULATED registry failure before write' }
    if (-not ($fault -and $global:JunoRecoveryFake.Fault -eq 'Ignore')) {
        if ($module -eq 'Startup') { $global:JunoRecoveryFake.Startup=Copy-RecoveryObject $target }
        else { $global:JunoRecoveryFake.Bpu.Test_pkg.$name=Copy-RecoveryObject $target }
    }
    if ($fault -and $global:JunoRecoveryFake.Fault -eq 'After') { throw 'SIMULATED registry failure after write' }
}
function New-RecoveryFakeKey([string]$module) {
    $key=[pscustomobject]@{Module=$module}
    $key | Add-Member ScriptMethod SetValue {
        param($name,$data,$kind)
        $target=if ($this.Module -eq 'Startup') { [pscustomobject]@{Exists=$true;Data=[Convert]::ToBase64String([byte[]]$data)} }
                else { New-RecoveryValue $true ([int]$data) }
        Invoke-RecoveryFakeWrite $this.Module $name $target
    }
    $key | Add-Member ScriptMethod DeleteValue {
        param($name,$throwIfMissing)
        $target=if ($this.Module -eq 'Startup') { [pscustomobject]@{Exists=$false;Data=$null} } else { New-RecoveryValue $false $null }
        Invoke-RecoveryFakeWrite $this.Module $name $target
    }
    $key | Add-Member ScriptMethod Close {}
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}
function ConvertTo-RecoveryLegacyStartup {
    $global:JunoRecoveryFake.StartupDisk.Entries[0].PSObject.Properties.Remove('Transaction')
}
function ConvertTo-RecoveryLegacyBpu {
    $global:JunoRecoveryFake.BpuDisk.Items[0].PSObject.Properties.Remove('Transaction')
}

Describe 'Inicio: recuperacion sin Registro real' {
    BeforeEach {
        Enter-JunoLease ('Local\Juno.Tests.Recovery.'+[Guid]::NewGuid().ToString('N'))
        Reset-RecoveryFake
        Mock Get-StartupBackup { Copy-RecoveryObject $global:JunoRecoveryFake.StartupDisk }
        Mock Save-StartupBackup { param($backup) Save-RecoveryFake 'Startup' $backup }
        Mock Get-StartupSourceFingerprint { $global:JunoRecoveryFake.Fingerprint }
        Mock Read-StartupRegValue {
            $s=$global:JunoRecoveryFake.Startup
            [pscustomobject]@{Exists=$s.Exists;Kind=$(if($s.Exists){'Binary'}else{$null});Data=$(if($s.Exists){[Convert]::FromBase64String($s.Data)}else{$null})}
        }
        Mock Open-StartupRegKey { New-RecoveryFakeKey 'Startup' }
    }
    AfterEach { Exit-JunoLease }
    It 'A: confirma bytes exactos solo despues de leer la escritura' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $record=$global:JunoRecoveryFake.StartupDisk.Entries[0]
        $record.LastWrittenData | Should Be $global:JunoRecoveryFake.Startup.Data
        ($null -eq $record.Transaction.Pending) | Should Be $true
        $global:JunoRecoveryFake.History[0].Entries[0].LastWrittenData | Should BeNullOrEmpty
        $record.OriginalExists | Should Be $false
    }
    It 'B: conserva intencion y original si no se escribio nada' {
        $global:JunoRecoveryFake.FaultWrites=@(1)
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
        $global:JunoRecoveryFake.StartupDisk.Entries[0].LastWrittenData | Should BeNullOrEmpty
        ($null -ne $global:JunoRecoveryFake.StartupDisk.Entries[0].Transaction.Pending) | Should Be $true
    }
    It 'C/D: recupera excepciones anteriores o posteriores a escribir' -TestCases @(@{Mode='Before'},@{Mode='After'}) {
        param($Mode)
        $global:JunoRecoveryFake.Fault=$Mode; $global:JunoRecoveryFake.FaultWrites=@(1)
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.StartupDisk.Entries[0].LastWrittenData | Should Be $global:JunoRecoveryFake.Startup.Data
        $expected=if($Mode -eq 'After'){1}else{2}
        $global:JunoRecoveryFake.Writes | Should Be $expected
    }
    It 'rechaza una escritura que no quedo registrada aunque SetValue no arroje error' {
        $global:JunoRecoveryFake.Fault='Ignore'; $global:JunoRecoveryFake.FaultWrites=@(1)
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        $global:JunoRecoveryFake.StartupDisk.Entries[0].LastWrittenData | Should BeNullOrEmpty
    }
    It 'recupera fallo de respaldo antes o despues de escribir' -TestCases @(@{Checkpoint=1},@{Checkpoint=2}) {
        param($Checkpoint)
        $global:JunoRecoveryFake.FaultSaves=@($Checkpoint)
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        if($Checkpoint -eq 1){$global:JunoRecoveryFake.Writes | Should Be 0}
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.StartupDisk.Entries[0].LastWrittenData | Should Be $global:JunoRecoveryFake.Startup.Data
    }
    It 'E: restaura ausencia original y conserva el archivo logico de respaldo' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
        @($global:JunoRecoveryFake.StartupDisk.Entries).Count | Should Be 0
    }
    It 'E: restaura bytes originales existentes sin reemplazar su copia al alternar' {
        $original=New-RecoveryStartupSnapshot 6
        $global:JunoRecoveryFake.Startup=$original
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        Set-StartupState $global:JunoRecoveryEntry $true | Out-Null
        $global:JunoRecoveryFake.StartupDisk.Entries[0].OriginalData | Should Be $original.Data
        Restore-StartupState | Out-Null
        $global:JunoRecoveryFake.Startup.Data | Should Be $original.Data
    }
    It 'F: restaura directamente una operacion fallida sin exigir reintento' -TestCases @(@{Mode='Before'},@{Mode='After'}) {
        param($Mode)
        $global:JunoRecoveryFake.Fault=$Mode; $global:JunoRecoveryFake.FaultWrites=@(1)
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
    }
    It 'reanuda restauracion interrumpida antes o despues del borrado' -TestCases @(@{Mode='Before'},@{Mode='After'}) {
        param($Mode)
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.Fault=$Mode; $global:JunoRecoveryFake.FaultWrites=@(2)
        Restore-StartupState | Should Match 'No restauradas'
        @($global:JunoRecoveryFake.StartupDisk.Entries).Count | Should Be 1
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
    }
    It 'G: detecta cambio externo incluso si conserva el estado logico deseado' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.Startup=New-RecoveryStartupSnapshot 7
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        Restore-StartupState | Should Match 'fuera de JUNO'
        $global:JunoRecoveryFake.Writes | Should Be 1
        @($global:JunoRecoveryFake.StartupDisk.Entries).Count | Should Be 1
    }
    It 'recupera fallo de guardado durante restauracion o al retirar el registro completado' -TestCases @(@{At=3},@{At=4},@{At=5}) {
        param($At)
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.FaultSaves=@($At)
        if($At -eq 5){ { Restore-StartupState } | Should Throw }
        else{ Restore-StartupState | Should Match 'No restauradas' }
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
        @($global:JunoRecoveryFake.StartupDisk.Entries).Count | Should Be 0
    }
    It 'G: bloquea cambio de origen y cambio entre respaldo y escritura' {
        $global:JunoRecoveryFake.ChangeBeforeWrite=$true
        { Set-StartupState $global:JunoRecoveryEntry $false } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 0
        $global:JunoRecoveryFake.Fingerprint='changed'
        Restore-StartupState | Should Match 'entrada original cambio'
    }
    It 'H: restaura un respaldo v0.8 aplicado' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        ConvertTo-RecoveryLegacyStartup
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
    }
    It 'H: reintenta un respaldo v0.8 cuya intencion nunca se escribio' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        ConvertTo-RecoveryLegacyStartup
        $global:JunoRecoveryFake.Startup=[pscustomobject]@{Exists=$false;Data=$null}
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.Startup.Exists | Should Be $true
        $global:JunoRecoveryFake.StartupDisk.Entries[0].OriginalExists | Should Be $false
    }
    It 'H: rechaza valores ajenos a original e intencion en un respaldo antiguo' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        ConvertTo-RecoveryLegacyStartup
        $global:JunoRecoveryFake.Startup=New-RecoveryStartupSnapshot 7
        Restore-StartupState | Should Match 'fuera de JUNO'
        $global:JunoRecoveryFake.Writes | Should Be 1
    }
    It 'I/J: repetir no escribe ni pierde registros no seleccionados' {
        $global:JunoRecoveryFake.StartupDisk.Entries=@([pscustomobject]@{Id='other';Note='untouched'})
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.Writes | Should Be 1
        $global:JunoRecoveryFake.StartupDisk.Entries[0].Note | Should Be 'untouched'
    }
    It 'verifica tambien la restauracion y permite reintentar si Windows no la conserva' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.Fault='Ignore'; $global:JunoRecoveryFake.FaultWrites=@(2)
        Restore-StartupState | Should Match 'No restauradas'
        Restore-StartupState | Should Match 'Restauradas: 1'
        $global:JunoRecoveryFake.Startup.Exists | Should Be $false
    }
    It 'rechaza una version de diario desconocida sin cambiar el Registro' {
        Set-StartupState $global:JunoRecoveryEntry $false | Out-Null
        $global:JunoRecoveryFake.StartupDisk.Entries[0].Transaction.Version=99
        { Set-StartupState $global:JunoRecoveryEntry $true } | Should Throw
        Restore-StartupState | Should Match 'incompatible'
        $global:JunoRecoveryFake.Writes | Should Be 1
    }
}

Describe 'Permisos de usuario: dos DWORD recuperables sin Registro real' {
    BeforeEach {
        Enter-JunoLease ('Local\Juno.Tests.Recovery.'+[Guid]::NewGuid().ToString('N'))
        Reset-RecoveryFake
        # Simular historicos de etapas 1-3 para probar su recuperacion. La entrada real
        # ahora rechaza nuevas peticiones HKCU; se verifica sin este mock en Background.Tests.
        Mock Assert-BPUApplySupported {}
        Mock Test-BPULocalPolicy { [pscustomobject]@{} }
        Mock Get-BPPPackages { [pscustomobject]@{Family='Test_pkg'} }
        Mock Get-BPUBackup { Copy-RecoveryObject $global:JunoRecoveryFake.BpuDisk }
        Mock Save-BPUBackup { param($backup) Save-RecoveryFake 'Bpu' $backup }
        Mock Get-BPUState {
            param($family)
            if($family -ne 'Test_pkg'){throw 'TEST: familia inesperada'}
            $state=Copy-RecoveryObject $global:JunoRecoveryFake.Bpu.Test_pkg
            $state.IsOff=($state.Disabled.Exists -and $state.Disabled.Value -eq 1) -or ($state.DisabledByUser.Exists -and $state.DisabledByUser.Value -eq 1)
            $state
        }
        Mock Open-BPUWriteKey { param($family) if($family -ne 'Test_pkg'){throw 'TEST: familia inesperada'}; New-RecoveryFakeKey 'Bpu' }
    }
    AfterEach { Exit-JunoLease }
    It 'A: confirma ambos DWORD individualmente y conserva originales' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        $entry=$global:JunoRecoveryFake.BpuDisk.Items[0]
        $entry.Transaction.Phase | Should Be 'Applied'
        $entry.Transaction.Disabled.Confirmed.Value | Should Be 1
        $entry.Transaction.DisabledByUser.Confirmed.Value | Should Be 1
        $entry.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.History[1].Items[0].Transaction.Disabled.Confirmed.Value | Should Be 0
        $global:JunoRecoveryFake.History[1].Items[0].Transaction.Disabled.Pending.Value | Should Be 1
    }
    It 'B: conserva originales si falla la primera escritura' {
        $global:JunoRecoveryFake.FaultWrites=@(1)
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applying'
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Disabled.Confirmed.Value | Should Be 0
    }
    It 'C: registra primer valor confirmado y segundo pendiente' {
        $global:JunoRecoveryFake.FaultWrites=@(2)
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        $entry=$global:JunoRecoveryFake.BpuDisk.Items[0]
        $entry.Transaction.Disabled.Confirmed.Value | Should Be 1
        $entry.Transaction.DisabledByUser.Confirmed.Value | Should Be 0
        $entry.Transaction.DisabledByUser.Pending.Value | Should Be 1
        Test-BPUApplyPending $entry | Should Be $true
    }
    It 'D: reintenta fallos antes o despues de cada DWORD' -TestCases @(@{At=1;Mode='Before'},@{At=2;Mode='Before'},@{At=1;Mode='After'},@{At=2;Mode='After'}) {
        param($At,$Mode)
        $global:JunoRecoveryFake.FaultWrites=@($At); $global:JunoRecoveryFake.Fault=$Mode
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applied'
        $expected=if($Mode -eq 'After'){2}else{3}
        $global:JunoRecoveryFake.Writes | Should Be $expected
    }
    It 'verifica cada DWORD aunque la API no informe error' -TestCases @(@{At=1},@{At=2}) {
        param($At)
        $global:JunoRecoveryFake.FaultWrites=@($At); $global:JunoRecoveryFake.Fault='Ignore'
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applying'
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applied'
    }
    It 'recupera fallo en cualquiera de los seis guardados de aplicacion' -TestCases @(@{At=1},@{At=2},@{At=3},@{At=4},@{At=5},@{At=6}) {
        param($At)
        $global:JunoRecoveryFake.FaultSaves=@($At)
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        if($At -le 2){$global:JunoRecoveryFake.Writes | Should Be 0}
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applied'
    }
    It 'E: restaura originales existentes o ausentes' -TestCases @(@{Exists=$true},@{Exists=$false}) {
        param($Exists)
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled=New-RecoveryValue $Exists $(if($Exists){0}else{$null})
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser=New-RecoveryValue $Exists $(if($Exists){0}else{$null})
        Disable-BPUApps @('Test_pkg') | Out-Null
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Exists | Should Be $Exists
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Exists | Should Be $Exists
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 0
    }
    It 'F: restaura directamente cualquiera de los cuatro fallos parciales' -TestCases @(@{At=1;Mode='Before'},@{At=2;Mode='Before'},@{At=1;Mode='After'},@{At=2;Mode='After'}) {
        param($At,$Mode)
        $global:JunoRecoveryFake.FaultWrites=@($At); $global:JunoRecoveryFake.Fault=$Mode
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value | Should Be 0
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 0
    }
    It 'reanuda fallos de restauracion antes o despues de cada DWORD' -TestCases @(@{At=3;Mode='Before'},@{At=4;Mode='Before'},@{At=3;Mode='After'},@{At=4;Mode='After'}) {
        param($At,$Mode)
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.FaultWrites=@($At); $global:JunoRecoveryFake.Fault=$Mode
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Restoring'
        Test-BPUApplyPending $global:JunoRecoveryFake.BpuDisk.Items[0] | Should Be $false
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value | Should Be 0
    }
    It 'recupera fallo en cada guardado de restauracion' -TestCases @(@{At=7},@{At=8},@{At=9},@{At=10},@{At=11},@{At=12}) {
        param($At)
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.FaultSaves=@($At)
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value | Should Be 0
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 0
    }
    It 'G: no pisa cambios externos despues de exito o aplicacion parcial' -TestCases @(@{Partial=$false},@{Partial=$true}) {
        param($Partial)
        if($Partial){$global:JunoRecoveryFake.FaultWrites=@(2); { Disable-BPUApps @('Test_pkg') } | Should Throw}
        else{Disable-BPUApps @('Test_pkg') | Out-Null}
        $writes=$global:JunoRecoveryFake.Writes
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser=New-RecoveryValue $true 2
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be $writes
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 1
    }
    It 'H: recupera respaldos antiguos con cero, uno o dos DWORD aplicados' -TestCases @(@{One=0;Two=0},@{One=1;Two=0},@{One=0;Two=1},@{One=1;Two=1}) {
        param($One,$Two)
        Disable-BPUApps @('Test_pkg') | Out-Null
        ConvertTo-RecoveryLegacyBpu
        Test-BPUApplyPending $global:JunoRecoveryFake.BpuDisk.Items[0] | Should Be $true
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value=$One
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value=$Two
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value | Should Be 0
    }
    It 'H: reintenta aplicacion parcial de un respaldo antiguo' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        ConvertTo-RecoveryLegacyBpu
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value=0
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Applied'
        $global:JunoRecoveryFake.BpuDisk.Items[0].DisabledByUser.Value | Should Be 0
    }
    It 'I/J: repetir o restaurar otra familia no escribe ni cambia respaldos ajenos' {
        $global:JunoRecoveryFake.BpuDisk.Items=@([pscustomobject]@{Family='Other_pkg';Note='untouched'})
        Disable-BPUApps @('Test_pkg') | Out-Null
        Disable-BPUApps @('Test_pkg') | Out-Null
        Restore-BPUApps @('Unselected_pkg') | Out-Null
        $global:JunoRecoveryFake.Writes | Should Be 2
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Note | Should Be 'untouched'
    }
    It 'J: no se apropia de indicadores de bloqueo preexistentes' {
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value=1
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Writes | Should Be 0
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 0
    }
    It 'J: rechaza paquetes no permitidos y nombres de valor fuera del modulo' {
        { Disable-BPUApps @('Unknown_pkg') } | Should Throw
        { Set-BPURegistryValue 'Test_pkg' 'OtherValue' (New-RecoveryValue $true 1) } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 0
        Assert-MockCalled Open-BPUWriteKey -Times 0 -Exactly -Scope It
    }
    It 'no escribe ni descarta respaldo cuando desaparece la clave' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Available=$false
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 2
        @($global:JunoRecoveryFake.BpuDisk.Items).Count | Should Be 1
    }
    It 'verifica cada restauracion aunque la API no informe error' -TestCases @(@{At=3},@{At=4}) {
        param($At)
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Fault='Ignore'; $global:JunoRecoveryFake.FaultWrites=@($At)
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Phase | Should Be 'Restoring'
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value | Should Be 0
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Value | Should Be 0
    }
    It 'detecta reversion externa al original despues de confirmar la aplicacion' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value=0
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 2
    }
    It 'rechaza valores ajenos al original y al destino de un respaldo antiguo' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        ConvertTo-RecoveryLegacyBpu
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Value=2
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 2
    }
    It 'conserva originales ausentes al recuperar un respaldo antiguo parcial' {
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled=New-RecoveryValue $false $null
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser=New-RecoveryValue $false $null
        Disable-BPUApps @('Test_pkg') | Out-Null
        ConvertTo-RecoveryLegacyBpu
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser=New-RecoveryValue $false $null
        Restore-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.Bpu.Test_pkg.Disabled.Exists | Should Be $false
        $global:JunoRecoveryFake.Bpu.Test_pkg.DisabledByUser.Exists | Should Be $false
    }
    It 'rechaza una version de diario desconocida sin nuevas escrituras' {
        Disable-BPUApps @('Test_pkg') | Out-Null
        $global:JunoRecoveryFake.BpuDisk.Items[0].Transaction.Version=99
        { Disable-BPUApps @('Test_pkg') } | Should Throw
        { Restore-BPUApps @('Test_pkg') } | Should Throw
        $global:JunoRecoveryFake.Writes | Should Be 2
    }
}

Describe 'Lectura y escritura real de JSON solo dentro de TestDrive' {
    BeforeEach {
        Enter-JunoLease ('Local\Juno.Tests.Recovery.'+[Guid]::NewGuid().ToString('N'))
        $script:AppFolder=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:StartupBackupPath=Join-Path $script:AppFolder 'inicio-backup.json'
        $script:BPUBackupPath=Join-Path $script:AppFolder 'background-user.json'
        Mock Get-BPUAccount { 'TEST-SID' }
        Reset-RecoveryFake
    }
    AfterEach { Exit-JunoLease }
    It 'reconoce archivos antiguos y conserva sus campos originales al agregar el diario' {
        $r=Copy-RecoveryObject $global:JunoRecoveryEntry
        $r.PSObject.Properties.Remove('Editable')
        foreach($p in @{Fingerprint=$global:JunoRecoveryFake.Fingerprint;OriginalExists=$false;OriginalData=$null;LastWrittenData=$null}.GetEnumerator()) { Add-Member -InputObject $r NoteProperty $p.Key $p.Value }
        $startup=[pscustomobject]@{Entries=@($r)}
        Save-StartupBackup $startup
        $loaded=Get-StartupBackup
        Initialize-StartupTransaction $loaded.Entries[0]
        Save-StartupBackup $loaded
        $again=Get-StartupBackup
        $again.Entries[0].Name | Should Be 'ExampleStartup'
        $again.Entries[0].Transaction.Version | Should Be 1
        Test-Path -LiteralPath $script:StartupBackupPath | Should Be $true
        $bpu=[pscustomobject]@{Version=1;Sid='TEST-SID';Items=@([pscustomobject]@{Family='Test_pkg';Disabled=(New-RecoveryValue $false $null);DisabledByUser=(New-RecoveryValue $true 0)})}
        Save-BPUBackup $bpu
        $loaded=Get-BPUBackup
        Initialize-BPUTransaction $loaded.Items[0]
        Save-BPUBackup $loaded
        $again=Get-BPUBackup
        $again.Version | Should Be 1
        $again.Items[0].Disabled.Exists | Should Be $false
        $again.Items[0].Transaction.Version | Should Be 1
        Test-Path -LiteralPath $script:BPUBackupPath | Should Be $true
    }
    It 'rechaza respaldo de otro usuario sin reemplazarlo' {
        [void][IO.Directory]::CreateDirectory($script:AppFolder)
        [IO.File]::WriteAllText($script:BPUBackupPath, '{"Version":1,"Sid":"OTHER-SID","Items":[]}',[Text.Encoding]::UTF8)
        $before=Get-Content -LiteralPath $script:BPUBackupPath -Raw
        { Get-BPUBackup } | Should Throw
        (Get-Content -LiteralPath $script:BPUBackupPath -Raw) | Should Be $before
    }
    It 'conserva un JSON danado y detiene su lectura' {
        [void](New-Item -ItemType Directory -Path $script:AppFolder -Force)
        Set-Content -LiteralPath $script:BPUBackupPath -Value '{invalid' -Encoding UTF8
        $before=Get-Content -LiteralPath $script:BPUBackupPath -Raw
        { Get-BPUBackup } | Should Throw
        (Get-Content -LiteralPath $script:BPUBackupPath -Raw) | Should Be $before
    }
}
