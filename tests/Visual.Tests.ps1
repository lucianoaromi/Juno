#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$visualRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledVisual' -as [type])){
    $files=@(Get-ChildItem (Join-Path $visualRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@('Dashboard.TestSupport.cs','Transparency.TestSupport.cs','Power.TestSupport.cs','Visual.TestSupport.cs'|ForEach-Object{Join-Path $PSScriptRoot $_})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $visualRoot 'BackupStore.ps1')
. (Join-Path $visualRoot 'RecoveryOperations.ps1')
. (Join-Path $visualRoot 'TransparencyOperations.ps1')
. (Join-Path $visualRoot 'TransparencyAdapter.ps1')
. (Join-Path $visualRoot 'VisualEffectsOperations.ps1')
. (Join-Path $visualRoot 'VisualAdapter.ps1')
function Get-CurrentEffects {throw 'TEST: API real prohibida'}
function Get-VisualRegistrySnapshot {throw 'TEST: Registro real prohibido'}
function Set-JunoEffects($effects){throw 'TEST: API real prohibida'}
function Restore-VisualRegistry($snapshots){throw 'TEST: Registro real prohibido'}
function Get-JunoStorePath {throw 'TEST: almacén real prohibido'}
function Read-JunoStore {throw 'TEST: respaldo real prohibido'}
function Write-JunoStore {throw 'TEST: escritor real prohibido'}
function Confirm-JunoReview([string]$message){throw 'TEST: revisión real prohibida'}
function Get-TransparencySnapshot {throw 'TEST: Registro real prohibido'}
function Set-JunoTransparencySnapshot($target){throw 'TEST: Registro real prohibido'}
function Notify-TransparencyChange {throw 'TEST: notificación real prohibida'}
function New-VisualFixture {
    $effects=[ordered]@{}
    foreach($name in @('UIEffects','ClientAreaAnimation','MenuAnimation','ComboBoxAnimation','ListSmoothScrolling','MenuFade','SelectionFade','ToolTipAnimation','ToolTipFade','CursorShadow','DropShadow','MinimizeAnimation','FontSmoothing','DragFullWindows')){$effects[$name]=$true}
    $registry=@(Get-JunoVisualTargets|Where-Object{$_[1] -ne 'EnableTransparency'}|ForEach-Object{
        $value=if($_[2] -eq 'Binary'){'AAAAAAAAAAA='}elseif($_[1] -eq 'FontSmoothing'){'2'}elseif($_[1] -eq 'VisualFXSetting'){'3'}else{'1'}
        [pscustomobject]@{Key=$_[0];Name=$_[1];Exists=$true;Kind=$_[2];Value=$value}
    })
    return [pscustomobject]@{State=[pscustomobject]@{Effects=[pscustomobject]$effects;Registry=$registry};Backup=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=$null};Transparency=[pscustomobject]@{Exists=$true;Kind='DWord';Value='1'};Writes=0;Saves=0;Fault='';History=@();Reviews=0;Reads=0}
}
Describe 'Efectos visuales mediante el motor estable y fronteras ficticias' {
    BeforeEach {
        $global:JunoVisualFake=New-VisualFixture
        $script:JunoLease=$null
        Mock Enter-JunoLease {$script:JunoLease=[pscustomobject]@{Thread=[Threading.Thread]::CurrentThread.ManagedThreadId;Abandoned=$false}}
        Mock Exit-JunoLease {$script:JunoLease=$null}
        Mock Initialize-JunoVisualInterop {}
        Mock Get-CurrentEffects {if($global:JunoVisualFake.Fault -eq 'ReadAfterWrite' -and $global:JunoVisualFake.Writes -gt 0){throw 'SIMULATED unreadable API'};Copy-JunoObject $global:JunoVisualFake.State.Effects}
        Mock Get-VisualRegistrySnapshot {return ,(Copy-JunoObject $global:JunoVisualFake.State.Registry)}
        Mock Read-JunoStore {param($kind,$scope,$default) $global:JunoVisualFake.Reads++;Assert-JunoBackupData $kind $global:JunoVisualFake.Backup $scope;Copy-JunoObject $global:JunoVisualFake.Backup}
        Mock Write-JunoStore {param($kind,$data,$scope) Assert-JunoLease;Assert-JunoBackupData $kind $data $scope;$global:JunoVisualFake.Saves++;$global:JunoVisualFake.Backup=Copy-JunoObject $data;$global:JunoVisualFake.History+=@(Copy-JunoObject $data)}
        Mock Set-JunoEffects {
            param($effects)
            Assert-JunoLease;$f=$global:JunoVisualFake;$f.Writes++
            if($f.Fault -eq 'ApiBefore'){throw 'SIMULATED API failure'}
            foreach($p in $effects.PSObject.Properties){$f.State.Effects.($p.Name)=$p.Value}
            if($f.Fault -eq 'ApiAfter'){throw 'SIMULATED API partial failure'}
        }
        Mock Restore-VisualRegistry {
            param($snapshots)
            Assert-JunoLease;$f=$global:JunoVisualFake;$f.Writes++
            foreach($r in $snapshots){if($f.Fault -eq 'Registry'){throw 'SIMULATED Registry failure'};$index=-1;for($i=0;$i -lt $f.State.Registry.Count;$i++){if($f.State.Registry[$i].Name -ceq $r.Name){$index=$i;break}};if($index -lt 0){throw 'TEST: destino inesperado'};$f.State.Registry[$index]=Copy-JunoObject $r}
        }
        Mock Confirm-JunoReview {$global:JunoVisualFake.Reviews++}
        Mock Get-TransparencySnapshot {Copy-JunoObject $global:JunoVisualFake.Transparency}
        Mock Set-JunoTransparencySnapshot {param($target) $global:JunoVisualFake.Transparency=Copy-JunoObject $target}
        Mock Notify-TransparencyChange {$true}
    }
    AfterEach {$script:JunoLease=$null}
    It 'consulta personalizada no escribe ni importa respaldos' {
        $r=Invoke-JunoVisualRequest Read;$r.State|Should Be Custom;$r.CanApply|Should Be $true;$r.CanRestore|Should Be $false
        $global:JunoVisualFake.Writes|Should Be 0;$global:JunoVisualFake.Saves|Should Be 0
        $r.Details|Should Match 'FontSmoothing';$r.Details|Should Match 'HKCU'
    }
    It 'marcador administrado por Windows no afirma ajustes de fábrica' {
        ($global:JunoVisualFake.State.Registry|Where-Object{$_.Name -eq 'VisualFXSetting'}).Value='0'
        (Invoke-JunoVisualRequest Read).State|Should Be Default
        [Juno.Preview.VisualController]::StateText('Default')|Should Be 'Administrada por Windows'
    }
    It 'preset <Mode> requiere API y Registro, conserva original y evita repetición' -TestCases @(@{Mode='Quality';Font=$true},@{Mode='Maximum';Font=$false}) {
        param($Mode,$Font)
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State
        $r=Invoke-JunoVisualRequest $Mode -Confirmed;$r.Outcome|Should Be Applied;$r.State|Should Be $Mode
        $f.State.Effects.FontSmoothing|Should Be $Font
        ($f.State.Registry|Where-Object{$_.Name -eq 'FontSmoothing'}).Value|Should Be $(if($Font){'2'}else{'0'})
        Test-JunoEqual $f.Backup.VisualEffects $original.Effects|Should Be $true
        Test-JunoEqual $f.Backup.VisualRegistry $original.Registry|Should Be $true
        $writes=$f.Writes;$saves=$f.Saves;(Invoke-JunoVisualRequest $Mode -Confirmed).Outcome|Should Be Unchanged
        $f.Writes|Should Be $writes;$f.Saves|Should Be $saves
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored
        Test-JunoEqual $f.State $original|Should Be $true;$f.Backup.VisualEffects|Should BeNullOrEmpty;$f.Backup.Journal.Visual|Should BeNullOrEmpty
    }
    It 'aplicación sin confirmar se rechaza antes de leer o escribir' {
        (Invoke-JunoVisualRequest Quality).Outcome|Should Be Cancelled
        $global:JunoVisualFake.Reads|Should Be 0;$global:JunoVisualFake.Writes|Should Be 0;$global:JunoVisualFake.Saves|Should Be 0
    }
    It 'API y Registro discordantes o incompletos no se anuncian optimizados: <Kind>' -TestCases @(@{Kind='Mismatch'},@{Kind='Incomplete'},@{Kind='RegistryOnly'}) {
        param($Kind)
        $f=$global:JunoVisualFake
        switch($Kind){Mismatch{($f.State.Registry|Where-Object{$_.Name -eq 'FontSmoothing'}).Value='0'} Incomplete{$f.State.Effects.PSObject.Properties.Remove('MenuFade')} RegistryOnly{$preset=Get-JunoVisualPreset $f.State $true;$f.State.Registry=@($f.State.Registry|ForEach-Object{$old=$_;$match=@($preset.Registry|Where-Object{$_.Name -ceq $old.Name});if($match.Count){$match[0]}else{$old}})}}
        $r=Invoke-JunoVisualRequest Read
        $r.State|Should Not Be Quality;$r.State|Should Not Be Maximum
        if($Kind -eq 'Incomplete'){$r.Outcome|Should Be Failed;$r.CanApply|Should Be $false}
    }
    It 'error <Fault> conserva original y permite recuperar sin éxito falso' -TestCases @(@{Fault='ApiBefore'},@{Fault='ApiAfter'},@{Fault='Registry'}) {
        param($Fault)
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State;$f.Fault=$Fault
        $r=Invoke-JunoVisualRequest Quality -Confirmed;$r.Outcome|Should Be Failed
        $f.Backup.Journal.Visual.Phase|Should Be Partial
        (Invoke-JunoVisualRequest Read).PartialOperation|Should Be $true
        Test-JunoEqual $f.Backup.VisualEffects $original.Effects|Should Be $true
        $f.Fault='';(Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored
        Test-JunoEqual $f.State $original|Should Be $true
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Applied
    }
    It 'restauración parcial conserva originales y permite reintentar' {
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State
        Invoke-JunoVisualRequest Quality -Confirmed|Out-Null;$f.Fault='Registry'
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Failed;$f.Backup.VisualRegistry|Should Not BeNullOrEmpty
        $f.Fault='';(Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored
        Test-JunoEqual $f.State $original|Should Be $true
    }
    It 'API ilegible después de escribir conserva Pending hasta una recuperación revisada' {
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State;$f.Fault='ReadAfterWrite'
        $r=Invoke-JunoVisualRequest Quality -Confirmed;$r.Outcome|Should Be Failed;$r.Pending|Should Be $true;$r.CanRestore|Should Be $false
        $f.Backup.Journal.Visual.Pending|Should Be $true
        $f.Fault='';$r=Invoke-JunoVisualRequest Read;$r.CanRestore|Should Be $true;$r.CanApply|Should Be $false
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored;$f.Reviews|Should Be 1;Test-JunoEqual $f.State $original|Should Be $true
    }
    It 'reintenta un error de API confirmado como parcial sin reemplazar el primer original' {
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State;$f.Fault='ApiBefore'
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Failed;$f.Fault=''
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Applied
        Test-JunoEqual $f.Backup.VisualEffects $original.Effects|Should Be $true;Test-JunoEqual $f.Backup.VisualRegistry $original.Registry|Should Be $true
    }
    It 'un fallo al guardar intención impide tocar API o Registro' {
        Mock Write-JunoStore {throw 'SIMULATED save failure'}
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Failed;$global:JunoVisualFake.Writes|Should Be 0
    }
    It 'restaura valores originalmente ausentes' {
        $f=$global:JunoVisualFake;$item=($f.State.Registry|Where-Object{$_.Name -eq 'TaskbarAnimations'});$item.Exists=$false;$item.Kind=$null;$item.Value=$null
        Invoke-JunoVisualRequest Quality -Confirmed|Out-Null;(Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored
        $restored=($f.State.Registry|Where-Object{$_.Name -eq 'TaskbarAnimations'});$restored.Exists|Should Be $false;$restored.Value|Should BeNullOrEmpty
    }
    It 'histórico válido exige revisión y puede restaurar subconjuntos' {
        $f=$global:JunoVisualFake;$f.Backup.VisualEffects=[pscustomobject]@{FontSmoothing=$true};$f.Backup.VisualRegistry=@()
        $r=Invoke-JunoVisualRequest Read;$r.Historical|Should Be $true;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $true
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored;$f.Reviews|Should Be 1
    }
    It 'cancelar revisión histórica conserva el almacén' {
        $f=$global:JunoVisualFake;$f.Backup.VisualEffects=[pscustomobject]@{FontSmoothing=$true};$before=Copy-JunoObject $f.Backup
        Mock Confirm-JunoReview {throw [OperationCanceledException]::new('SIMULATED cancelled')}
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Cancelled
        Test-JunoEqual $f.Backup $before|Should Be $true;$f.Writes|Should Be 0
    }
    It 'respaldo incompatible bloquea aplicar y restaurar sin perder lectura' {
        Mock Read-JunoStore {Stop-JunoBackupValidation 'UserMismatch' 'SIMULATED identity'}
        $r=Invoke-JunoVisualRequest Quality -Confirmed;$r.Outcome|Should Be Failed;$r.BackupIssue|Should Be UserMismatch;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
        $global:JunoVisualFake.Writes|Should Be 0;$global:JunoVisualFake.Saves|Should Be 0
    }
    It 'conflicto externo conserva original y bloquea ambas escrituras' {
        $f=$global:JunoVisualFake;Invoke-JunoVisualRequest Quality -Confirmed|Out-Null;$writes=$f.Writes;$f.State.Effects.MenuFade=$true
        $r=Invoke-JunoVisualRequest Restore -Confirmed;$r.Outcome|Should Be Conflict;$r.CanRestore|Should Be $false;$r.CanApply|Should Be $false;$f.Writes|Should Be $writes
    }
    It 'pendiente exige revisión para restaurar y no permite nueva aplicación' {
        $f=$global:JunoVisualFake;Invoke-JunoVisualRequest Quality -Confirmed|Out-Null;$f.Backup.Journal.Visual.Pending=$true;$f.Backup.Journal.Visual.Phase='Applying';$writes=$f.Writes
        $r=Invoke-JunoVisualRequest Read;$r.Pending|Should Be $true;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $true
        (Invoke-JunoVisualRequest Maximum -Confirmed).Outcome|Should Be Failed;$f.Writes|Should Be $writes
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored;$f.Reviews|Should Be 1
    }
    It 'revalida después de guardar intención y detecta cambios externos antes de escribir' {
        $f=$global:JunoVisualFake
        Mock Write-JunoStore {param($kind,$data,$scope) $global:JunoVisualFake.Backup=Copy-JunoObject $data;$global:JunoVisualFake.State.Effects.MenuFade=$false}
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Conflict;$f.Writes|Should Be 0;$f.Backup.Journal.Visual.Pending|Should Be $true
    }
    It 'mutex ocupado impide leer y escribir datos' {
        Mock Enter-JunoLease {throw 'Recurso ocupado: TEST'}
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Busy;$global:JunoVisualFake.Reads|Should Be 0;$global:JunoVisualFake.Writes|Should Be 0
    }
    It 'las dos restauraciones preservan independientemente datos y diarios compartidos' {
        $f=$global:JunoVisualFake;$original=Copy-JunoObject $f.State
        Invoke-JunoTransparencyRequest Disable -Confirmed|Out-Null;$trans=Copy-JunoObject $f.Backup.TransparencyBackup;$journal=Copy-JunoObject $f.Backup.Journal.Transparency
        (Invoke-JunoVisualRequest Quality -Confirmed).Outcome|Should Be Applied
        Test-JunoEqual $f.Backup.TransparencyBackup $trans|Should Be $true;Test-JunoEqual $f.Backup.Journal.Transparency $journal|Should Be $true;$f.Transparency.Value|Should Be '0'
        $visual=Copy-JunoObject $f.Backup.Journal.Visual
        (Invoke-JunoTransparencyRequest Restore -Confirmed).Outcome|Should Be Restored;$f.Transparency.Value|Should Be '1';Test-JunoEqual $f.Backup.Journal.Visual $visual|Should Be $true
        (Invoke-JunoVisualRequest Restore -Confirmed).Outcome|Should Be Restored;Test-JunoEqual $f.State $original|Should Be $true;$f.Backup.Journal.Transparency|Should BeNullOrEmpty
    }
}

function New-VisualUiResult {return [Juno.Preview.VisualResult]@{State='Custom';CanApply=$true;Message='Diagnóstico ficticio';Details='SPI ficticio / HKCU ficticio'}}
function Set-VisualUiResult($r){$visualProvider.Next();$visualController.Start('Read',$visualConfirm)|Out-Null;$visualProvider.Complete($r);$visualController.Poll()|Out-Null;$visualForm.Navigate('Rendimiento')}
Describe 'Tarjeta visual con tareas controladas' {
    BeforeEach {
        $script:visualProvider=New-Object Juno.Preview.Testing.ControlledVisual;$script:visualController=New-Object Juno.Preview.VisualController($visualProvider)
        $script:visualConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:visualSettings=New-Object Juno.Preview.Testing.ControlledVisualSettings
        $script:visualForm=New-Object Juno.Preview.ShellForm($visualRoot,(New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))),(New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService))),$visualConfirm,(New-Object Juno.Preview.PowerController((New-Object Juno.Preview.UnavailablePowerService))),$null,$null,$visualController,$visualSettings)
    }
    AfterEach {$visualForm.Dispose();$visualProvider.Complete((New-VisualUiResult))}
    It 'navegar sin mostrar no consulta ni cambia nada' {
        foreach($section in [Juno.Preview.ShellForm]::Sections){$visualForm.Navigate($section)};$visualProvider.Calls|Should Be 0;$visualProvider.WriteCalls|Should Be 0
    }
    It 'abrir Rendimiento consulta secuencialmente sin escrituras ni selección automática de máximo' {
        $visualForm.Show();$visualForm.Navigate('Rendimiento');$watch=[Diagnostics.Stopwatch]::StartNew()
        while($visualProvider.Calls -eq 0 -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $visualProvider.Calls|Should Be 1;$visualProvider.LastAction|Should Be Read;$visualProvider.WriteCalls|Should Be 0
        $visualProvider.Complete((New-VisualUiResult));$watch.Restart();while($visualController.IsBusy -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $visualForm.Controls.Find('VisualMode',$true)[0].SelectedIndex|Should Be 0
    }
    It 'el recomendado es predeterminado y cancelar una confirmación no escribe' {
        Set-VisualUiResult (New-VisualUiResult)
        $visualForm.Controls.Find('VisualMode',$true)[0].SelectedIndex|Should Be 0
        $visualForm.Controls.Find('VisualApply',$true)[0].Accent|Should Be $true
        $visualForm.RequestVisual('Quality')|Should Be $false;$visualConfirm.Calls|Should Be 1;$visualConfirm.LastMessage|Should Match 'mantiene el suavizado';$visualProvider.WriteCalls|Should Be 0
    }
    It 'avanzado identifica su efecto sobre la legibilidad y mantiene un solo botón principal' {
        Set-VisualUiResult (New-VisualUiResult);$visualForm.Controls.Find('VisualMode',$true)[0].SelectedIndex=1
        $visualForm.Controls.Find('VisualApply',$true)[0].Text|Should Be 'Aplicar Máximo rendimiento'
        $visualForm.RequestVisual('Maximum')|Should Be $false;$visualConfirm.LastMessage|Should Match 'Desactiva el suavizado';$visualConfirm.LastMessage.Length|Should BeLessThan 180
        $dialog=[Juno.Preview.TransparencyConfirmation]::CreateDialog($visualConfirm.LastTitle,$visualConfirm.LastMessage)
        try{$dialog.AcceptButton.Text|Should Be Cancelar;$dialog.Height|Should BeLessThan 300}finally{$dialog.Dispose()}
    }
    It 'no repite preset vigente y ofrece restaurar solo cuando corresponde' -TestCases @(@{Restore=$true},@{Restore=$false}) {
        param($Restore)
        $r=New-VisualUiResult;$r.State='Quality';$r.CanRestore=$Restore;Set-VisualUiResult $r
        @($visualForm.Controls.Find('VisualApply',$true)).Count|Should Be 0
        @($visualForm.Controls.Find('VisualRestore',$true)).Count|Should Be ([int]$Restore)
        $visualForm.RequestVisual('Quality')|Should Be $false;$visualConfirm.Calls|Should Be 0
    }
    It 'pendiente oculta la aplicación y ofrece una sola restauración' {
        $r=New-VisualUiResult;$r.State='Partial';$r.CanApply=$false;$r.CanRestore=$true;$r.Pending=$true;Set-VisualUiResult $r
        @($visualForm.Controls.Find('VisualApply',$true)).Count|Should Be 0
        @($visualForm.Controls.Find('VisualRestore',$true)).Count|Should Be 1
        $visualForm.Controls.Find('VisualRestore',$true)[0].Secondary|Should Be $true
        $visualForm.RequestVisual('Quality')|Should Be $false;$visualProvider.WriteCalls|Should Be 0
    }
    It 'escritura conserva estado previo, bloquea otras herramientas y cierre, y permite navegar' {
        Set-VisualUiResult (New-VisualUiResult);$visualForm.Show();[Windows.Forms.Application]::DoEvents()
        # Esperar la lectura inicial del proveedor de transparencia no configurado.
        $watch=[Diagnostics.Stopwatch]::StartNew();while($visualForm.Transparency.IsBusy -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $visualProvider.Next();$visualConfirm.Accept=$true;$visualForm.RequestVisual('Quality')|Should Be $true
        $visualController.Snapshot.State|Should Be Custom;$visualForm.RequestVisual('Maximum')|Should Be $false;$visualForm.RequestPower('Read')|Should Be $false;$visualForm.RequestTransparency('Read')|Should Be $false
        $visualForm.Controls.Find('VisualApply',$true)[0].Enabled|Should Be $false;$visualForm.Controls.Find('VisualMode',$true)[0].Enabled|Should Be $false
        $visualForm.Close();$visualForm.IsDisposed|Should Be $false;$visualForm.Navigate('Inicio');$visualForm.Navigate('Aplicaciones')
        $done=New-VisualUiResult;$done.State='Quality';$done.CanRestore=$true;$done.Outcome='Applied';$visualProvider.Complete($done)
        $watch.Restart();while($visualController.IsBusy -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $visualForm.Navigate('Rendimiento');$visualForm.Controls.Find('VisualRestore',$true)[0].Accent|Should Be $true;$visualProvider.WriteCalls|Should Be 1
    }
    It 'detalles conservan el diagnóstico sin mostrarlo en la tarjeta' {
        Set-VisualUiResult (New-VisualUiResult);$visualForm.Controls.Find('VisualState',$true)[0].Text|Should Not Match 'SPI|HKCU'
        $details=$visualForm.CreateVisualDetails();try{$details.Controls.Find('TechnicalDetails',$true)[0].Text|Should Match 'SPI ficticio';$details.Controls.Find('VisualRead',$true)[0].Enabled|Should Be $true}finally{$details.Dispose()}
    }
    It 'Configurar en Windows reemplaza Ver detalles solo en la tarjeta visual' {
        Set-VisualUiResult (New-VisualUiResult)
        $card=$visualForm.Controls.Find('visual',$true)[0];$button=$card.Controls.Find('VisualWindows',$true)[0]
        $button.Text|Should Be 'Configurar en Windows';$button.Secondary|Should Be $true;$button.Accent|Should Be $false
        @($card.Controls.Find('VisualDetails',$true)).Count|Should Be 0
        $button.ContextMenuStrip.Items['VisualRefreshMenu'].Text|Should Be 'Actualizar estado'
        $button.ContextMenuStrip.Items['VisualDiagnosticsMenu'].Text|Should Be 'Diagnóstico'
        @($visualForm.Controls.Find('PowerDetails',$true)).Count|Should Be 1
        @($visualForm.Controls.Find('TransparencyDetails',$true)).Count|Should Be 1
    }
    It 'abrir Windows no confirma, consulta, aplica ni altera el estado o la restauración' {
        $r=New-VisualUiResult;$r.CanRestore=$true;Set-VisualUiResult $r
        $before=$visualController.Snapshot;$calls=$visualProvider.Calls
        $button=$visualForm.Controls.Find('VisualWindows',$true)[0]
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $visualSettings.Calls|Should Be 1;$visualProvider.Calls|Should Be $calls;$visualProvider.WriteCalls|Should Be 0;$visualConfirm.Calls|Should Be 0
        [object]::ReferenceEquals($before,$visualController.Snapshot)|Should Be $true
        $visualForm.Controls.Find('VisualRestore',$true)[0].Enabled|Should Be $true
        $visualForm.Navigate('Inicio');$visualForm.Navigate('Rendimiento');$visualForm.SelectedSection|Should Be Rendimiento
    }
    It 'un error de apertura es breve y conserva el diagnóstico completo sin cambiar elegibilidad' {
        $r=New-VisualUiResult;$r.CanRestore=$true;Set-VisualUiResult $r;$visualSettings.Fail=$true
        $button=$visualForm.Controls.Find('VisualWindows',$true)[0]
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $visualForm.Controls.Find('VisualState',$true)[0].Text|Should Be 'No se pudo abrir la configuración de Windows.'
        $visualController.Snapshot.CanRestore|Should Be $true;$visualController.Snapshot.State|Should Be Custom;$visualProvider.WriteCalls|Should Be 0
        $details=$visualForm.CreateVisualDetails();try{$details.Controls.Find('TechnicalDetails',$true)[0].Text|Should Match 'SIMULATED Windows settings launch failure'}finally{$details.Dispose()}
    }
    It 'no abre Windows durante una operación visual incluso ante un evento programático' {
        Set-VisualUiResult (New-VisualUiResult);$visualProvider.Next();$visualConfirm.Accept=$true;$visualForm.RequestVisual('Quality')|Should Be $true
        $button=$visualForm.Controls.Find('VisualWindows',$true)[0];$button.Enabled|Should Be $false
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $visualSettings.Calls|Should Be 0;$visualProvider.WriteCalls|Should Be 1
    }
    It 'actualizar desde el menú detecta un conflicto simulado sin restaurar automáticamente' {
        $r=New-VisualUiResult;$r.CanRestore=$true;Set-VisualUiResult $r
        $button=$visualForm.Controls.Find('VisualWindows',$true)[0]
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $visualProvider.Next();$visualForm.Controls.Find('VisualWindows',$true)[0].ContextMenuStrip.Items['VisualRefreshMenu'].PerformClick()
        $visualProvider.LastAction|Should Be Read;$visualProvider.WriteCalls|Should Be 0
        $conflict=New-VisualUiResult;$conflict.Outcome='Conflict';$conflict.CanApply=$false;$conflict.CanRestore=$false;$conflict.Message='Cambio manual simulado fuera de JUNO'
        $visualProvider.Complete($conflict);$visualController.Poll()|Out-Null;$visualForm.Navigate('Rendimiento')
        @($visualForm.Controls.Find('VisualApply',$true)).Count|Should Be 0
        @($visualForm.Controls.Find('VisualRestore',$true)).Count|Should Be 0
        $visualForm.Controls.Find('VisualState',$true)[0].Text|Should Match 'cambió fuera de JUNO';$visualConfirm.Calls|Should Be 0;$visualProvider.WriteCalls|Should Be 0
    }
    It 'el menú contextual permite abrir el diagnóstico sin el botón retirado' {
        Set-VisualUiResult (New-VisualUiResult)
        $global:JunoVisualDiagnosticObserved=$null;$timer=New-Object Windows.Forms.Timer;$timer.Interval=100
        $timer.Add_Tick({
            $dialogs=@([Windows.Forms.Application]::OpenForms|Where-Object{$_.Name -eq 'VisualDetailsDialog'})
            if($dialogs.Count -eq 0){return};$dialog=$dialogs[0]
            $global:JunoVisualDiagnosticObserved=$dialog.Controls.Find('TechnicalDetails',$true)[0].Text
            $dialog.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Close()
        })
        try{$timer.Start();$visualForm.Controls.Find('VisualWindows',$true)[0].ContextMenuStrip.Items['VisualDiagnosticsMenu'].PerformClick();$global:JunoVisualDiagnosticObserved|Should Match 'SPI ficticio';$visualProvider.WriteCalls|Should Be 0}finally{$timer.Stop();$timer.Dispose()}
    }
    It 'F5 con foco en la tarjeta actualiza mediante la consulta existente' {
        Set-VisualUiResult (New-VisualUiResult);$visualForm.Show();$watch=[Diagnostics.Stopwatch]::StartNew()
        while($visualForm.Transparency.IsBusy -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $button=$visualForm.Controls.Find('VisualWindows',$true)[0];$button.Focus()|Should Be $true
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $button.IsDisposed|Should Be $false;$visualSettings.Calls|Should Be 1;$visualProvider.Next()
        $message=[Windows.Forms.Message]::Create($visualForm.Handle,0,[IntPtr]::Zero,[IntPtr]::Zero)
        $args=[object[]]@($message,[Windows.Forms.Keys]::F5)
        $visualForm.GetType().GetMethod('ProcessCmdKey',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($visualForm,$args)|Should Be $true
        $visualProvider.LastAction|Should Be Read;$visualController.IsBusy|Should Be $true;$visualProvider.WriteCalls|Should Be 0
    }
    It 'los botones conservan sus límites con restauración y ventana estrecha' -TestCases @(@{Width=1180},@{Width=940},@{Width=700}) {
        param($Width)
        $r=New-VisualUiResult;$r.CanRestore=$true;Set-VisualUiResult $r;$visualForm.ClientSize=New-Object Drawing.Size($Width,650);$visualForm.PerformLayout()
        foreach($name in @('VisualWindows','VisualRestore')){
            $button=$visualForm.Controls.Find($name,$true)[0]
            ($button.Right -le $button.Parent.ClientSize.Width)|Should Be $true;($button.Bottom -le $button.Parent.ClientSize.Height)|Should Be $true
            foreach($other in $button.Parent.Controls){if($other -ne $button){$button.Bounds.IntersectsWith($other.Bounds)|Should Be $false}}
        }
    }
    It 'error borra elegibilidad anterior y permite consultar sin escrituras' {
        Set-VisualUiResult (New-VisualUiResult);$visualProvider.Next();$visualController.Start('Read',$visualConfirm)|Out-Null;$visualProvider.Completion.TrySetException([InvalidOperationException]::new('SIMULATED'))|Out-Null;$visualController.Poll()|Out-Null;$visualForm.Navigate('Rendimiento')
        @($visualForm.Controls.Find('VisualApply',$true)).Count|Should Be 0;$visualController.CanStart('Read')|Should Be $true;$visualController.Status|Should Match 'No se pudo completar';$visualProvider.WriteCalls|Should Be 0
    }
    It 'cierre durante una lectura libera la vista sin cancelar el proveedor' {
        $visualForm.RequestVisual('Read')|Should Be $true;$visualForm.Dispose();$visualProvider.Disposed|Should Be $true;$visualProvider.Complete((New-VisualUiResult));$visualController.Poll()|Should Be $false;$visualProvider.WriteCalls|Should Be 0
    }
}

Describe 'Resolvedor oficial de Efectos visuales sin ejecutar Windows' {
    It 'reutiliza SystemPropertiesPerformance en <Directory> para OS64=<OS64> Process64=<Process64>' -TestCases @(
        @{OS64=$true;Process64=$true;Directory='System32'},@{OS64=$true;Process64=$false;Directory='Sysnative'},@{OS64=$false;Process64=$false;Directory='System32'}
    ) {
        param($OS64,$Process64,$Directory)
        $folder=Join-Path $TestDrive ('Resolvedor con espacios '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
        $source=[IO.File]::ReadAllText((Join-Path $visualRoot 'UiSupport.ps1'))
        $source+="`r`nfunction Get-JunoRuntimeArchitecture {[pscustomobject]@{OS64=`$$OS64;Process64=`$$Process64}}`r`nfunction Test-Path {param(`$LiteralPath,`$PathType) return `$true}`r`n"
        [IO.File]::WriteAllText((Join-Path $folder 'UiSupport.ps1'),$source,[Text.UTF8Encoding]::new($true))
        $global:JunoVisualOpenedPath=$null;$start=[Action[string]]{param($path)$global:JunoVisualOpenedPath=$path}
        $launcher=New-Object Juno.Preview.WindowsVisualSettingsLauncher($folder,$start);$launcher.Open()
        $global:JunoVisualOpenedPath|Should Be (Join-Path $env:WINDIR ($Directory+'\SystemPropertiesPerformance.exe'))
    }
    It 'herramienta ausente no llega al lanzador' {
        $folder=Join-Path $TestDrive 'Herramienta ausente';[void][IO.Directory]::CreateDirectory($folder)
        $source=[IO.File]::ReadAllText((Join-Path $visualRoot 'UiSupport.ps1'))+"`r`nfunction Test-Path {param(`$LiteralPath,`$PathType) return `$false}`r`n"
        [IO.File]::WriteAllText((Join-Path $folder 'UiSupport.ps1'),$source,[Text.UTF8Encoding]::new($true))
        $global:JunoVisualOpenedPath=$null;$start=[Action[string]]{param($path)$global:JunoVisualOpenedPath=$path}
        $launcher=New-Object Juno.Preview.WindowsVisualSettingsLauncher($folder,$start)
        {$launcher.Open()}|Should Throw;$global:JunoVisualOpenedPath|Should BeNullOrEmpty
    }
    It 'no espera al proceso, eleva ni inicia operaciones de efectos al abrir Windows' {
        $source=[IO.File]::ReadAllText((Join-Path $visualRoot 'ui\VisualModel.cs'))
        $launcherSource=$source.Substring($source.IndexOf('public sealed class WindowsVisualSettingsLauncher'),$source.IndexOf('public enum VisualAction')-$source.IndexOf('public sealed class WindowsVisualSettingsLauncher'))
        $launcherSource|Should Match "Get-JunoSystemTool 'SystemPropertiesPerformance.exe'"
        $launcherSource|Should Match 'UseShellExecute=false'
        $launcherSource|Should Not Match 'WaitForExit|\.Wait\(|ShowDialog|runas|Invoke-JunoVisual|Apply-VisualEffects|SystemPropertiesAdvanced'
    }
}
