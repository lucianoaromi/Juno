#requires -Version 5.1
# Solo proveedores ficticios: nunca abrir Windows ni cambiar configuraciones en esta suite.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$configurationRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledColorsSettings' -as [type])){
    $files=@(Get-ChildItem (Join-Path $configurationRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function Click-ConfigurationButton($name){$b=$configForm.Controls.Find($name,$true)[0];[void]$b.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($b,@([EventArgs]::Empty))}
Describe 'Accesos oficiales desde energía y transparencia sin cambios de Windows' {
    BeforeEach {
        $script:configPower=New-Object Juno.Preview.Testing.ControlledPower
        $script:configTrans=New-Object Juno.Preview.Testing.ControlledTransparency
        $script:configConfirm=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:configPlans=New-Object Juno.Preview.Testing.ControlledPowerPlans
        $script:configColors=New-Object Juno.Preview.Testing.ControlledColorsSettings
        $script:configEnergy=New-Object Juno.Preview.PowerController($configPower)
        $script:configTransparency=New-Object Juno.Preview.TransparencyController($configTrans)
        [void]$configEnergy.Start('Read',$configConfirm);$p=New-Object Juno.Preview.PowerResult;$p.ActiveName='Equilibrado ficticio';$p.CanApply=$true;$p.CanRestore=$true;$configPower.Complete($p);[void]$configEnergy.Poll();$configPower.Next()
        [void]$configTransparency.Start('Read',$configConfirm);$t=New-Object Juno.Preview.TransparencyResult;$t.State='Disabled';$t.CanChange=$true;$t.CanRestore=$true;$configTrans.Complete($t);[void]$configTransparency.Poll();$configTrans.Next()
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService));$s=New-Object Juno.Preview.StartupController((New-Object Juno.Preview.UnavailableStartupService))
        $script:configForm=New-Object Juno.Preview.ShellForm($configurationRoot,$d,$configTransparency,$configConfirm,$configEnergy,$configPlans,$null,$v,$null,$s,$null,$configColors)
        $configForm.Navigate('Rendimiento')
    }
    AfterEach {$configForm.Dispose()}
    It 'sustituye los detalles por accesos secundarios con el estilo de Efectos visuales' {
        $visual=$configForm.Controls.Find('VisualWindows',$true)[0]
        foreach($name in @('PowerWindows','TransparencyWindows')){
            $b=$configForm.Controls.Find($name,$true)[0];$b.Text|Should Be 'Configurar en Windows';$b.Secondary|Should Be $true;$b.Accent|Should Be $false
            $b.GetType()|Should Be $visual.GetType();$b.Height|Should Be $visual.Height;$b.Font|Should Be $visual.Font
        }
        @($configForm.Controls.Find('PowerDetails',$true)).Count|Should Be 0
        @($configForm.Controls.Find('TransparencyDetails',$true)).Count|Should Be 0
    }
    It 'abre ambos accesos sin consultar, confirmar ni alterar instantáneas o respaldos' {
        $p=$configEnergy.Snapshot;$t=$configTransparency.Snapshot
        Click-ConfigurationButton PowerWindows;Click-ConfigurationButton TransparencyWindows
        $configPlans.Calls|Should Be 1;$configColors.Calls|Should Be 1;$configConfirm.Calls|Should Be 0
        $configPower.Calls|Should Be 1;$configTrans.Calls|Should Be 1;$configPower.WriteCalls|Should Be 0;$configTrans.WriteCalls|Should Be 0
        [object]::ReferenceEquals($p,$configEnergy.Snapshot)|Should Be $true;[object]::ReferenceEquals($t,$configTransparency.Snapshot)|Should Be $true
        $configEnergy.Snapshot.CanRestore|Should Be $true;$configTransparency.Snapshot.CanRestore|Should Be $true
        @($configForm.Controls.Find('PowerApply',$true)).Count|Should Be 1;@($configForm.Controls.Find('PowerRestore',$true)).Count|Should Be 1
        @($configForm.Controls.Find('TransparencyEnable',$true)).Count|Should Be 1;@($configForm.Controls.Find('TransparencyRestore',$true)).Count|Should Be 1
    }
    It 'informa brevemente un fallo en <Button> sin información técnica' -TestCases @(@{Button='PowerWindows';Message='No se pudo abrir Opciones de energía de Windows.'},@{Button='TransparencyWindows';Message='No se pudo abrir Colores de Windows.'}) {
        param($Button,$Message)$configPlans.Fail=$true;$configColors.Fail=$true;Click-ConfigurationButton $Button
        $configForm.Controls.Find('PreviewStatus',$true)[0].Text|Should Be $Message
        $configPower.WriteCalls|Should Be 0;$configTrans.WriteCalls|Should Be 0
    }
    It 'bloquea los accesos durante una operación y permite abrirlos después' {
        $configForm.RequestPower('Read')|Should Be $true
        foreach($name in @('PowerWindows','TransparencyWindows')){$configForm.Controls.Find($name,$true)[0].Enabled|Should Be $false;Click-ConfigurationButton $name}
        $configPlans.Calls|Should Be 0;$configColors.Calls|Should Be 0
        $configPower.Complete((New-Object Juno.Preview.PowerResult));[void]$configEnergy.Poll();$configForm.Navigate('Rendimiento')
        Click-ConfigurationButton PowerWindows;Click-ConfigurationButton TransparencyWindows;$configPlans.Calls|Should Be 1;$configColors.Calls|Should Be 1
    }
    It 'conserva tamaño y alineación de tarjetas y botones al navegar a <Width>' -TestCases @(@{Width=1180},@{Width=940},@{Width=700}) {
        param($Width)$configForm.ClientSize=New-Object Drawing.Size($Width,790);$configForm.Navigate('Rendimiento');$configForm.PerformLayout()
        $sizes=@{};foreach($card in @('power','transparency')){$sizes[$card]=$configForm.Controls.Find($card,$true)[0].Size}
        $configForm.Navigate('Aplicaciones');$configForm.Navigate('Rendimiento');$configForm.PerformLayout()
        foreach($card in @('power','transparency')){$configForm.Controls.Find($card,$true)[0].Size|Should Be $sizes[$card]}
        foreach($name in @('PowerWindows','TransparencyWindows')){
            $b=$configForm.Controls.Find($name,$true)[0];($b.Right -le $b.Parent.ClientSize.Width -and $b.Bottom -le $b.Parent.ClientSize.Height)|Should Be $true
            foreach($other in $b.Parent.Controls){if($other -ne $b){$b.Bounds.IntersectsWith($other.Bounds)|Should Be $false}}
        }
    }
    It 'resuelve control.exe oficial y el panel específico sin PATH ni elevación' {
        $capture=New-Object Juno.Preview.Testing.ConfigurationLaunchCapture;$capture.Power().Open();$info=$capture.Info
        $folder=[Environment]::GetFolderPath('System');if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess){$folder=Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative'}
        $info.FileName|Should Be (Join-Path $folder 'control.exe');$info.Arguments|Should Be '/name Microsoft.PowerOptions';$info.UseShellExecute|Should Be $true;$info.Verb|Should BeNullOrEmpty
    }
    It 'abre únicamente la URI oficial de Colores sin elevación' {
        $capture=New-Object Juno.Preview.Testing.ConfigurationLaunchCapture;$capture.Colors().Open();$info=$capture.Info
        $info.FileName|Should Be 'ms-settings:colors';$info.Arguments|Should BeNullOrEmpty;$info.UseShellExecute|Should Be $true;$info.Verb|Should BeNullOrEmpty
    }
}
