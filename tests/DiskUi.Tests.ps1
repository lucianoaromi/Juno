#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$diskUiRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledDiskSettings' -as [type])){
    $files=@(Get-ChildItem (Join-Path $diskUiRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function Click-DiskWindows {
    $b=$diskWindow.Controls.Find('DiskWindows',$true)[0]
    [void]$b.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($b,@([EventArgs]::Empty))
}
Describe 'Discos modernos: opción B y apertura oficial sin mantenimiento automático' {
    BeforeEach {
        $script:diskLaunch=New-Object Juno.Preview.Testing.ControlledDiskSettings
        $script:diskCleanup=New-Object Juno.Preview.Testing.ControlledCleanupSettings
        $script:diskConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:diskPower=New-Object Juno.Preview.Testing.ControlledPower
        $script:diskEnergy=New-Object Juno.Preview.PowerController($diskPower)
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService));$s=New-Object Juno.Preview.StartupController((New-Object Juno.Preview.UnavailableStartupService))
        $script:diskWindow=New-Object Juno.Preview.ShellForm($diskUiRoot,$d,$t,$diskConfirm,$diskEnergy,$null,$null,$v,$null,$s,$null,$null,$diskCleanup,$diskLaunch)
        $diskWindow.Navigate('Mantenimiento')
    }
    AfterEach {$diskWindow.Dispose()}
    It 'muestra únicamente título, descripción y un botón funcional' {
        $section=$diskWindow.Controls.Find('disks',$true)[0];$section.Controls.Count|Should Be 3
        $section.Controls[0].Text|Should Be 'DISCOS SSD/HDD'
        $section.Controls[1].Text|Should Be 'Consultá y optimizá tus unidades utilizando las herramientas de Windows.'
        $section.Controls[2].Text|Should Be 'Optimizar unidades en Windows';$section.Controls[2].Enabled|Should Be $true;$section.Controls[2].Secondary|Should Be $true
        ($section.Controls.Text -join ' ')|Should Not Match 'SMART|Healthy|TRIM|GB|WMI|CIM|No disponible|Sin conectar|Actualizar'
        @($diskWindow.Controls.Find('ToolAction',$true)).Count|Should Be 0
    }
    It 'abrir y navegar no detecta unidades ni inicia ninguna operación' {
        $diskWindow.Show();[Windows.Forms.Application]::DoEvents()
        1..3|ForEach-Object{$diskWindow.Navigate('Aplicaciones');$diskWindow.Navigate('Mantenimiento')}
        $diskLaunch.Calls|Should Be 0;$diskCleanup.Calls|Should Be 0;$diskPower.Calls|Should Be 0;$diskPower.WriteCalls|Should Be 0
    }
    It 'la pulsación solo abre Windows, sin confirmación, escritura ni cambios de recuperación' {
        $before=$diskEnergy.Snapshot;$before.CanRestore=$true
        Click-DiskWindows;$diskLaunch.Calls|Should Be 1;$diskCleanup.Calls|Should Be 0;$diskConfirm.Calls|Should Be 0;$diskPower.Calls|Should Be 0
        [object]::ReferenceEquals($before,$diskEnergy.Snapshot)|Should Be $true;$diskEnergy.Snapshot.CanRestore|Should Be $true
        @($diskWindow.OwnedForms).Count|Should Be 0;$diskWindow.SelectedSection|Should Be Mantenimiento
    }
    It 'muestra un error breve y permite reintentar ante <Failure>' -TestCases @(@{Failure='Missing'},@{Failure='AccessDenied'},@{Failure='WindowsError'}) {
        param($Failure)
        $diskLaunch.Failure=switch($Failure){Missing{[IO.FileNotFoundException]::new('TEST: ruta privada')}AccessDenied{[UnauthorizedAccessException]::new('TEST: permisos')}WindowsError{[ComponentModel.Win32Exception]::new(5)}}
        Click-DiskWindows;$diskWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Be 'No se pudo abrir Optimizar unidades de Windows.'
        $diskWindow.Controls.Find('disks',$true)[0].Controls.Count|Should Be 3
        $diskLaunch.Failure=$null;Click-DiskWindows;$diskLaunch.Calls|Should Be 2
        $diskWindow.Controls.Find('PreviewStatus',$true)[0].Text|Should Not Be 'No se pudo abrir Optimizar unidades de Windows.'
    }
    It 'bloquea ambos accesos durante otra operación y los recupera al terminar' {
        $diskWindow.RequestPower('Read')|Should Be $true;$diskWindow.Navigate('Mantenimiento')
        foreach($name in @('DiskWindows','CleanupWindows')){$diskWindow.Controls.Find($name,$true)[0].Enabled|Should Be $false}
        Click-DiskWindows;$diskLaunch.Calls|Should Be 0
        $diskPower.Complete((New-Object Juno.Preview.PowerResult));[void]$diskEnergy.Poll()
        [void]$diskWindow.GetType().GetMethod('RefreshTransparencyView',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($diskWindow,@())
        foreach($name in @('DiskWindows','CleanupWindows')){$diskWindow.Controls.Find($name,$true)[0].Enabled|Should Be $true}
        Click-DiskWindows;$diskLaunch.Calls|Should Be 1
    }
    It 'mantiene secciones compactas sin solapamientos en <Width>x<Height>' -TestCases @(@{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}) {
        param($Width,$Height)$diskWindow.ClientSize=New-Object Drawing.Size($Width,$Height);$diskWindow.Show();$diskWindow.PerformLayout();[Windows.Forms.Application]::DoEvents()
        $cleanup=$diskWindow.Controls.Find('cleanup',$true)[0];$section=$diskWindow.Controls.Find('disks',$true)[0]
        ($section.Height -le 190)|Should Be $true;$cleanup.Bounds.IntersectsWith($section.Bounds)|Should Be $false
        foreach($child in $section.Controls){($child.Left -ge 0 -and $child.Right -le $section.ClientSize.Width -and $child.Bottom -le $section.ClientSize.Height)|Should Be $true}
        for($i=0;$i -lt 3;$i++){for($j=$i+1;$j -lt 3;$j++){$section.Controls[$i].Bounds.IntersectsWith($section.Controls[$j].Bounds)|Should Be $false}}
        $diskWindow.Controls.Find('ContentViewport',$true)[0].HorizontalScroll.Visible|Should Be $false
        $section.Controls[2].Height|Should Be $cleanup.Controls[2].Height
    }
    It 'conserva Limpieza y los accesos de las demás secciones' {
        $diskWindow.Controls.Find('CleanupWindows',$true)[0].Text|Should Be 'Abrir limpieza de Windows'
        $diskWindow.Navigate('Aplicaciones');$diskWindow.Controls.Find('startup',$true)[0].Controls.Count|Should Be 3
        $diskWindow.Navigate('Rendimiento');foreach($name in @('VisualWindows','PowerWindows','TransparencyWindows')){@($diskWindow.Controls.Find($name,$true)).Count|Should Be 1}
    }
    It 'resuelve dfrgui oficial según arquitectura sin parámetros, PATH ni runas' {
        $capture=New-Object Juno.Preview.Testing.ConfigurationLaunchCapture;$capture.Disks().Open();$info=$capture.Info
        $folder=[Environment]::GetFolderPath('System');if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess){$folder=Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative'}
        $info.FileName|Should Be (Join-Path $folder 'dfrgui.exe');$info.Arguments|Should BeNullOrEmpty;$info.Verb|Should BeNullOrEmpty;$info.UseShellExecute|Should Be $true
    }
    It 'no conecta el motor de mantenimiento ni duplica información de discos' {
        $source=[IO.File]::ReadAllText((Join-Path $diskUiRoot 'ui/JunoShell.cs'))
        $source|Should Not Match 'Get-DiskVolumes|Get-PhysicalDisk|Start-DiskOptimize|Enable-DiskTrim|Invoke-JunoTrim|chkdsk|Win32_LogicalDisk'
    }
}
