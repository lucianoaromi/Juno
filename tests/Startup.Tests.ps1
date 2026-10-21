#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$startupUiRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledStartup' -as [type])){
    $files=@(Get-ChildItem (Join-Path $startupUiRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function New-StartupUiResult {
    $value=New-Object Juno.Preview.StartupResult
    $value.Message='Entradas clásicas detectadas. Otras aplicaciones o entradas no legibles pueden no aparecer.'
    $value.Entries=@(
        (New-Object Juno.Preview.StartupEntry -Property @{Id='FICTICIO-1';Name='Spotify ficticio';Scope='Usuario';State='Enabled';CanChange=$true;Fingerprint='SOURCE-1';ApprovalToken='VALUE-1'}),
        (New-Object Juno.Preview.StartupEntry -Property @{Id='FICTICIO-2';Name='Discord ficticio';Scope='Usuario';State='Disabled';CanChange=$true;Fingerprint='SOURCE-2';ApprovalToken='VALUE-2'}),
        (New-Object Juno.Preview.StartupEntry -Property @{Id='FICTICIO-3';Name='Sincronizador ficticio';Scope='Equipo';State='Enabled';CanChange=$false;Reason='Necesitás permisos de administrador para modificar esta aplicación.'})
    )
    return $value
}
function Get-StartupUiControls($parent){foreach($child in $parent.Controls){$child;Get-StartupUiControls $child}}
function Click-StartupUi($name){$button=@(Get-StartupUiControls $sWindow|Where-Object Name -eq $name)[0];[void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))}
function Assert-StartupUiLayout($parent){
    foreach($child in $parent.Controls){
        if($parent.Name -notin @('ContentViewport','Sidebar')){($child.Left -ge 0 -and $child.Top -ge 0 -and $child.Right -le $parent.ClientSize.Width+1 -and $child.Bottom -le $parent.ClientSize.Height+1)|Should Be $true}
        Assert-StartupUiLayout $child
    }
    $children=@($parent.Controls)
    for($i=0;$i -lt $children.Count;$i++){for($j=$i+1;$j -lt $children.Count;$j++){if($children[$i].Bounds.IntersectsWith($children[$j].Bounds)){throw ('Solapamiento: '+$parent.Name+' '+$children[$i].Name+' / '+$children[$j].Name)}}}
}
Describe 'Inicio: controlador y WinForms con datos ficticios' {
    BeforeEach {
        $script:sFake=New-Object Juno.Preview.Testing.ControlledStartup
        $script:sController=New-Object Juno.Preview.StartupController($sFake)
        $script:sConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:sSettings=New-Object Juno.Preview.Testing.ControlledStartupSettings
        [void]$sController.Start('Read','',$sConfirm);$sFake.Complete((New-StartupUiResult));[void]$sController.Poll();$sFake.Next()
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))
        $t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService))
        $p=New-Object Juno.Preview.PowerController((New-Object Juno.Preview.UnavailablePowerService))
        $v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService))
        $script:sWindow=New-Object Juno.Preview.ShellForm($startupUiRoot,$d,$t,$sConfirm,$p,$null,$null,$v,$null,$sController,$sSettings)
        $sWindow.Navigate('Aplicaciones');$sWindow.PerformLayout()
    }
    AfterEach {$sWindow.Dispose()}
    It 'muestra nombre, estado, acción y ámbito sin datos técnicos' {
        $text=(Get-StartupUiControls $sWindow).Text -join ' '
        $text|Should Match 'PROGRAMAS DE INICIO|Spotify ficticio|Activado|Desactivado|Usuario|Equipo'
        $text|Should Not Match 'FICTICIO-1|SOURCE-1|VALUE-1|StartupApproved|HKEY|Registry64'
        (Get-StartupUiControls $sWindow|Where-Object Name -eq StartupAction0).Text|Should Be Desactivar
        (Get-StartupUiControls $sWindow|Where-Object Name -eq StartupAction1).Text|Should Be Activar
    }
    It 'cancelar una confirmación no envía escrituras' {
        $sConfirm.Accept=$false;Click-StartupUi StartupAction0;$sConfirm.Calls|Should Be 1;$sFake.WriteCalls|Should Be 0;$sController.IsBusy|Should Be $false;$sController.Status|Should Be 'Solicitud cancelada.'
    }
    It 'selección individual envía identidad y tokens con una sola confirmación' {
        $sConfirm.Accept=$true;Click-StartupUi StartupAction1;$sFake.WriteCalls|Should Be 1;$sFake.LastAction|Should Be Enable;$sFake.LastId|Should Be FICTICIO-2;$sFake.LastFingerprint|Should Be SOURCE-2;$sFake.LastApprovalToken|Should Be VALUE-2;$sFake.LastConfirmed|Should Be $true
        $sConfirm.Calls|Should Be 1;$sConfirm.LastMessage|Should Be '¿Activar Discord ficticio al iniciar Windows?'
    }
    It 'revisión incluye advertencia en la misma confirmación' {
        $sController.Snapshot.Entries[0].NeedsReview=$true;$sController.Snapshot.Entries[0].Reason='Puede afectar sincronización.';$sWindow.Navigate('Aplicaciones');$sConfirm.Accept=$true;Click-StartupUi StartupAction0
        $sConfirm.Calls|Should Be 1;$sConfirm.LastMessage|Should Match 'sincronización';$sFake.WriteCalls|Should Be 1
    }
    It 'entrada del equipo explica permisos sin confirmar ni escribir' {Click-StartupUi StartupAction2;$sFake.WriteCalls|Should Be 0;$sConfirm.Calls|Should Be 0;(Get-StartupUiControls $sWindow|Where-Object Name -eq StartupState).Text|Should Match 'administrador'}
    It 'controles incompatibles se deshabilitan mientras consulta sin bloquear navegación' {
        $sWindow.RequestStartup('Read',$null)|Should Be $true;$sController.Status|Should Match 'Consultando'
        foreach($name in @('StartupRead','StartupWindows','StartupAction0')){(Get-StartupUiControls $sWindow|Where-Object Name -eq $name).Enabled|Should Be $false}
        $sWindow.RequestStartup('Read',$null)|Should Be $false;$sWindow.RequestPower('Read')|Should Be $false;$sWindow.RequestTransparency('Read')|Should Be $false;$sWindow.RequestVisual('Read')|Should Be $false
        $sWindow.Navigate('Inicio');$sWindow.SelectedSection|Should Be Inicio;$sWindow.Navigate('Aplicaciones');$sFake.Calls|Should Be 2
    }
    It 'conserva el estado anterior hasta recibir verificación' {
        $sConfirm.Accept=$true;Click-StartupUi StartupAction0;$sController.Snapshot.Entries[0].State|Should Be Enabled;$sController.Status|Should Match 'Aplicando'
        $result=New-StartupUiResult;$result.Entries[0].State='Disabled';$result.CanRestore=$true;$result.Outcome='Applied';$result.Message='Spotify ficticio ya no se iniciará automáticamente mediante esta entrada.'
        $sFake.Complete($result);$sController.Poll()|Should Be $true;$sWindow.Navigate('Aplicaciones')
        (Get-StartupUiControls $sWindow|Where-Object Name -eq StartupAction0).Text|Should Be Activar
        (Get-StartupUiControls $sWindow|Where-Object Name -eq StartupRestore).Enabled|Should Be $true
    }
    It 'restauración solo aparece cuando corresponde' {
        @(Get-StartupUiControls $sWindow|Where-Object Name -eq StartupRestore).Count|Should Be 0
        $sController.Snapshot.CanRestore=$true;$sWindow.Navigate('Aplicaciones');$sConfirm.Accept=$true;Click-StartupUi StartupRestore;$sFake.LastAction|Should Be Restore;$sFake.LastId|Should Be '';$sConfirm.Calls|Should Be 1
    }
    It 'una operación pendiente bloquea entrada y mantiene recuperación' {
        $sController.Snapshot.Pending=$true;$sController.Snapshot.CanRestore=$true;$sController.Snapshot.Entries[0].CanChange=$false;$sWindow.Navigate('Aplicaciones');$sController.CanStart('Disable','FICTICIO-1')|Should Be $false;$sController.CanStart('Restore',$null)|Should Be $true
    }
    It 'actualización manual refleja cambios externos sin escribir ni restaurar' {
        Click-StartupUi StartupRead;$result=New-StartupUiResult;$result.Entries[0].CanChange=$false;$result.Entries[0].Reason='La entrada cambió.';$sFake.Complete($result);[void]$sController.Poll();$sWindow.Navigate('Aplicaciones')
        $sController.CanStart('Disable','FICTICIO-1')|Should Be $false;$sFake.WriteCalls|Should Be 0
    }
    It 'abrir Configuración es secundario, sin consulta, confirmación ni cambios' {
        $before=$sController.Snapshot;$calls=$sFake.Calls;Click-StartupUi StartupWindows;$sSettings.Calls|Should Be 1;$sConfirm.Calls|Should Be 0;$sFake.Calls|Should Be $calls;[object]::ReferenceEquals($before,$sController.Snapshot)|Should Be $true
        (Get-StartupUiControls $sWindow|Where-Object Name -eq StartupWindows).Secondary|Should Be $true
    }
    It 'fallo al abrir Windows muestra mensaje breve y conserva diagnóstico' {
        $sSettings.Fail=$true;Click-StartupUi StartupWindows;(Get-StartupUiControls $sWindow|Where-Object Name -eq StartupState).Text|Should Be 'No se pudo abrir la configuración de inicio de Windows.'
        $dialog=$sWindow.CreateStartupDetails();try{(Get-StartupUiControls $dialog|Where-Object Name -eq TechnicalDetails).Text|Should Match 'SIMULATED startup settings failure'}finally{$dialog.Dispose()};$sFake.WriteCalls|Should Be 0
    }
    It 'Windows no se abre durante una escritura aunque se fuerce el evento' {$sConfirm.Accept=$true;Click-StartupUi StartupAction0;Click-StartupUi StartupWindows;$sSettings.Calls|Should Be 0}
    It 'no enumera constantemente al navegar entre secciones' {1..3|ForEach-Object{foreach($section in [Juno.Preview.ShellForm]::Sections){$sWindow.Navigate($section)}};$sFake.Calls|Should Be 1}
    It 'cierre normal espera escritura y luego permite cerrar' {
        $sConfirm.Accept=$true;Click-StartupUi StartupAction0;[Juno.Preview.Testing.StartupWindowEvents]::RequestClose($sWindow)|Should Be $true;$sFake.Disposed|Should Be $false
        $sFake.Complete((New-StartupUiResult));[Juno.Preview.Testing.StartupWindowEvents]::RequestClose($sWindow)|Should Be $false
    }
    It 'cerrar durante una lectura libera la vista sin cancelar transacciones' {$sWindow.RequestStartup('Read',$null)|Should Be $true;$sWindow.Dispose();$sFake.Disposed|Should Be $true;$sFake.Complete((New-StartupUiResult));$sController.Poll()|Should Be $false}
    It 'error del servicio permite volver a consultar' {$sWindow.RequestStartup('Read',$null)|Should Be $true;$sFake.Completion.SetException((New-Object InvalidOperationException('SIMULATED')));[void]$sController.Poll();$sController.Snapshot.Outcome|Should Be Failed;$sFake.Next();$sWindow.RequestStartup('Read',$null)|Should Be $true}
    It 'IDs duplicados o estados desconocidos no autorizan escrituras' {$sController.Snapshot.Entries[1].Id='FICTICIO-1';$sController.CanStart('Disable','FICTICIO-1')|Should Be $false;$sController.Snapshot.Entries[2].CanChange=$true;$sController.Snapshot.Entries[2].State='Unknown';$sController.CanStart('Disable','FICTICIO-3')|Should Be $false}
    It 'respaldo incompatible bloquea cambio y restauración incluso con flags incoherentes' {$sController.Snapshot.BackupIssue='UserMismatch';$sController.Snapshot.CanRestore=$true;$sController.CanStart('Restore',$null)|Should Be $false;$sController.CanStart('Disable','FICTICIO-1')|Should Be $false}
    It 'confirmación reentrante no inicia consultas ni operaciones cruzadas' {
        $confirm=New-Object Juno.Preview.Testing.ReentrantStartupConfirmation
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService));$p=New-Object Juno.Preview.PowerController((New-Object Juno.Preview.UnavailablePowerService));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService))
        $other=New-Object Juno.Preview.ShellForm($startupUiRoot,$d,$t,$confirm,$p,$null,$null,$v,$null,$sController,$sSettings);$confirm.Form=$other
        try{$other.RequestStartup('Disable','FICTICIO-1')|Should Be $true;$confirm.Calls|Should Be 1;$confirm.Nested|Should Be $false;$sFake.WriteCalls|Should Be 1}finally{$other.Dispose()}
    }
    It 'el temporizador publica el resultado en el hilo de interfaz' {
        $previous=[Windows.Forms.Control]::CheckForIllegalCrossThreadCalls;[Windows.Forms.Control]::CheckForIllegalCrossThreadCalls=$true
        try{
            $sWindow.Show();$sWindow.RequestStartup('Read',$null)|Should Be $true;$r=New-StartupUiResult;$r.Entries[0].State='Disabled';$sFake.Complete($r)
            $watch=[Diagnostics.Stopwatch]::StartNew();while($sController.IsBusy -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
            $sController.IsBusy|Should Be $false;(Get-StartupUiControls $sWindow|Where-Object Name -eq StartupAction0).Text|Should Be Activar
        }finally{[Windows.Forms.Control]::CheckForIllegalCrossThreadCalls=$previous}
    }
    It 'confirmación usa Cancelar para Enter y Escape' {$dialog=[Juno.Preview.TransparencyConfirmation]::CreateDialog('JUNO · Programas de inicio','¿Desactivar Spotify al iniciar Windows?');try{$dialog.AcceptButton.Text|Should Be Cancelar;$dialog.CancelButton.Text|Should Be Cancelar}finally{$dialog.Dispose()}}
    It 'apertura oficial <Windows> usa URI fija con lanzador simulado' -TestCases @(@{Windows='Windows 10'},@{Windows='Windows 11'}) {
        param($Windows)$capture=New-Object Juno.Preview.Testing.StartupLaunchCapture;$capture.Launcher().Open();$capture.Uri|Should Be 'ms-settings:startupapps';$capture.Uri|Should Not Match 'exe|runas|powershell|cmd'
    }
    It 'distribución a <Width>x<Height> sin superposiciones con inventario' -TestCases @(@{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}) {
        param($Width,$Height)$sWindow.ClientSize=New-Object Drawing.Size($Width,$Height);$sWindow.Navigate('Aplicaciones');$sWindow.PerformLayout();Assert-StartupUiLayout $sWindow
        $viewport=(Get-StartupUiControls $sWindow|Where-Object Name -eq ContentViewport);($viewport.AutoScrollMinSize.Height -gt $viewport.Height)|Should Be $true
    }
}
