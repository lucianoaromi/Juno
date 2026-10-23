#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$restUiRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledRecovery' -as [type])){
    $files=@(Get-ChildItem (Join-Path $restUiRoot 'ui') -Filter *.cs|ForEach-Object FullName)+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object FullName)
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function New-RestUiItem([string]$id,[string]$state='Ready') {New-Object Juno.Preview.RecoveryItem -Property @{Id=$id;State=$state;Count=2;CanRestore=($state -eq 'Ready');Token='TEST-TOKEN';Details='PRIVATE SID GUID C:\Secrets\backup.json';Message='PRIVATE HKCU technical diagnostic'}}
function Set-RestUiItems($items){
    $ruController.Start($null,$null)|Out-Null;$r=New-Object Juno.Preview.RecoveryResult -Property @{Items=[Juno.Preview.RecoveryItem[]]@($items);MachineChecked=$true}
    $ruFake.Complete($r);$ruController.Poll()|Out-Null;$ruFake.Next();$ruWindow.Navigate('Restauración');$ruWindow.PerformLayout()
}
function Get-RestUiControls($control){foreach($child in $control.Controls){$child;Get-RestUiControls $child}}
function Click-RestUi([string]$name){$controls=$ruWindow.Controls.Find($name,$true);if($controls.Count -ne 1){throw ('Control no encontrado: '+$name)};$button=$controls[0];[void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))}
function Assert-RestUiLayout($control){
    foreach($c in $control.Controls){($c.Left -ge 0 -and $c.Top -ge 0 -and $c.Right -le $control.ClientSize.Width+1 -and $c.Bottom -le $control.ClientSize.Height+1)|Should Be $true;Assert-RestUiLayout $c}
    $children=@($control.Controls);for($i=0;$i -lt $children.Count;$i++){for($j=$i+1;$j -lt $children.Count;$j++){$children[$i].Bounds.IntersectsWith($children[$j].Bounds)|Should Be $false}}
}
Describe 'Restauración moderna: controles y eventos WinForms reales con servicios simulados' {
    BeforeEach {
        $script:ruFake=New-Object Juno.Preview.Testing.ControlledRecovery;$script:ruController=New-Object Juno.Preview.RecoveryController($ruFake)
        $script:ruConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:ruPower=New-Object Juno.Preview.Testing.ControlledPower;$script:ruTransparency=New-Object Juno.Preview.Testing.ControlledTransparency;$script:ruStartup=New-Object Juno.Preview.Testing.ControlledStartup;$script:ruVisual=New-Object Juno.Preview.Testing.ControlledVisual
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))
        $t=New-Object Juno.Preview.TransparencyController($ruTransparency);$p=New-Object Juno.Preview.PowerController($ruPower);$v=New-Object Juno.Preview.VisualController($ruVisual);$s=New-Object Juno.Preview.StartupController($ruStartup)
        $script:ruWindow=New-Object Juno.Preview.ShellForm($restUiRoot,$d,$t,$ruConfirm,$p,$null,$null,$v,$null,$s,$null,$null,$null,$null,$ruController)
        $ruWindow.Navigate('Restauración');$ruWindow.PerformLayout()
    }
    AfterEach {$ruWindow.Dispose()}
    It 'mostrar y navegar no consulta, restaura ni inicia efectos visuales' {
        foreach($section in @('Aplicaciones','Restauración','Acerca de','Restauración')){$ruWindow.Navigate($section)}
        $ruFake.Calls|Should Be 0;$ruVisual.Calls|Should Be 0;$ruStartup.Calls|Should Be 0
        @((Get-RestUiControls $ruWindow)|Where-Object{$_.Name -like '*RecoveryRestore' -or $_.Name -eq 'StartupRestore'}).Count|Should Be 0
    }
    It 'consultar usa solo lectura sin confirmación ni elevación automática' {
        Click-RestUi RecoveryRead;$ruFake.Calls|Should Be 1;$ruFake.Writes|Should Be 0;$ruFake.Confirmed|Should Be $false;$ruConfirm.Calls|Should Be 0
        $ruWindow.Controls.Find('RecoveryStatus',$true)[0].Text|Should Match 'Comprobando'
        $ruWindow.Controls.Find('RecoveryRead',$true)[0].Enabled|Should Be $false
    }
    It 'sin respaldos muestra mensaje claro y un solo botón' {
        Set-RestUiItems @();$section=$ruWindow.Controls.Find('RecoverySection',$true)[0]
        $ruWindow.Controls.Find('RecoveryStatus',$true)[0].Text|Should Be 'No hay cambios anteriores para restaurar.'
        @((Get-RestUiControls $section)|Where-Object{$_ -is [Windows.Forms.Button]}).Count|Should Be 1
        ($section.Height -le 225)|Should Be $true
    }
    It 'solo ofrece categorías listas y oculta detalles internos' {
        Set-RestUiItems @((New-RestUiItem Power),(New-RestUiItem Transparency Conflict),(New-RestUiItem Startup Error),(New-RestUiItem BackgroundUser Blocked),(New-RestUiItem Trim Empty))
        $section=$ruWindow.Controls.Find('RecoverySection',$true)[0];$text=(Get-RestUiControls $section).Text -join ' '
        $text|Should Not Match 'PRIVATE|HKCU|SID|GUID|Secrets|Ver detalles|Diagnóstico';$text|Should Match 'cambió fuera de JUNO'
        @($ruWindow.Controls.Find('PowerRecoveryRestore',$true)).Count|Should Be 1
        foreach($name in @('TransparencyRecoveryRestore','StartupRestore','BackgroundUserRecoveryRestore','TrimRecoveryRestore')){@($ruWindow.Controls.Find($name,$true)).Count|Should Be 0}
    }
    It 'si todo está bloqueado no invita a elegir una operación inexistente' {
        Set-RestUiItems @((New-RestUiItem Power Blocked),(New-RestUiItem Transparency Error))
        $ruController.Status|Should Match 'No hay recuperaciones disponibles';$ruController.Status|Should Not Match Elegí
    }
    It 'restaurar <Id> confirma su impacto y envía el token exacto' -TestCases @(@{Id='Power'},@{Id='Transparency'},@{Id='Startup'},@{Id='BackgroundUser'},@{Id='BackgroundPolicy'},@{Id='Trim'}) {
        param($Id)Set-RestUiItems @((New-RestUiItem $Id));$ruConfirm.Accept=$true;$ruWindow.RequestRecovery($Id)|Should Be $true
        $ruConfirm.Calls|Should Be 1;$ruFake.Id|Should Be $Id;$ruFake.Token|Should Be TEST-TOKEN;$ruFake.Confirmed|Should Be $true;$ruFake.Writes|Should Be 1
        $ruConfirm.LastMessage|Should Match ([regex]::Escape([Juno.Preview.RecoveryPresentation]::Name($Id)))
        if($Id -eq 'Trim'){$ruConfirm.LastMessage|Should Match 'desactiva TRIM NTFS'}
        if($Id -eq 'BackgroundPolicy'){$ruConfirm.LastMessage|Should Match 'todas las cuentas'}
    }
    It 'cancelar conserva la instantánea y no escribe' {
        Set-RestUiItems @((New-RestUiItem Power));$ruConfirm.Accept=$false;Click-RestUi PowerRecoveryRestore
        $ruFake.Writes|Should Be 0;$ruController.Find('Power').State|Should Be Ready;$ruController.Status|Should Match cancelada
    }
    It 'durante escritura bloquea duplicados, otros motores y cierre prematuro' {
        Set-RestUiItems @((New-RestUiItem Startup));$ruConfirm.Accept=$true;Click-RestUi StartupRestore
        $ruWindow.RequestRecovery('Startup')|Should Be $false;$ruWindow.RequestRecovery($null)|Should Be $false
        $ruWindow.RequestPower('Read')|Should Be $false;$ruWindow.RequestTransparency('Read')|Should Be $false;$ruWindow.RequestVisual('Read')|Should Be $false;$ruWindow.RequestStartup('Read',$null)|Should Be $false
        [Juno.Preview.Testing.StartupWindowEvents]::RequestClose($ruWindow)|Should Be $true
        $ruFake.Writes|Should Be 1;$ruController.Status|Should Match verificación;$ruController.Find('Startup').State|Should Be Ready
        $ruWindow.Navigate('Aplicaciones');$ruWindow.Controls.Find('StartupWindows',$true)[0].Enabled|Should Be $false
        $ruWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Match 'Restauración';$ruWindow.Navigate('Restauración')
    }
    It 'la confirmación modal impide solicitudes reentrantes' {
        Set-RestUiItems @((New-RestUiItem Transparency));$confirmation=New-Object Juno.Preview.Testing.ReentrantRecoveryConfirmation;$confirmation.Form=$ruWindow
        $ruController.Start('Transparency',$confirmation)|Should Be $true;$confirmation.Nested|Should Be $false;$ruFake.Writes|Should Be 1
    }
    It 'una categoría duplicada no es restaurable' {
        Set-RestUiItems @((New-RestUiItem Power),(New-RestUiItem Power));$ruController.CanRestore('Power')|Should Be $false
    }
    It 'el resultado parcial conserva su acción pendiente sin declarar éxito' {
        Set-RestUiItems @((New-RestUiItem Startup));$ruConfirm.Accept=$true;Click-RestUi StartupRestore
        $r=New-Object Juno.Preview.RecoveryResult -Property @{Outcome='Partial';Message='No se pudo recuperar todo. Los cambios pendientes conservan su respaldo.';Items=@((New-RestUiItem Startup));MachineChecked=$true}
        $ruFake.Complete($r);$ruController.Poll()|Out-Null;$ruWindow.Navigate('Restauración')
        $ruController.Status|Should Match pendientes;@($ruWindow.Controls.Find('StartupRestore',$true)).Count|Should Be 1
    }
    It 'refresca únicamente el controlador afectado después de <Id>' -TestCases @(@{Id='Power'},@{Id='Transparency'},@{Id='Startup'},@{Id='BackgroundUser'},@{Id='Trim'}) {
        param($Id)Set-RestUiItems @((New-RestUiItem $Id));$ruConfirm.Accept=$true;[void]$ruWindow.RequestRecovery($Id)
        $ruFake.Complete((New-Object Juno.Preview.RecoveryResult -Property @{Outcome='Restored';Message='Se recuperó la configuración anterior.';Attempted=$Id;MachineChecked=$true}))
        $clock=[Diagnostics.Stopwatch]::StartNew();while($ruController.IsBusy -and $clock.ElapsedMilliseconds -lt 1500){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
        $ruController.IsBusy|Should Be $false;$ruController.Status|Should Match recuperó
        $ruPower.Calls|Should Be ([int]($Id -eq 'Power'));$ruTransparency.Calls|Should Be ([int]($Id -eq 'Transparency'));$ruStartup.Calls|Should Be ([int]($Id -eq 'Startup'));$ruVisual.Calls|Should Be 0
        @((Get-RestUiControls $ruWindow)|Where-Object{$_.Name -like '*RecoveryRestore' -or $_.Name -eq 'StartupRestore'}).Count|Should Be 0
    }
    It 'fallos de tareas conservan el diagnóstico privado y muestran un mensaje breve' {
        $ruController.Start($null,$null)|Out-Null;$ruFake.Completion.SetException((New-Object InvalidOperationException 'PRIVATE ERROR'));$ruController.Poll()|Out-Null
        $ruController.Snapshot.Details|Should Match 'PRIVATE ERROR';$ruController.Status|Should Not Match PRIVATE;$ruController.CanRestore('Power')|Should Be $false
    }
    It 'sin privilegio indica la comprobación de equipo pendiente' {
        $ruController.Start($null,$null)|Out-Null;$ruFake.Complete((New-Object Juno.Preview.RecoveryResult));$ruController.Poll()|Out-Null
        $ruController.Status|Should Match 'administrador con la misma cuenta'
    }
    It 'vista completa sin superposición ni barra horizontal a <Width>x<Height>' -TestCases @(@{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}) {
        param($Width,$Height)$ruWindow.ClientSize=New-Object Drawing.Size($Width,$Height)
        Set-RestUiItems @((New-RestUiItem Power),(New-RestUiItem Transparency),(New-RestUiItem Startup),(New-RestUiItem BackgroundUser Blocked),(New-RestUiItem BackgroundPolicy Error),(New-RestUiItem Trim))
        $ruWindow.Show();[Windows.Forms.Application]::DoEvents();$section=$ruWindow.Controls.Find('RecoverySection',$true)[0];Assert-RestUiLayout $section
        $viewport=$ruWindow.Controls.Find('ContentViewport',$true)[0];$viewport.HorizontalScroll.Visible|Should Be $false
        if($Height -eq 500){$viewport.VerticalScroll.Visible|Should Be $true;$viewport.ScrollControlIntoView($section.Controls[$section.Controls.Count-1]);[Windows.Forms.Application]::DoEvents();($viewport.AutoScrollPosition.Y -lt 0)|Should Be $true}
    }
}
