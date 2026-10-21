#requires -Version 5.1
# Datos ficticios y fronteras cerradas: nunca se modifica el Registro ni se notifica al escritorio.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$transRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledTransparency' -as [type])){
    if('Juno.Preview.ShellForm' -as [type]){throw 'Ejecuta la suite en un proceso nuevo.'}
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\PowerModel.cs','ui\PowerPlatform.cs','ui\PowerShellPowerService.cs','ui\JunoShell.cs','tests\Dashboard.TestSupport.cs','tests\Transparency.TestSupport.cs','tests\Power.TestSupport.cs')|ForEach-Object{Join-Path $transRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $transRoot 'BackupStore.ps1')
. (Join-Path $transRoot 'RecoveryOperations.ps1')
. (Join-Path $transRoot 'TransparencyOperations.ps1')
. (Join-Path $transRoot 'TransparencyAdapter.ps1')
# Barreras también fuera de los Mock: fallar cerrado si un aislamiento se pierde.
function Get-TransparencySnapshot {throw 'TEST: Registro real prohibido'}
function Set-JunoTransparencySnapshot($target) {throw 'TEST: Registro real prohibido'}
function Notify-TransparencyChange {throw 'TEST: notificación real prohibida'}
function Get-Backup {throw 'TEST: respaldo real prohibido'}
function Save-Backup($backup) {throw 'TEST: respaldo real prohibido'}
function Confirm-JunoReview([string]$message) {throw 'TEST: diálogo real prohibido'}
function Copy-TransFake($value){return ($value|ConvertTo-Json -Depth 24|ConvertFrom-Json)}
function New-TransSnapshot([bool]$exists=$true,[string]$value='1'){if($exists){return [pscustomobject]@{Exists=$true;Kind='DWord';Value=$value}};return [pscustomobject]@{Exists=$false;Kind=$null;Value=$null}}
function Reset-TransFake {
    $global:JunoTransFake=[pscustomobject]@{
        Snapshot=(New-TransSnapshot)
        Backup=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=$null;Journal=[pscustomobject]@{Version=1;Visual=$null;Transparency=$null}}
        Writes=0;Saves=0;Reads=0;Enters=0;Exits=0;FailSaves=@();WriteFault='';ChangeOnSave=$false
    }
}
Describe 'Adaptación de transparencia sobre el motor estable y diarios ficticios' {
    BeforeEach {
        Reset-TransFake
        Mock Enter-JunoLease {$global:JunoTransFake.Enters++;$script:JunoLease=[pscustomobject]@{Abandoned=$false}}
        Mock Assert-JunoLease {}
        Mock Exit-JunoLease {$global:JunoTransFake.Exits++;$script:JunoLease=$null}
        Mock Get-TransparencySnapshot {$global:JunoTransFake.Reads++;Copy-TransFake $global:JunoTransFake.Snapshot}
        Mock Get-Backup {Copy-TransFake $global:JunoTransFake.Backup}
        Mock Save-Backup {
            param($backup)
            $global:JunoTransFake.Saves++
            if($global:JunoTransFake.FailSaves -contains $global:JunoTransFake.Saves){throw 'SIMULATED save failure'}
            $global:JunoTransFake.Backup=Copy-TransFake $backup
            if($global:JunoTransFake.ChangeOnSave){$global:JunoTransFake.ChangeOnSave=$false;$global:JunoTransFake.Snapshot=New-TransSnapshot $true '2'}
        }
        Mock Set-JunoTransparencySnapshot {
            param($target)
            $global:JunoTransFake.Writes++
            if($global:JunoTransFake.WriteFault -eq 'Before'){throw 'SIMULATED before write'}
            if($global:JunoTransFake.WriteFault -ne 'NoEffect'){$global:JunoTransFake.Snapshot=Copy-TransFake $target}
            if($global:JunoTransFake.WriteFault -eq 'After'){throw 'SIMULATED after write'}
        }
        Mock Notify-TransparencyChange {$false}
        Mock Confirm-JunoReview {}
    }
    It 'lee <Value> sin escribir configuración ni respaldos' -TestCases @(@{Value='1';Expected='Enabled'},@{Value='0';Expected='Disabled'},@{Value='2';Expected='Unknown'}) {
        param($Value,$Expected)
        $global:JunoTransFake.Snapshot=New-TransSnapshot $true $Value
        $r=Invoke-JunoTransparencyRequest Read
        $r.State|Should Be $Expected;$r.CanChange|Should Be $true
        $global:JunoTransFake.Writes|Should Be 0;$global:JunoTransFake.Saves|Should Be 0
        $global:JunoTransFake.Enters|Should Be 1;$global:JunoTransFake.Exits|Should Be 1
    }
    It 'la ausencia no se interpreta como activada o desactivada' {
        $global:JunoTransFake.Snapshot=New-TransSnapshot $false
        (Invoke-JunoTransparencyRequest Read).State|Should Be 'Unknown'
        $global:JunoTransFake.Saves|Should Be 0
    }
    It 'un tipo incompatible bloquea las escrituras sin convertirlo silenciosamente' {
        $global:JunoTransFake.Snapshot.Kind='String'
        $r=Invoke-JunoTransparencyRequest Read;$r.State|Should Be 'Unknown';$r.CanChange|Should Be $false
        (Invoke-JunoTransparencyRequest Disable -Confirmed).Outcome|Should Be 'Failed'
        $global:JunoTransFake.Writes|Should Be 0;$global:JunoTransFake.Saves|Should Be 0
    }
    It 'expresa error de lectura sin éxito ni controles de cambio' {
        Mock Get-TransparencySnapshot {throw 'SIMULATED denied'}
        $r=Invoke-JunoTransparencyRequest Read;$r.State|Should Be 'Unavailable';$r.Outcome|Should Be 'Failed';$r.CanChange|Should Be $false
        $global:JunoTransFake.Writes|Should Be 0
    }
    It 'rechaza respaldo ilegible antes de intentar modificar Windows' {
        Mock Get-Backup {throw 'SIMULATED corrupt backup'}
        $r=Invoke-JunoTransparencyRequest Disable -Confirmed;$r.Outcome|Should Be 'Failed';$r.Message|Should Match 'respaldo'
        $global:JunoTransFake.Writes|Should Be 0
    }
    It 'la cancelación inicial no adquiere mutex ni consulta ni escribe' {
        $r=Invoke-JunoTransparencyRequest Disable
        $r.Outcome|Should Be 'Cancelled';$global:JunoTransFake.Enters|Should Be 0;$global:JunoTransFake.Reads|Should Be 0
        $global:JunoTransFake.Writes|Should Be 0;$global:JunoTransFake.Saves|Should Be 0
    }
    It 'aplica <Action> conservando el original y verificando el Registro simulado' -TestCases @(@{Action='Enable';Initial='0';Target='1'},@{Action='Disable';Initial='1';Target='0'}) {
        param($Action,$Initial,$Target)
        $global:JunoTransFake.Snapshot=New-TransSnapshot $true $Initial
        $r=Invoke-JunoTransparencyRequest $Action -Confirmed
        $r.Outcome|Should Be 'Applied';$r.Message|Should Match 'Escritura confirmada';$r.Message|Should Match 'visual'
        $global:JunoTransFake.Snapshot.Value|Should Be $Target
        $global:JunoTransFake.Backup.TransparencyBackup.Value|Should Be $Initial
        $global:JunoTransFake.Backup.Journal.Transparency.Pending|Should BeNullOrEmpty
        $global:JunoTransFake.Exits|Should Be 1
    }
    It 'mantiene el primer original al aplicar otra vez' {
        Invoke-JunoTransparencyRequest Disable -Confirmed|Out-Null
        Invoke-JunoTransparencyRequest Enable -Confirmed|Out-Null
        $global:JunoTransFake.Backup.TransparencyBackup.Value|Should Be '1'
    }
    It 'restaura la ausencia original sin inventar un DWORD' {
        $global:JunoTransFake.Snapshot=New-TransSnapshot $false
        Invoke-JunoTransparencyRequest Enable -Confirmed|Out-Null
        $global:JunoTransFake.Backup.TransparencyBackup.Exists|Should Be $false
        (Invoke-JunoTransparencyRequest Restore -Confirmed).Outcome|Should Be 'Restored'
        $global:JunoTransFake.Snapshot.Exists|Should Be $false
        $global:JunoTransFake.Backup.TransparencyBackup|Should BeNullOrEmpty
    }
    It 'conserva intención ante escritura <Fault> y permite reconciliar/restaurar' -TestCases @(@{Fault='Before'},@{Fault='After'},@{Fault='NoEffect'}) {
        param($Fault)
        $global:JunoTransFake.WriteFault=$Fault
        $r=Invoke-JunoTransparencyRequest Disable -Confirmed
        $r.Outcome|Should Be 'Failed';$r.Pending|Should Be $true
        $global:JunoTransFake.Backup.Journal.Transparency.Pending.Value|Should Be '0'
        $global:JunoTransFake.WriteFault=''
        (Invoke-JunoTransparencyRequest Restore -Confirmed).Outcome|Should Be 'Restored'
        $global:JunoTransFake.Snapshot.Value|Should Be '1'
    }
    It 'no escribe si no puede persistir la intención' {
        $global:JunoTransFake.FailSaves=@(1)
        (Invoke-JunoTransparencyRequest Disable -Confirmed).Outcome|Should Be 'Failed'
        $global:JunoTransFake.Writes|Should Be 0
    }
    It 'una lectura fallida después de escribir informa resultado desconocido y pendiente' {
        Mock Get-TransparencySnapshot {if($global:JunoTransFake.Writes -gt 0){throw 'SIMULATED readback failure'};Copy-TransFake $global:JunoTransFake.Snapshot}
        $r=Invoke-JunoTransparencyRequest Disable -Confirmed
        $r.Outcome|Should Be 'Failed';$r.State|Should Be 'Unavailable';$r.Pending|Should Be $true
        $global:JunoTransFake.Backup.Journal.Transparency.Pending.Value|Should Be '0'
    }
    It 'reconcilia escritura completada con fallo al guardar confirmación' {
        $global:JunoTransFake.FailSaves=@(2)
        $r=Invoke-JunoTransparencyRequest Disable -Confirmed
        $r.Outcome|Should Be 'Failed';$r.Pending|Should Be $true;$global:JunoTransFake.Snapshot.Value|Should Be '0'
        $global:JunoTransFake.FailSaves=@()
        (Invoke-JunoTransparencyRequest Restore -Confirmed).Outcome|Should Be 'Restored'
    }
    It 'la consulta de un pendiente no altera ni completa su diario' {
        $global:JunoTransFake.WriteFault='After';Invoke-JunoTransparencyRequest Disable -Confirmed|Out-Null
        $before=$global:JunoTransFake.Backup|ConvertTo-Json -Depth 24 -Compress;$saves=$global:JunoTransFake.Saves
        (Invoke-JunoTransparencyRequest Read).Pending|Should Be $true
        ($global:JunoTransFake.Backup|ConvertTo-Json -Depth 24 -Compress)|Should Be $before
        $global:JunoTransFake.Saves|Should Be $saves
    }
    It 'una restauración parcial impide aplicar y se puede completar' {
        Invoke-JunoTransparencyRequest Disable -Confirmed|Out-Null
        $global:JunoTransFake.WriteFault='After'
        $r=Invoke-JunoTransparencyRequest Restore -Confirmed
        $r.Outcome|Should Be 'Failed';$r.Pending|Should Be $true;$r.CanChange|Should Be $false;$r.CanRestore|Should Be $true
        $writes=$global:JunoTransFake.Writes
        (Invoke-JunoTransparencyRequest Enable -Confirmed).Outcome|Should Be 'Failed'
        $global:JunoTransFake.Writes|Should Be $writes
        $global:JunoTransFake.WriteFault=''
        (Invoke-JunoTransparencyRequest Restore -Confirmed).Outcome|Should Be 'Restored'
    }
    It 'detecta cambios externos <When> sin sobrescribirlos' -TestCases @(@{When='after'},@{When='before-write'}) {
        param($When)
        if($When -eq 'after'){
            Invoke-JunoTransparencyRequest Disable -Confirmed|Out-Null
            $global:JunoTransFake.Snapshot=New-TransSnapshot $true '2'
            $writes=$global:JunoTransFake.Writes
            $r=Invoke-JunoTransparencyRequest Restore -Confirmed
        } else {
            $global:JunoTransFake.ChangeOnSave=$true;$writes=0
            $r=Invoke-JunoTransparencyRequest Disable -Confirmed
        }
        $r.Outcome|Should Be 'Conflict';$global:JunoTransFake.Writes|Should Be $writes
        $global:JunoTransFake.Backup.TransparencyBackup.Value|Should Be '1'
    }
    It 'un histórico requiere revisión explícita antes de restaurar' {
        $global:JunoTransFake.Backup.TransparencyBackup=New-TransSnapshot $false
        $r=Invoke-JunoTransparencyRequest Read;$r.Historical|Should Be $true
        $r=Invoke-JunoTransparencyRequest Restore -Confirmed;$r.Outcome|Should Be 'Restored'
        Assert-MockCalled Confirm-JunoReview -Times 1 -Exactly -Scope It
    }
    It 'cancelar revisión histórica conserva original y no escribe' {
        $global:JunoTransFake.Backup.TransparencyBackup=New-TransSnapshot $false
        Mock Confirm-JunoReview {throw [OperationCanceledException]::new('SIMULATED cancelled')}
        $r=Invoke-JunoTransparencyRequest Restore -Confirmed
        $r.Outcome|Should Be 'Cancelled';$global:JunoTransFake.Writes|Should Be 0;$global:JunoTransFake.Saves|Should Be 0
        $global:JunoTransFake.Backup.TransparencyBackup.Exists|Should Be $false
    }
    It 'un recurso ocupado impide toda lectura/escritura del almacén' {
        Mock Enter-JunoLease {throw 'Recurso ocupado: otra interfaz'}
        $r=Invoke-JunoTransparencyRequest Disable -Confirmed;$r.Outcome|Should Be 'Busy'
        $global:JunoTransFake.Reads|Should Be 0;$global:JunoTransFake.Writes|Should Be 0;$global:JunoTransFake.Exits|Should Be 0
    }
}

function Get-TransControls($control){foreach($child in $control.Controls){$child;Get-TransControls $child}}
function Test-TransButtonFlag($form,[string]$name,[string]$flag){$buttons=@($form.Controls.Find($name,$true));return ($buttons.Count -gt 0 -and [bool]$buttons[0].$flag)}
function Get-TransButton($form,[string]$name){return @($form.Controls.Find($name,$true))[0]}
function Wait-TransUi($form){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}while($form.Transparency.IsBusy -and $clock.ElapsedMilliseconds -lt 4000)
    if($form.Transparency.IsBusy){throw 'TEST: la UI no recibió el resultado'}
}
function Complete-TransUi($form,$provider,[string]$state='Enabled',[bool]$restore=$false){
    $r=New-Object Juno.Preview.TransparencyResult;$r.State=$state;$r.CanChange=$true;$r.CanRestore=$restore;$r.Message='Lectura simulada'
    $provider.Complete($r);Wait-TransUi $form
}
Describe 'Tarjeta Transparencia y navegación sin operaciones reales' {
    BeforeEach {
        $script:transProvider=New-Object Juno.Preview.Testing.ControlledTransparency
        $script:transController=New-Object Juno.Preview.TransparencyController($transProvider)
        $script:transConfirmation=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:transDashboard=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))
        $script:transForm=New-Object Juno.Preview.ShellForm($transRoot,$transDashboard,$transController,$transConfirmation)
    }
    AfterEach {$transForm.Dispose();$transProvider.Complete((New-Object Juno.Preview.TransparencyResult))}
    It 'construir y navegar sin mostrar no inicia consultas ni escrituras' {
        foreach($section in [Juno.Preview.ShellForm]::Sections){$transForm.Navigate($section)}
        $transProvider.Calls|Should Be 0;$transProvider.WriteCalls|Should Be 0
    }
    It 'abrir y visitar Rendimiento inicia solo lectura y permite navegar mientras consulta' {
        $transForm.Show();[Windows.Forms.Application]::DoEvents();$transForm.Navigate('Rendimiento')
        $transProvider.Calls|Should Be 1;$transProvider.LastAction|Should Be 'Read'
        foreach($name in @('TransparencyRead','TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Enabled)|Should Be $false}
        foreach($section in [Juno.Preview.ShellForm]::Sections){$transForm.Navigate($section)}
        $transProvider.Calls|Should Be 1;$transProvider.WriteCalls|Should Be 0
        Complete-TransUi $transForm $transProvider
        $transForm.Navigate('Rendimiento')
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'Activada'
        (Test-TransButtonFlag $transForm 'TransparencyDisable' Accent)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Accent)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Secondary)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Enabled)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Enabled)|Should Be $false
    }
    It 'cancelar la confirmación no envía una escritura al adaptador' {
        $transForm.Show();$transForm.Navigate('Rendimiento');Complete-TransUi $transForm $transProvider
        $transForm.RequestTransparency('Disable')|Should Be $false
        $transConfirmation.Calls|Should Be 1;$transProvider.Calls|Should Be 1;$transProvider.WriteCalls|Should Be 0
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'Solicitud cancelada'
    }
    It 'una escritura bloquea acciones y cierre pero conserva navegación hasta la verificación' {
        $transForm.Show();$transForm.Navigate('Rendimiento');Complete-TransUi $transForm $transProvider
        $transProvider.Next();$transConfirmation.Accept=$true
        $transForm.RequestTransparency('Disable')|Should Be $true
        $transForm.RequestTransparency('Enable')|Should Be $false
        $transController.IsWriting|Should Be $true;$transProvider.WriteCalls|Should Be 1
        foreach($name in @('TransparencyRead','TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Enabled)|Should Be $false}
        # La instantánea anterior sigue vigente hasta que llegue la verificación.
        (Test-TransButtonFlag $transForm 'TransparencyDisable' Accent)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Accent)|Should Be $false
        $transForm.Close();$transForm.IsDisposed|Should Be $false
        $transForm.Navigate('Aplicaciones');$transForm.SelectedSection|Should Be 'Aplicaciones'
        Complete-TransUi $transForm $transProvider 'Disabled' $true
        $transForm.Navigate('Rendimiento')
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'Desactivada'
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Accent)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyDisable' Accent)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyDisable' Secondary)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Enabled)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Accent)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Secondary)|Should Be $true
        $transForm.Close();$transForm.ResourcesReleased|Should Be $true
    }
    It 'cerrar durante una consulta libera la vista sin callbacks tardíos a controles' {
        [Windows.Forms.Control]::CheckForIllegalCrossThreadCalls=$true
        $transForm.Show();$transForm.Navigate('Rendimiento');$transForm.Close()
        $transForm.IsDisposed|Should Be $true;$transProvider.Disposed|Should Be $true
        $transProvider.Complete((New-Object Juno.Preview.TransparencyResult))
        $transController.Poll()|Should Be $false;$transProvider.WriteCalls|Should Be 0
    }
    It 'un fallo no habilita cambios ni conserva una lectura como actual' {
        $transForm.Show();$transForm.Navigate('Rendimiento')
        $transProvider.Completion.TrySetException([InvalidOperationException]::new('SIMULATED'))|Out-Null
        Wait-TransUi $transForm
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'No disponible'
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Enabled)|Should Be $false
        $transController.CanStart('Read')|Should Be $true
        foreach($name in @('TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Accent)|Should Be $false}
    }
    It 'una identidad incompatible permite consultar pero no confirmar ni enviar cambios desde la tarjeta' {
        $transForm.Show();$transForm.Navigate('Rendimiento')
        $r=New-Object Juno.Preview.TransparencyResult;$r.State='Enabled';$r.Outcome='Failed';$r.BackupIssue='UserMismatch'
        $r.Message=Get-JunoBackupFailureText 'UserMismatch'
        $transProvider.Complete($r);Wait-TransUi $transForm
        $transController.CanStart('Read')|Should Be $true
        foreach($name in @('TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Enabled)|Should Be $false}
        $transForm.RequestTransparency('Disable')|Should Be $false
        $transConfirmation.Calls|Should Be 0;$transProvider.WriteCalls|Should Be 0
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'El respaldo no es compatible'
        foreach($name in @('TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Accent)|Should Be $false}
    }
    It 'una restauración pendiente muestra reconciliación y ofrece solo restaurar o consultar' {
        $transForm.Show();$transForm.Navigate('Rendimiento')
        $r=New-Object Juno.Preview.TransparencyResult;$r.Pending=$true;$r.CanRestore=$true;$r.Message='Restauración interrumpida'
        $transProvider.Complete($r);Wait-TransUi $transForm
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'pendiente de revisión'
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Enabled)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Enabled)|Should Be $false
        foreach($name in @('TransparencyEnable','TransparencyDisable','TransparencyRestore')){(Test-TransButtonFlag $transForm $name Accent)|Should Be $false}
    }
    It 'un estado desconocido explica el motivo y no resalta una acción incompatible' {
        $transForm.Show();$transForm.Navigate('Rendimiento')
        $r=New-Object Juno.Preview.TransparencyResult;$r.State='Unknown';$r.Outcome='Failed';$r.Message='El valor de transparencia no es compatible; consulta antes de reintentar.'
        $transProvider.Complete($r);Wait-TransUi $transForm
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'No se pudo completar el cambio'
        foreach($name in @('TransparencyEnable','TransparencyDisable','TransparencyRestore')){
            (Test-TransButtonFlag $transForm $name Enabled)|Should Be $false
            (Test-TransButtonFlag $transForm $name Accent)|Should Be $false
        }
    }
    It 'conserva el estado visual al navegar entre secciones' {
        $transForm.Show();$transForm.Navigate('Rendimiento');Complete-TransUi $transForm $transProvider 'Disabled' $true
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Accent)|Should Be $true
        $transForm.Navigate('Aplicaciones');$transForm.Navigate('Rendimiento')
        (Test-TransButtonFlag $transForm 'TransparencyEnable' Accent)|Should Be $true
        (Test-TransButtonFlag $transForm 'TransparencyDisable' Secondary)|Should Be $false
        (Test-TransButtonFlag $transForm 'TransparencyRestore' Enabled)|Should Be $true
    }
    It 'Restauración general sigue inactiva e indica dónde restaurar Transparencia' {
        $transForm.Navigate('Restauración')
        ((Get-TransControls $transForm).Text -join ' ')|Should Match 'general aún no está integrada'
        foreach($button in @(Get-TransControls $transForm|Where-Object{$_.Name -eq 'ToolAction'})){$button.Enabled|Should Be $false}
    }
    It 'el bucle modal de una revisión no abre confirmaciones repetidas' {
        $provider=New-Object Juno.Preview.Testing.ControlledTransparency
        $controller=New-Object Juno.Preview.TransparencyController($provider)
        $confirmation=New-Object Juno.Preview.Testing.PumpingConfirmation
        $dashboard=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))
        $form=New-Object Juno.Preview.ShellForm($transRoot,$dashboard,$controller,$confirmation)
        try{
            $form.Show();$form.Navigate('Rendimiento')
            $script:modalProvider=$provider
            $response=[Action[bool]]{param($allowed)$script:modalProvider.PendingReview=$null;$script:modalProvider.Complete((New-Object Juno.Preview.TransparencyResult))}
            $provider.PendingReview=New-Object Juno.Preview.TransparencyReview('Revisión ficticia',$response)
            Wait-TransUi $form
            $confirmation.Calls|Should Be 1
        }finally{$form.Dispose()}
    }
}

function New-TransBridgeFixture {
    $folder=Join-Path $TestDrive ('Puente con espacios '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
    foreach($file in @('BackupStore.ps1','RecoveryOperations.ps1','TransparencyOperations.ps1','TransparencyAdapter.ps1','VisualInterop.ps1')){
        [IO.File]::Copy((Join-Path $transRoot $file),(Join-Path $folder $file))
    }
    $mutexName='Local\Juno.Tests.Transparency.'+[Guid]::NewGuid().ToString('N')
    $p=Join-Path $folder 'BackupStore.ps1';$s=[IO.File]::ReadAllText($p).Replace('Global\JUNO.0.8.State',$mutexName);[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($true))
    $literal=$folder.Replace("'","''")
    $barriers=@'
# Fronteras ficticias en una copia privada; el proveedor de producción no recibe flags de prueba.
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Get-JunoStorePath([string]$kind,[string]$scope='User'){
    if($kind -cne 'General' -or $scope -cne 'User'){throw 'TEST: ámbito prohibido'}
    return '__FOLDER__\Datos ficticios\backup.json'
}
function Get-TransparencySnapshot {return (Get-Content -LiteralPath '__FOLDER__\registro-ficticio.json' -Raw|ConvertFrom-Json)}
function Set-JunoTransparencySnapshot($target){
    Assert-JunoLease
    Assert-JunoVisualSnapshot $target -Transparency
    [IO.File]::WriteAllText('__FOLDER__\registro-ficticio.json',($target|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
}
function Notify-TransparencyChange {return $false}
function Set-RegistryVisual {throw 'TEST: escritor real prohibido'}
'@
    $p=Join-Path $folder 'TransparencyAdapter.ps1';[IO.File]::AppendAllText($p,("
"+$barriers.Replace('__FOLDER__',$literal)),[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $folder 'registro-ficticio.json'),((New-TransSnapshot)|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{Root=$folder;Mutex=$mutexName;Backup=(Join-Path $folder 'Datos ficticios\backup.json')}
}
function Wait-TransBridge($task){
    if(-not $task.Wait(15000)){throw 'TEST: el puente simulado no terminó'}
    return $task.GetAwaiter().GetResult()
}
Describe 'Puente PowerShell real con Registro ficticio, almacén y mutex privados' {
    BeforeEach {$script:bridgeFixture=New-TransBridgeFixture;$script:bridge=New-Object Juno.Preview.PowerShellTransparencyService($bridgeFixture.Root)}
    AfterEach {$bridge.Dispose()}
    It 'consulta en runspace sin crear carpetas ni respaldos' {
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))
        $r.State|Should Be 'Enabled';$r.CanChange|Should Be $true
        [IO.Directory]::Exists((Split-Path $bridgeFixture.Backup -Parent))|Should Be $false
    }
    It 'rechaza escritura sin confirmación aun si se llama al proveedor directamente' {
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Disable',$false));$r.Outcome|Should Be 'Cancelled'
        [IO.File]::Exists($bridgeFixture.Backup)|Should Be $false
    }
    It 'adquiere, escribe, verifica y libera en el mismo hilo, preservando el sobre estable' {
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Disable',$true))
        $r.Outcome|Should Be 'Applied';$r.State|Should Be 'Disabled'
        $saved=Get-Content -LiteralPath $bridgeFixture.Backup -Raw|ConvertFrom-Json
        $saved.Format|Should Be 'JUNO.Backup';$saved.Kind|Should Be 'General';$saved.Scope|Should Be 'User'
        $saved.Data.TransparencyBackup.Value|Should Be '1'
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Restore',$true))
        $r.Outcome|Should Be 'Restored';$r.State|Should Be 'Enabled'
        $lease=[Threading.Mutex]::new($false,$bridgeFixture.Mutex)
        try{$lease.WaitOne(0)|Should Be $true;$lease.ReleaseMutex()}finally{$lease.Dispose()}
    }
    It 'la interfaz antigua con el mismo mutex impide operar desde la nueva' {
        Enter-JunoLease $bridgeFixture.Mutex
        try{
            $r=Wait-TransBridge ($bridge.ExecuteAsync('Disable',$true));$r.Outcome|Should Be 'Busy'
            [IO.File]::Exists($bridgeFixture.Backup)|Should Be $false
        }finally{Exit-JunoLease}
        (Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))).Outcome|Should Be 'Read'
    }
    It 'aceptar revisión histórica conserva el archivo anterior y restaura su ausencia' {
        [void][IO.Directory]::CreateDirectory((Split-Path $bridgeFixture.Backup -Parent))
        $old=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=(New-TransSnapshot $false)}
        $old=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=$old}
        [IO.File]::WriteAllText($bridgeFixture.Backup,($old|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($bridgeFixture.Backup)
        $task=$bridge.ExecuteAsync('Restore',$true);$clock=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $bridge.PendingReview -and -not $task.IsCompleted -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
        $review=$bridge.PendingReview
        if($null -eq $review){$detail=Wait-TransBridge $task;throw ('TEST: falta revisión: '+$detail.Message)}
        $review.Answer($true)
        (Wait-TransBridge $task).Outcome|Should Be 'Restored'
        $history=@(Get-ChildItem -LiteralPath (Split-Path $bridgeFixture.Backup -Parent) -Filter '*.previous.*.json'|Where-Object{[IO.File]::ReadAllText($_.FullName) -ceq $before})
        $history.Count|Should Be 1
        [IO.File]::ReadAllText($history[0].FullName)|Should Be $before
        (Get-Content -LiteralPath (Join-Path $bridgeFixture.Root 'registro-ficticio.json') -Raw|ConvertFrom-Json).Exists|Should Be $false
    }
    It 'la revisión histórica viaja a UI y su cancelación conserva los archivos byte a byte' {
        [void][IO.Directory]::CreateDirectory((Split-Path $bridgeFixture.Backup -Parent))
        $old=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=(New-TransSnapshot $false)}
        $old=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=$old}
        [IO.File]::WriteAllText($bridgeFixture.Backup,($old|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($bridgeFixture.Backup)
        $task=$bridge.ExecuteAsync('Restore',$true)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $bridge.PendingReview -and -not $task.IsCompleted -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
        $review=$bridge.PendingReview
        if($null -eq $review){$detail=Wait-TransBridge $task;throw ('TEST: no llegó la revisión: '+$detail.Message)}
        $review.Message|Should Match 'Actual:'
        {Enter-JunoLease $bridgeFixture.Mutex}|Should Throw
        (Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))).Outcome|Should Be 'Busy'
        $other=New-Object Juno.Preview.PowerShellTransparencyService($bridgeFixture.Root)
        try{(Wait-TransBridge ($other.ExecuteAsync('Read',$false))).Outcome|Should Be 'Busy'}finally{$other.Dispose()}
        $review.Answer($false)
        (Wait-TransBridge $task).Outcome|Should Be 'Cancelled'
        [IO.File]::ReadAllText($bridgeFixture.Backup)|Should Be $before
        # Una respuesta tardía a esa revisión no autoriza una operación posterior.
        $second=$bridge.ExecuteAsync('Restore',$true);$clock.Restart()
        while($null -eq $bridge.PendingReview -and -not $second.IsCompleted -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
        $current=$bridge.PendingReview
        if($null -eq $current){$detail=Wait-TransBridge $second;throw ('TEST: falta segunda revisión: '+$detail.Message)}
        $review.Answer($true);Start-Sleep -Milliseconds 100
        $second.IsCompleted|Should Be $false
        $current.Answer($false)
        (Wait-TransBridge $second).Outcome|Should Be 'Cancelled'
        [IO.File]::ReadAllText($bridgeFixture.Backup)|Should Be $before
    }
    It 'el puente no comparte el timeout lector ni detiene escrituras al disponer' {
        $source=[IO.File]::ReadAllText((Join-Path $transRoot 'ui\PowerShellTransparencyService.cs'))
        $source|Should Match 'PSThreadOptions.ReuseThread'
        $source|Should Not Match 'ProcessDashboardQuery|\.Kill\(|\.Stop\(|\.BeginStop\(|CancelAfter\(|WaitForExit\('
        $adapter=[IO.File]::ReadAllText((Join-Path $transRoot 'TransparencyAdapter.ps1'))
        $adapter|Should Not Match 'SetValue\(|DeleteValue\(|Write-JunoStore|\.CreateDirectory\('
    }
}

Describe 'Identidad del respaldo en el puente de Transparencia sin cambios reales' {
    BeforeEach {$script:bridgeFixture=New-TransBridgeFixture;$script:bridge=New-Object Juno.Preview.PowerShellTransparencyService($bridgeFixture.Root)}
    AfterEach {$bridge.Dispose()}
    It 'propaga <Code> a la vista y bloquea aplicar/restaurar sin exponer datos privados' -TestCases @(
        @{Field='Sid';Value='OTHER-PRIVATE-SID';Code='UserMismatch'},
        @{Field='Machine';Value='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Code='MachineMismatch'},
        @{Field='Scope';Value='Machine';Code='ScopeMismatch'}
    ) {
        param($Field,$Value,$Code)
        [void][IO.Directory]::CreateDirectory((Split-Path $bridgeFixture.Backup -Parent))
        $data=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;TransparencyBackup=(New-TransSnapshot $false)}
        $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=$data}
        $doc.$Field=$Value
        [IO.File]::WriteAllText($bridgeFixture.Backup,($doc|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($bridgeFixture.Backup);$registry=[IO.File]::ReadAllText((Join-Path $bridgeFixture.Root 'registro-ficticio.json'))
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))
        $r.State|Should Be 'Enabled';$r.Outcome|Should Be 'Failed';$r.BackupIssue|Should Be $Code
        $r.CanChange|Should Be $false;$r.CanRestore|Should Be $false
        $r.Message.Contains($bridgeFixture.Root)|Should Be $false;$r.Message|Should Not Match 'OTHER-PRIVATE-SID|aaaaaaaa-bbbb'
        foreach($action in @('Enable','Disable','Restore')){(Wait-TransBridge ($bridge.ExecuteAsync($action,$true))).BackupIssue|Should Be $Code}
        [IO.File]::ReadAllText($bridgeFixture.Backup)|Should Be $before
        [IO.File]::ReadAllText((Join-Path $bridgeFixture.Root 'registro-ficticio.json'))|Should Be $registry
    }
    It 'un histórico sin identidad se conserva bloqueado incluso con confirmación y revisión disponibles' {
        [void][IO.Directory]::CreateDirectory((Split-Path $bridgeFixture.Backup -Parent))
        $old=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;TransparencyBackup=(New-TransSnapshot $false)}
        [IO.File]::WriteAllText($bridgeFixture.Backup,($old|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($bridgeFixture.Backup)
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))
        $r.BackupIssue|Should Be 'UnverifiableLegacy';$r.CanRestore|Should Be $false;$r.CanChange|Should Be $false
        (Wait-TransBridge ($bridge.ExecuteAsync('Restore',$true))).BackupIssue|Should Be 'UnverifiableLegacy'
        $bridge.PendingReview|Should BeNullOrEmpty
        [IO.File]::ReadAllText($bridgeFixture.Backup)|Should Be $before
        @(Get-ChildItem -LiteralPath (Split-Path $bridgeFixture.Backup -Parent) -File).Count|Should Be 1
    }
    It 'un fallo simulado de identidad se puede reintentar con el token correcto sin reescribir el respaldo' {
        [void][IO.Directory]::CreateDirectory((Split-Path $bridgeFixture.Backup -Parent))
        $data=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;TransparencyBackup=(New-TransSnapshot $false)}
        $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=$data}
        [IO.File]::WriteAllText($bridgeFixture.Backup,($doc|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($bridgeFixture.Backup)
        # Cambiar SOLO la dependencia ficticia del token; jamás la identidad del respaldo.
        $adapter=Join-Path $bridgeFixture.Root 'TransparencyAdapter.ps1';$source=[IO.File]::ReadAllText($adapter)
        [IO.File]::WriteAllText($adapter,($source+"`r`nfunction Get-JunoIdentity {[pscustomobject]@{Sid='SANDBOX-FAKE-SID';Machine='11111111-2222-3333-4444-555555555555'}}"),[Text.UTF8Encoding]::new($true))
        (Wait-TransBridge ($bridge.ExecuteAsync('Read',$false))).BackupIssue|Should Be 'UserMismatch'
        [IO.File]::WriteAllText($adapter,$source,[Text.UTF8Encoding]::new($true))
        $r=Wait-TransBridge ($bridge.ExecuteAsync('Read',$false));$r.Outcome|Should Be 'Read';$r.BackupIssue|Should BeNullOrEmpty;$r.CanRestore|Should Be $true
        [IO.File]::ReadAllText($bridgeFixture.Backup)|Should Be $before
    }
}
