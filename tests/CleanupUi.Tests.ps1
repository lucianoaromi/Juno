#requires -Version 5.1
# La apertura es simulada; no se examina ni elimina ningún archivo del usuario.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$cleanupUiRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledCleanupSettings' -as [type])){
    $files=@(Get-ChildItem (Join-Path $cleanupUiRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function Click-CleanupWindows {
    $button=$cleanupWindow.Controls.Find('CleanupWindows',$true)[0]
    [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
}
Describe 'Limpieza moderna: acceso útil a Windows sin resultados inventados' {
    BeforeEach {
        $script:cleanupLaunch=New-Object Juno.Preview.Testing.ControlledCleanupSettings
        $script:cleanupConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:cleanupPower=New-Object Juno.Preview.Testing.ControlledPower
        $script:cleanupEnergy=New-Object Juno.Preview.PowerController($cleanupPower)
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService));$s=New-Object Juno.Preview.StartupController((New-Object Juno.Preview.UnavailableStartupService))
        $script:cleanupWindow=New-Object Juno.Preview.ShellForm($cleanupUiRoot,$d,$t,$cleanupConfirm,$cleanupEnergy,$null,$null,$v,$null,$s,$null,$null,$cleanupLaunch)
        $cleanupWindow.Navigate('Mantenimiento')
    }
    AfterEach {$cleanupWindow.Dispose()}
    It 'contiene solo título, descripción breve y una acción real' {
        $section=$cleanupWindow.Controls.Find('cleanup',$true)[0];$section.Controls.Count|Should Be 3
        $section.Controls[0].Text|Should Be 'LIMPIEZA INTELIGENTE'
        $section.Controls[1].Text|Should Be 'Revisá los archivos temporales y elegí qué eliminar en Windows.'
        $section.Controls[2].Text|Should Be 'Abrir limpieza de Windows';$section.Controls[2].Secondary|Should Be $true
        ($section.Controls.Text -join ' ')|Should Not Match 'Analizar|GB|MB|recuperable|liberado|diagnóstico|detalles'
        @($section.Controls|Where-Object{$_ -is [Windows.Forms.DataGridView] -or $_ -is [Windows.Forms.ListView]}).Count|Should Be 0
        $cleanupWindow.Controls.Find('InformationBadge',$true)[0].Text|Should Match 'MANTENIMIENTO EN WINDOWS'
    }
    It 'mostrar y navegar no analiza, abre herramientas ni consulta servicios' {
        $cleanupWindow.Show();[Windows.Forms.Application]::DoEvents()
        1..3|ForEach-Object{$cleanupWindow.Navigate('Aplicaciones');$cleanupWindow.Navigate('Mantenimiento')}
        $cleanupLaunch.Calls|Should Be 0;$cleanupPower.Calls|Should Be 0;$cleanupConfirm.Calls|Should Be 0
    }
    It 'abre Windows sin escrituras, confirmaciones ni alteraciones de recuperación' {
        $before=$cleanupEnergy.Snapshot;$before.CanRestore=$true
        Click-CleanupWindows
        $cleanupLaunch.Calls|Should Be 1;$cleanupPower.Calls|Should Be 0;$cleanupPower.WriteCalls|Should Be 0;$cleanupConfirm.Calls|Should Be 0
        [object]::ReferenceEquals($before,$cleanupEnergy.Snapshot)|Should Be $true;$cleanupEnergy.Snapshot.CanRestore|Should Be $true
        $cleanupWindow.SelectedSection|Should Be 'Mantenimiento';@($cleanupWindow.OwnedForms).Count|Should Be 0
    }
    It 'un fallo de Windows se informa sin detalle técnico ni resultados falsos y permite reintentar' {
        $cleanupLaunch.Fail=$true;Click-CleanupWindows
        $cleanupWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Be 'No se pudo abrir la limpieza de Windows.'
        $cleanupWindow.Controls.Find('cleanup',$true)[0].Controls.Count|Should Be 3
        $cleanupLaunch.Fail=$false;Click-CleanupWindows;$cleanupLaunch.Calls|Should Be 2;$cleanupPower.WriteCalls|Should Be 0
        $cleanupWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Not Be 'No se pudo abrir la limpieza de Windows.'
    }
    It 'el acceso queda deshabilitado durante una operación y se habilita al terminar' {
        $cleanupWindow.RequestPower('Read')|Should Be $true;$cleanupWindow.Navigate('Mantenimiento')
        $button=$cleanupWindow.Controls.Find('CleanupWindows',$true)[0];$button.Enabled|Should Be $false;Click-CleanupWindows;$cleanupLaunch.Calls|Should Be 0
        $cleanupPower.Complete((New-Object Juno.Preview.PowerResult));[void]$cleanupEnergy.Poll()
        [void]$cleanupWindow.GetType().GetMethod('RefreshTransparencyView',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($cleanupWindow,@())
        $button.Enabled|Should Be $true;Click-CleanupWindows;$cleanupLaunch.Calls|Should Be 1
    }
    It 'conserva una sección compacta y legible al navegar en <Width>x<Height>' -TestCases @(@{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}) {
        param($Width,$Height)$cleanupWindow.ClientSize=New-Object Drawing.Size($Width,$Height);$cleanupWindow.PerformLayout()
        $section=$cleanupWindow.Controls.Find('cleanup',$true)[0];($section.Height -le 190)|Should Be $true
        foreach($child in $section.Controls){($child.Left -ge 0 -and $child.Right -le $section.ClientSize.Width -and $child.Bottom -le $section.ClientSize.Height)|Should Be $true}
        for($i=0;$i -lt 3;$i++){for($j=$i+1;$j -lt 3;$j++){$section.Controls[$i].Bounds.IntersectsWith($section.Controls[$j].Bounds)|Should Be $false}}
        $size=$section.Size;$cleanupWindow.Navigate('Inicio');$cleanupWindow.Navigate('Mantenimiento');$cleanupWindow.Controls.Find('cleanup',$true)[0].Size|Should Be $size
    }
    It 'conserva las demás herramientas y el acceso oficial de discos' {
        $cleanupWindow.Navigate('Aplicaciones');$cleanupWindow.Controls.Find('startup',$true)[0].Controls.Count|Should Be 3
        $cleanupWindow.Navigate('Rendimiento');foreach($name in @('VisualWindows','PowerWindows','TransparencyWindows')){@($cleanupWindow.Controls.Find($name,$true)).Count|Should Be 1}
        $cleanupWindow.Navigate('Mantenimiento');@($cleanupWindow.Controls.Find('ToolAction',$true)).Count|Should Be 0
        $cleanupWindow.Controls.Find('DiskWindows',$true)[0].Text|Should Be 'Optimizar unidades en Windows'
    }
    It 'usa la URI oficial sin comandos automáticos ni elevación en <Windows>' -TestCases @(@{Windows='Windows 10'},@{Windows='Windows 11'}) {
        param($Windows)$capture=New-Object Juno.Preview.Testing.ConfigurationLaunchCapture;$capture.Cleanup().Open();$info=$capture.Info
        $info.FileName|Should Be 'ms-settings:storagesense';$info.Arguments|Should BeNullOrEmpty;$info.Verb|Should BeNullOrEmpty;$info.UseShellExecute|Should Be $true
    }
}
