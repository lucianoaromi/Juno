#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$startupUiRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledStartup' -as [type])){
    $files=@(Get-ChildItem (Join-Path $startupUiRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function Get-StartupUiControls($parent){foreach($child in $parent.Controls){$child;Get-StartupUiControls $child}}
function Click-StartupUi($name){$button=$sWindow.Controls.Find($name,$true)[0];[void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))}
Describe 'Inicio: acceso mínimo a Windows y recuperación conservada' {
    BeforeEach {
        $script:sFake=New-Object Juno.Preview.Testing.ControlledStartup
        $script:sController=New-Object Juno.Preview.StartupController($sFake)
        $script:sConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:sSettings=New-Object Juno.Preview.Testing.ControlledStartupSettings
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService));$p=New-Object Juno.Preview.PowerController((New-Object Juno.Preview.UnavailablePowerService));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService))
        $script:sWindow=New-Object Juno.Preview.ShellForm($startupUiRoot,$d,$t,$sConfirm,$p,$null,$null,$v,$null,$sController,$sSettings)
        $sWindow.Navigate('Aplicaciones');$sWindow.PerformLayout()
    }
    AfterEach {$sWindow.Dispose()}
    It 'contiene exactamente título, descripción y un botón' {
        $section=$sWindow.Controls.Find('startup',$true)[0];$section.Controls.Count|Should Be 3
        $section.Controls[0].Text|Should Be 'PROGRAMAS DE INICIO'
        $section.Controls[1].Text|Should Be 'Administrá qué aplicaciones se ejecutan automáticamente al iniciar Windows.'
        $section.Controls[2].Text|Should Be 'Configurar en Windows'
        @($section.Controls|Where-Object{$_ -is [Windows.Forms.Button]}).Count|Should Be 1
        $section.ContextMenuStrip|Should BeNullOrEmpty
    }
    It 'no consulta ni enumera programas al mostrar o navegar' {
        $sWindow.Show();[Windows.Forms.Application]::DoEvents()
        1..3|ForEach-Object{$sWindow.Navigate('Inicio');$sWindow.Navigate('Aplicaciones')}
        $sFake.Calls|Should Be 0;$sFake.WriteCalls|Should Be 0
    }
    It 'no reaparece una tabla aunque el controlador conserve entradas o respaldos' {
        $entry=New-Object Juno.Preview.StartupEntry -Property @{Id='PRIVATE-ID';Name='Aplicación oculta';State='Unknown'}
        $sController.Snapshot.Entries=@($entry);$sController.Snapshot.CanRestore=$true;$sController.Snapshot.Pending=$true;$sWindow.Navigate('Aplicaciones')
        $text=(Get-StartupUiControls ($sWindow.Controls.Find('startup',$true)[0])).Text -join ' '
        $text|Should Not Match 'Aplicación oculta|PRIVATE-ID|No disponible|Actualizar|Restaurar|Diagnóstico|detectad'
        @($sWindow.Controls.Find('StartupListViewport',$true)).Count|Should Be 0
        @($sWindow.Controls.Find('StartupRestore',$true)).Count|Should Be 0
    }
    It 'abrir Windows no consulta, confirma, restaura ni aplica cambios' {
        Click-StartupUi StartupWindows;$sSettings.Calls|Should Be 1;$sFake.Calls|Should Be 0;$sConfirm.Calls|Should Be 0
    }
    It 'un fallo de apertura informa brevemente sin agregar controles' {
        $sSettings.Fail=$true;Click-StartupUi StartupWindows
        $sWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Be 'No se pudo abrir la configuración de inicio de Windows.'
        $sWindow.Controls.Find('startup',$true)[0].Controls.Count|Should Be 3;$sFake.Calls|Should Be 0
    }
    It 'habilita el acceso al terminar una operación iniciada antes de navegar' {
        $sWindow.RequestStartup('Read',$null)|Should Be $true;$sWindow.Navigate('Aplicaciones')
        $button=$sWindow.Controls.Find('StartupWindows',$true)[0];$button.Enabled|Should Be $false
        Click-StartupUi StartupWindows;$sSettings.Calls|Should Be 0
        $sFake.Complete((New-Object Juno.Preview.StartupResult));[void]$sController.Poll()
        [void]$sWindow.GetType().GetMethod('RefreshTransparencyView',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($sWindow,@())
        $button.Enabled|Should Be $true;Click-StartupUi StartupWindows;$sSettings.Calls|Should Be 1;$sFake.WriteCalls|Should Be 0
    }
    It 'no ofrece operaciones individuales ni permite iniciarlas desde el shell' {
        $sWindow.RequestStartup('Enable','ID')|Should Be $false;$sWindow.RequestStartup('Disable','ID')|Should Be $false;$sFake.WriteCalls|Should Be 0
    }
    It 'la recuperación se consulta solo desde Restauración' {
        $sWindow.Navigate('Restauración');$sFake.Calls|Should Be 0;Click-StartupUi StartupRecoveryRead
        $sFake.LastAction|Should Be Read;$sFake.WriteCalls|Should Be 0
        $r=New-Object Juno.Preview.StartupResult;$r.CanRestore=$true;$r.Message='Hay cambios anteriores.';$sFake.Complete($r);[void]$sController.Poll();$sFake.Next();$sWindow.Navigate('Restauración')
        $sConfirm.Accept=$true;Click-StartupUi StartupRestore;$sFake.LastAction|Should Be Restore;$sFake.LastConfirmed|Should Be $true;$sConfirm.Calls|Should Be 1
    }
    It 'cancelar recuperación conserva el estado y no escribe' {
        $sController.Snapshot.CanRestore=$true;$sWindow.Navigate('Restauración');$sConfirm.Accept=$false;Click-StartupUi StartupRestore;$sFake.WriteCalls|Should Be 0;$sConfirm.Calls|Should Be 1
    }
    It 'respaldo incompatible impide restaurar' {
        $sController.Snapshot.CanRestore=$true;$sController.Snapshot.BackupIssue='UserMismatch';$sWindow.Navigate('Restauración');Click-StartupUi StartupRestore;$sFake.WriteCalls|Should Be 0
    }
    It 'la sección es compacta y sin superposición a <Width>x<Height>' -TestCases @(@{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}) {
        param($Width,$Height)$sWindow.ClientSize=New-Object Drawing.Size($Width,$Height);$sWindow.PerformLayout()
        $section=$sWindow.Controls.Find('startup',$true)[0];($section.Height -le 190)|Should Be $true
        foreach($child in $section.Controls){($child.Left -ge 0 -and $child.Right -le $section.ClientSize.Width -and $child.Bottom -le $section.ClientSize.Height)|Should Be $true}
        for($i=0;$i -lt 3;$i++){for($j=$i+1;$j -lt 3;$j++){$section.Controls[$i].Bounds.IntersectsWith($section.Controls[$j].Bounds)|Should Be $false}}
    }
    It 'usa la URI oficial con lanzador simulado en <Windows>' -TestCases @(@{Windows='Windows 10'},@{Windows='Windows 11'}) {
        param($Windows)$capture=New-Object Juno.Preview.Testing.StartupLaunchCapture;$capture.Launcher().Open();$capture.Uri|Should Be 'ms-settings:startupapps'
    }
}
