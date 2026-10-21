#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$uxRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledPower' -as [type])){
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\PowerModel.cs','ui\PowerPlatform.cs','ui\PowerShellPowerService.cs','ui\VisualModel.cs','ui\PowerShellVisualService.cs','ui\StartupModel.cs','ui\StartupControls.cs','ui\PowerShellStartupService.cs','ui\JunoShell.cs','tests\Dashboard.TestSupport.cs','tests\Transparency.TestSupport.cs','tests\Power.TestSupport.cs','tests\Visual.TestSupport.cs','tests\Startup.TestSupport.cs')|ForEach-Object{Join-Path $uxRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function New-UxPower {
    $r=New-Object Juno.Preview.PowerResult
    $r.ActiveName='Equilibrado';$r.ActiveGuid='381b4222-f694-41f0-9685-ff5bb260df2e';$r.CanApply=$true;$r.Administrator=$true;$r.ModernStandby=$false;$r.Availability='Available'
    $r.Message='Diagnóstico ficticio completo';return $r
}
function Set-UxPower($r){
    $uxProvider.Next();$uxController.Start('Read',$uxConfirmation)|Should Be $true
    $uxProvider.Complete($r);$uxController.Poll()|Should Be $true
}
function Find-Ux($form,$name){return ,@($form.Controls.Find($name,$true))}
Describe 'Experiencia compacta con proveedores ficticios' {
    BeforeEach {
        $script:uxProvider=New-Object Juno.Preview.Testing.ControlledPower
        $script:uxController=New-Object Juno.Preview.PowerController($uxProvider)
        $script:uxTrans=New-Object Juno.Preview.Testing.ControlledTransparency
        $script:uxTransparency=New-Object Juno.Preview.TransparencyController($uxTrans)
        $script:uxConfirmation=New-Object Juno.Preview.Testing.ControlledConfirmation;$uxConfirmation.Accept=$true
        $script:uxSelection=New-Object Juno.Preview.Testing.ControlledPowerSelection
        $script:uxForm=New-Object Juno.Preview.ShellForm($uxRoot,(New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))),$uxTransparency,$uxConfirmation,$uxController,(New-Object Juno.Preview.Testing.ControlledPowerPlans),$uxSelection)
    }
    AfterEach {$uxForm.Dispose();$uxProvider.Complete((New-UxPower));$uxTrans.Complete((New-Object Juno.Preview.TransparencyResult))}
    It 'Equilibrado ofrece una acción principal y mantiene GUID y diagnóstico en detalles' {
        $r=New-UxPower;Set-UxPower $r;$uxForm.Navigate('Rendimiento')
        (Find-Ux $uxForm PowerApply)[0].Accent|Should Be $true
        (Find-Ux $uxForm PowerRestore).Count|Should Be 0
        (Find-Ux $uxForm PowerRead).Count|Should Be 0
        (Find-Ux $uxForm PowerState)[0].Text|Should Be 'Plan actual de tu computadora.'
        $details=$uxForm.CreateToolDetails($true)
        try{(Find-Ux $details TechnicalDetails)[0].Text|Should Match $r.ActiveGuid;(Find-Ux $details TechnicalDetails)[0].Text|Should Match $r.Message;(Find-Ux $details PowerRead)[0].Enabled|Should Be $true}finally{$details.Dispose()}
    }
    It 'Alto rendimiento ofrece únicamente restaurar cuando corresponde' -TestCases @(@{Restore=$true},@{Restore=$false}) {
        param($Restore)
        $r=New-UxPower;$r.HighActive=$true;$r.CanApply=$false;$r.CanRestore=$Restore;$r.ActiveName='Alto rendimiento'
        Set-UxPower $r;$uxForm.Navigate('Rendimiento')
        (Find-Ux $uxForm PowerApply).Count|Should Be 0
        (Find-Ux $uxForm PowerRestore).Count|Should Be ([int]$Restore)
        if($Restore){(Find-Ux $uxForm PowerRestore)[0].Accent|Should Be $true}
    }
    It 'transparencia <State> ofrece solo la acción opuesta y conserva el diagnóstico' -TestCases @(@{State='Enabled';Main='TransparencyDisable';Other='TransparencyEnable'},@{State='Disabled';Main='TransparencyEnable';Other='TransparencyDisable'}) {
        param($State,$Main,$Other)
        $r=New-Object Juno.Preview.TransparencyResult;$r.State=$State;$r.CanChange=$true;$r.CanRestore=$true;$r.Message='Registro ficticio: detalle completo'
        $uxTransparency.Start('Read',$uxConfirmation)|Out-Null;$uxTrans.Complete($r);$uxTransparency.Poll()|Out-Null;$uxForm.Navigate('Rendimiento')
        (Find-Ux $uxForm $Main)[0].Accent|Should Be $true;(Find-Ux $uxForm $Other).Count|Should Be 0
        (Find-Ux $uxForm TransparencyRestore)[0].Secondary|Should Be $true
        $details=$uxForm.CreateToolDetails($false)
        try{(Find-Ux $details TechnicalDetails)[0].Text|Should Match $r.Message;(Find-Ux $details TechnicalDetails)[0].Text|Should Match 'HKCU'}finally{$details.Dispose()}
    }
    It 'problema <Kind> se resume sin perder evidencia ni habilitar cambios' -TestCases @(
        @{Kind='Admin';Text='Necesitás permisos de administrador'},@{Kind='Backup';Text='El respaldo no es compatible'},@{Kind='Pending';Text='Hay un cambio pendiente de revisión'},@{Kind='Conflict';Text='cambió fuera de JUNO'},@{Kind='Failed';Text='No se pudo completar el cambio'}) {
        param($Kind,$Text)
        $r=New-UxPower;$r.CanApply=$false;$r.Message='Evidencia técnica conservada'
        switch($Kind){Admin{$r.Administrator=$false} Backup{$r.BackupIssue='MachineMismatch';$r.Outcome='Failed'} Pending{$r.Pending=$true} Conflict{$r.Outcome='Conflict'} Failed{$r.Outcome='Failed'}}
        Set-UxPower $r;$uxForm.Navigate('Rendimiento')
        (Find-Ux $uxForm PowerState)[0].Text|Should Match $Text
        (Find-Ux $uxForm PowerApply)[0].Enabled|Should Be $false;(Find-Ux $uxForm PowerApply)[0].Accent|Should Be $false
        [Juno.Preview.ToolPresentation]::PowerDetails($uxController)|Should Match $r.Message
        $uxForm.RequestPower('Apply')|Should Be $false;$uxProvider.WriteCalls|Should Be 0
    }
    It 'confirmación habitual es breve y la recuperación conserva su revisión completa' {
        Set-UxPower (New-UxPower);$uxProvider.Next();$uxForm.RequestPower('Apply')|Should Be $true
        $uxConfirmation.Calls|Should Be 1;$uxConfirmation.LastMessage.Length|Should BeLessThan 160
        $uxConfirmation.LastMessage|Should Not Match 'GUID|Machine|HKLM|diario'
        $dialog=[Juno.Preview.TransparencyConfirmation]::CreateDialog($uxConfirmation.LastTitle,$uxConfirmation.LastMessage)
        $review=[Juno.Preview.TransparencyConfirmation]::CreateDialog('JUNO · Revisar recuperación de energía','Actual: información técnica histórica completa')
        try{$dialog.Height|Should BeLessThan 300;$dialog.AcceptButton.Text|Should Be 'Cancelar';$review.Height|Should BeGreaterThan 400;$review.AcceptButton.Text|Should Be 'Cancelar'}finally{$dialog.Dispose();$review.Dispose()}
    }
    It 'selección explícita verificada se reutiliza tras restaurar sin crear y con nueva confirmación' {
        $r=New-UxPower;$r.RequiresSelection=$true;$guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid=$guid;Name='Plan elegido'})
        Set-UxPower $r;$uxProvider.Next();$uxSelection.Selected=$guid
        $uxForm.RequestPower('Apply')|Should Be $true
        $done=New-UxPower;$done.ActiveGuid=$guid;$done.SelectionActive=$true;$done.CanApply=$false;$done.CanRestore=$true;$done.Outcome='Applied'
        $uxProvider.Complete($done);$uxController.Poll()|Out-Null;$uxController.RememberedGuid|Should Be $guid
        # Actualizar mientras el elegido sigue activo no debe olvidar una elección válida.
        $done.RequiresSelection=$true;$done.Choices=$r.Choices;$done.Outcome='Read';Set-UxPower $done
        $uxController.RememberedGuid|Should Be $guid;$uxController.CanStart('Apply')|Should Be $false
        $uxProvider.Next();$uxForm.RequestPower('Restore')|Should Be $true;$r.Outcome='Restored';$uxProvider.Complete($r);$uxController.Poll()|Out-Null
        $uxSelection.Selected=$null;$uxProvider.Next();$uxForm.RequestPower('Apply')|Should Be $true
        $uxSelection.Calls|Should Be 1;$uxConfirmation.Calls|Should Be 3;$uxProvider.LastTarget|Should Be $guid;$uxProvider.LastCreate|Should Be $false
    }
    It 'preferencia se invalida por <Reason> y exige volver a elegir' -TestCases @(@{Reason='Missing'},@{Reason='Renamed'},@{Reason='Conflict'},@{Reason='Pending'},@{Reason='Admin'},@{Reason='Standby'},@{Reason='Backup'},@{Reason='Historical'},@{Reason='Failed'}) {
        param($Reason)
        $r=New-UxPower;$r.RequiresSelection=$true;$guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid=$guid;Name='Plan elegido'})
        Set-UxPower $r;$uxProvider.Next();$uxSelection.Selected=$guid;$uxForm.RequestPower('Apply')|Out-Null
        $done=New-UxPower;$done.ActiveGuid=$guid;$done.Outcome='Applied';$done.SelectionActive=$true;$done.CanApply=$false
        $uxProvider.Complete($done);$uxController.Poll()|Out-Null;$uxController.RememberedGuid|Should Be $guid
        switch($Reason){Missing{$r.Choices=@()} Renamed{$r.Choices[0].Name='Otro nombre'} Conflict{$r.Outcome='Conflict'} Pending{$r.Pending=$true} Admin{$r.Administrator=$false} Standby{$r.ModernStandby=$true} Backup{$r.BackupIssue='MachineMismatch'} Historical{$r.Historical=$true} Failed{$r.Outcome='Failed'}}
        Set-UxPower $r;$uxController.RememberedGuid|Should BeNullOrEmpty
        $clean=New-UxPower;$clean.RequiresSelection=$true;$clean.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid=$guid;Name='Plan elegido'});Set-UxPower $clean
        $uxSelection.Selected=$null;$uxForm.RequestPower('Apply')|Should Be $false;$uxSelection.Calls|Should Be 2;$uxProvider.WriteCalls|Should Be 1
    }
    It 'cancelar confirmación no recuerda una elección ni envía escritura' {
        $r=New-UxPower;$r.RequiresSelection=$true;$r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Name='Elegido'})
        Set-UxPower $r;$uxSelection.Selected=$r.Choices[0].Guid;$uxConfirmation.Accept=$false
        $uxForm.RequestPower('Apply')|Should Be $false;$uxController.RememberedGuid|Should BeNullOrEmpty;$uxProvider.WriteCalls|Should Be 0
    }
    It 'tarjetas compactas con restauración conservan botones dentro de sus límites al navegar en <Width>' -TestCases @(@{Width=1180},@{Width=940},@{Width=700}) {
        param($Width)
        $r=New-UxPower;$r.CanRestore=$true;Set-UxPower $r
        $tr=New-Object Juno.Preview.TransparencyResult;$tr.State='Disabled';$tr.CanChange=$true;$tr.CanRestore=$true
        $uxTransparency.Start('Read',$uxConfirmation)|Out-Null;$uxTrans.Complete($tr);$uxTransparency.Poll()|Out-Null
        $uxForm.ClientSize=New-Object Drawing.Size($Width,650)
        foreach($section in [Juno.Preview.ShellForm]::Sections){$uxForm.Navigate($section)};$uxForm.Navigate('Rendimiento');$uxForm.PerformLayout()
        foreach($name in @('PowerApply','PowerRestore','PowerDetails','TransparencyEnable','TransparencyRestore','TransparencyDetails')){
            $button=(Find-Ux $uxForm $name)[0]
            ($button.Right -le $button.Parent.ClientSize.Width)|Should Be $true
            ($button.Bottom -le $button.Parent.ClientSize.Height)|Should Be $true
            foreach($other in $button.Parent.Controls){if($other -ne $button){$button.Bounds.IntersectsWith($other.Bounds)|Should Be $false}}
        }
        (Find-Ux $uxForm TransparencyEnable)[0].Accent|Should Be $true;$uxProvider.WriteCalls|Should Be 0;$uxTrans.WriteCalls|Should Be 0
    }
    It 'cerrar y comenzar otra sesión no conserva una preferencia anterior' {
        $r=New-UxPower;$r.RequiresSelection=$true;$guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid=$guid;Name='Plan elegido'})
        Set-UxPower $r;$uxProvider.Next();$uxSelection.Selected=$guid;$uxForm.RequestPower('Apply')|Out-Null
        $done=New-UxPower;$done.Outcome='Applied';$done.ActiveGuid=$guid;$uxProvider.Complete($done);$uxController.Poll()|Out-Null;$uxController.RememberedGuid|Should Be $guid
        $otherProvider=New-Object Juno.Preview.Testing.ControlledPower;$other=New-Object Juno.Preview.PowerController($otherProvider)
        try{$other.RememberedGuid|Should BeNullOrEmpty;$other.Start('Read',$uxConfirmation)|Out-Null;$otherProvider.Complete($r);$other.Poll()|Out-Null;$uxSelection.Selected=$null;$other.Start('Apply',$uxConfirmation,$uxSelection)|Should Be $false;$otherProvider.WriteCalls|Should Be 0}finally{$other.Dispose()}
    }
    It 'la falta del plan original sigue siendo visible aunque la consulta sea válida' {
        $r=New-UxPower;$r.Message='El plan original no existe; restauración bloqueada. Se conserva el respaldo.';Set-UxPower $r
        [Juno.Preview.ToolPresentation]::PowerMessage($uxController)|Should Match 'El plan anterior ya no está disponible'
        [Juno.Preview.ToolPresentation]::PowerDetails($uxController)|Should Match $r.Message
    }
}
