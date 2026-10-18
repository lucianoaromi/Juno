#requires -Version 5.1
# Consultas simuladas y trabajadores privados. Ninguna optimizacion o escritura de Windows.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$dashboardTestRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledQuery' -as [type])) {
    if('Juno.Preview.ShellForm' -as [type]){throw 'Ejecuta Dashboard.Tests.ps1 en un proceso PowerShell nuevo para compilar sus fixtures junto al shell.'}
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\JunoShell.cs','tests\Dashboard.TestSupport.cs','tests\Transparency.TestSupport.cs')|ForEach-Object{Join-Path $dashboardTestRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
function New-DashboardSnapshot {
    $s=New-Object Juno.Preview.DashboardSnapshot
    $s.CompletedUtc=[DateTime]::UtcNow
    $spec=@{
        os=@{Caption='Windows de prueba Pro';Version='10.0.fixture';Build='fixture';Architecture='64 bits'}
        cpu=@{Name='CPU de prueba';Cores='6';Logical='12'}
        ram=@{Installed='17179869184';Usable='16106127360';Available='8053063680'}
        disk=@{Drive='X:\';Total='107374182400';Available='26843545600'}
        power=@{Name='Plan de prueba'}
    }
    foreach($key in $spec.Keys){$r=New-Object Juno.Preview.DashboardReading;$r.Key=$key;foreach($field in $spec[$key].Keys){$r.Fields.Add($field,$spec[$key][$field])};$s.Readings.Add($key,$r)}
    return $s
}
function Get-DashboardControls($control){foreach($child in $control.Controls){$child;Get-DashboardControls $child}}
function Wait-DashboardUi($form){[Windows.Forms.Application]::DoEvents();$clock=[Diagnostics.Stopwatch]::StartNew();while($form.Dashboard.IsBusy -and $clock.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5};if($form.Dashboard.IsBusy){throw 'La UI no recibio el resultado'}}
function Start-DashboardFixture([string]$body,[int]$timeout=3000) {
    $path=Join-Path $TestDrive ('Consulta con espacios '+[Guid]::NewGuid().ToString('N')+'.ps1')
    [IO.File]::WriteAllText($path,$body,(New-Object Text.UTF8Encoding($true)))
    $query=New-Object Juno.Preview.ProcessDashboardQuery((Get-Process -Id $PID).Path,$path,$timeout)
    return $query
}
function Wait-DashboardTask($task){if(-not $task.Wait(10000)){throw 'Timeout del fixture privado'};return $task.GetAwaiter().GetResult()}

Describe 'Datos del sistema y presentacion sin valores inventados' {
    It 'recoge cada categoria a traves del contrato de lectura' -TestCases @(@{Key='os'},@{Key='cpu'},@{Key='ram'},@{Key='disk'},@{Key='power'}) {
        param($Key)
        $api=New-Object Juno.Preview.Testing.FixtureReadApi;$api.Fields.Add('Name','Fixture')
        $r=[Juno.Preview.DashboardCollector]::Read($Key,$api)
        $r.Key|Should Be $Key;$r.Fields['Name']|Should Be 'Fixture';$r.Failure|Should BeNullOrEmpty;$api.Calls|Should Be 1
    }
    It 'conserva el fallo de proveedor en lugar de devolver ceros' {
        $api=New-Object Juno.Preview.Testing.FixtureReadApi;$api.Fail=$true
        $r=[Juno.Preview.DashboardCollector]::Read('cpu',$api)
        $r.Fields.Count|Should Be 0;$r.Failure|Should Not BeNullOrEmpty
        $s=New-Object Juno.Preview.DashboardSnapshot;$s.Readings.Add('cpu',$r)
        $c=[Juno.Preview.DashboardPresentation]::Card('cpu',$s,$false)
        $c.Value|Should Be 'No disponible';$c.Detail|Should Not Match ': 0'
    }
    It 'una instantanea ausente muestra No disponible en las cinco tarjetas' {
        $s=New-Object Juno.Preview.DashboardSnapshot
        foreach($key in [Juno.Preview.DashboardWire]::Keys){$c=[Juno.Preview.DashboardPresentation]::Card($key,$s,$false);$c.Value|Should Be 'No disponible';$c.State|Should Be 'No disponible'}
    }
    It 'formatea bytes de forma independiente a la arquitectura y distingue cero real' {
        [Juno.Preview.DashboardPresentation]::Bytes($null)|Should Be 'No disponible'
        [Juno.Preview.DashboardPresentation]::Bytes(0)|Should Be '0 B'
        [Juno.Preview.DashboardPresentation]::Bytes([UInt64]17179869184)|Should Be '16 GiB'
        [Juno.Preview.DashboardPresentation]::Bytes([UInt64]1649267441664)|Should Be '1,5 TiB'
    }
    It 'calcula uso de <Total>/<Free> de forma validada' -TestCases @(
        @{Total='100';Free='25';Expected='75 %'},@{Total='100';Free='0';Expected='100 %'},
        @{Total='100';Free='100';Expected='0 %'},@{Total='0';Free='0';Expected='No disponible'},
        @{Total='100';Free='101';Expected='No disponible'},@{Total='-1';Free='5';Expected='No disponible'},
        @{Total='';Free='5';Expected='No disponible'},@{Total='18446744073709551615';Free='0';Expected='100 %'}
    ) {param($Total,$Free,$Expected)
        $percent=[Juno.Preview.DashboardPresentation]::UsedPercent([Juno.Preview.DashboardPresentation]::Number($Total),[Juno.Preview.DashboardPresentation]::Number($Free))
        [Juno.Preview.DashboardPresentation]::Percent($percent)|Should Be $Expected
    }
    It 'diferencia RAM instalada y utilizable para calcular su utilizacion' {
        $c=[Juno.Preview.DashboardPresentation]::Card('ram',(New-DashboardSnapshot),$false)
        $c.Value|Should Be '16 GiB';$c.Detail|Should Match '50 % de 15 GiB';$c.Detail|Should Match '7,5 GiB'
    }
    It 'informa unidad del sistema y porcentaje del volumen sin inferir SSD ni HDD' {
        $c=[Juno.Preview.DashboardPresentation]::Card('disk',(New-DashboardSnapshot),$false)
        $c.Detail|Should Match 'X:\\';$c.Detail|Should Match '75 %';$c.Detail|Should Not Match 'SSD|HDD'
    }
    It 'rechaza campos numericos malformados o inconsistentes' {
        $s=New-DashboardSnapshot;$s.Readings['cpu'].Fields['Cores']='0';$s.Readings['ram'].Fields['Available']='999999999999999'
        [Juno.Preview.DashboardPresentation]::Card('cpu',$s,$false).Detail|Should Match 'físicos: No disponible'
        $c=[Juno.Preview.DashboardPresentation]::Card('ram',$s,$false)
        $c.Detail|Should Match 'Disponible: No disponible';$c.Detail|Should Match 'Uso: No disponible'
    }
    It 'presenta el nombre real del plan y desconoce los planes ausentes' {
        [Juno.Preview.DashboardPresentation]::Card('power',(New-DashboardSnapshot),$false).Value|Should Be 'Plan de prueba'
        $c=[Juno.Preview.DashboardPresentation]::Card('power',(New-Object Juno.Preview.DashboardSnapshot),$false)
        $c.Value|Should Be 'No disponible';$c.Detail|Should Match 'desconocido'
    }
    It 'valida el protocolo y conserva Unicode' {
        $s=New-DashboardSnapshot;$r=$s.Readings['power'];$r.Fields['Name']='Equilibrado · energía'
        $round=[Juno.Preview.DashboardWire]::Decode([Juno.Preview.DashboardWire]::Encode($r));$round.Fields['Name']|Should Be 'Equilibrado · energía'
        {[Juno.Preview.DashboardWire]::Decode('{"Key":"unknown","Fields":{}}')}|Should Throw
        {[Juno.Preview.DashboardWire]::Decode('not json')}|Should Throw
        {[Juno.Preview.DashboardWire]::Decode(('x'*17000))}|Should Throw
    }
}

Describe 'Estado de dashboard y ciclo de UI sin consultas reales' {
    BeforeEach {
        $script:query=New-Object Juno.Preview.Testing.ControlledQuery
        $script:controller=New-Object Juno.Preview.DashboardController($query)
        $script:form=New-Object Juno.Preview.ShellForm($dashboardTestRoot,$controller)
    }
    AfterEach {$form.Dispose();$query.Complete((New-DashboardSnapshot))}
    It 'construir controles y navegar no inicia consultas' {
        foreach($section in [Juno.Preview.ShellForm]::Sections){$form.Navigate($section)}
        $query.Calls|Should Be 0
    }
    It 'refresca manualmente una vez y descarta solicitudes superpuestas' {
        $form.RefreshInformation()|Should Be $true
        $form.RefreshInformation()|Should Be $false;$query.Calls|Should Be 1
        $controller.Poll()|Should Be $false
        $query.Complete((New-DashboardSnapshot));$controller.Poll()|Should Be $true
        $query.Next();$form.RefreshInformation()|Should Be $true;$query.Calls|Should Be 2
    }
    It 'permite navegar durante carga y aplica el resultado en el hilo UI' {
        [Windows.Forms.Control]::CheckForIllegalCrossThreadCalls=$true
        $form.Show();[Windows.Forms.Application]::DoEvents()
        $query.Calls|Should Be 1;$controller.IsBusy|Should Be $true
        $refresh=@(Get-DashboardControls $form|Where-Object{$_.Name -eq 'RefreshInformation'})[0]
        $refresh.Enabled|Should Be $false;$refresh.Text|Should Match 'Actualizando información'
        $form.Navigate('Aplicaciones');$form.SelectedSection|Should Be 'Aplicaciones'
        $query.CompleteInBackground((New-DashboardSnapshot));Wait-DashboardUi $form
        $form.SelectedSection|Should Be 'Aplicaciones'
        $form.Navigate('Inicio');$text=(Get-DashboardControls $form).Text -join ' '
        $text|Should Match 'CPU de prueba';$text|Should Match 'Lectura completada'
        $query.Calls|Should Be 1
    }
    It 'mantiene cache al volver y habilita refresco despues del resultado' {
        $form.Show();$query.Complete((New-DashboardSnapshot));Wait-DashboardUi $form
        1..3|ForEach-Object{$form.Navigate('Rendimiento');$form.Navigate('Inicio')}
        $query.Calls|Should Be 1
        $button=@(Get-DashboardControls $form|Where-Object{$_.Name -eq 'RefreshInformation'})[0]
        $button.Enabled|Should Be $true
        $form.Navigate('Rendimiento');((Get-DashboardControls $form).Text -join ' ')|Should Match 'Configuración de rendimiento'
    }
    It 'identifica datos anteriores al refrescar y los reemplaza aunque la lectura falle' {
        $controller.Refresh()|Should Be $true;$query.Complete((New-DashboardSnapshot));[void]$controller.Poll();$query.Next()
        $controller.Refresh()|Should Be $true
        [Juno.Preview.DashboardPresentation]::Status($controller)|Should Match 'lectura anterior'
        $query.Fail();$controller.Poll()|Should Be $true
        $controller.Snapshot.Readings.Count|Should Be 0
        [Juno.Preview.DashboardPresentation]::Status($controller)|Should Match 'parcial'
    }
    It 'al cerrar cancela la tarea y no deja callbacks que toquen controles' {
        [void]$form.RefreshInformation();$form.Dispose()
        $controller.IsDisposed|Should Be $true;$query.LastToken.IsCancellationRequested|Should Be $true
        $query.CompleteInBackground((New-DashboardSnapshot));Start-Sleep -Milliseconds 100
        $controller.Poll()|Should Be $false;$form.ResourcesReleased|Should Be $true
    }
    It 'presenta los cinco estados previstos sin habilitar herramientas reales' {
        $expected=@('Disponible','Requiere administrador','No compatible','Estado desconocido','Pendiente de integración');$i=0
        foreach($state in [Enum]::GetValues([Juno.Preview.ToolAvailability])){[Juno.Preview.ToolStateText]::Describe($state)|Should Be $expected[$i];$i++}
        foreach($section in @('Rendimiento','Aplicaciones','Mantenimiento','Restauración')){
            $form.Navigate($section);$states=@(Get-DashboardControls $form|Where-Object{$_.Name -eq 'ToolState'})
            foreach($state in $states){$state.Text|Should Be 'Pendiente de integración'}
            foreach($action in @(Get-DashboardControls $form|Where-Object{$_.Name -eq 'ToolAction'})){$action.Enabled|Should Be $false}
        }
    }
}

Describe 'Trabajador privado, timeout, cancelacion y liberacion' {
    It 'lee respuestas desde una ruta con espacios sin modificar archivos de usuario' {
        $q=Start-DashboardFixture "[Console]::OutputEncoding=New-Object Text.UTF8Encoding(`$false);[Console]::Out.WriteLine('{`"Key`":`"power`",`"Fields`":{`"Name`":`"Plan de prueba`"}}')"
        $result=Wait-DashboardTask ($q.FetchAsync([Threading.CancellationToken]::None))
        $result.Readings['power'].Fields['Name']|Should Be 'Plan de prueba';$result.Failure|Should BeNullOrEmpty;$q.IsActive|Should Be $false
    }
    It 'conserva lecturas parciales y termina su propio trabajador al exceder el plazo' {
        # Incluir el arranque frio de PowerShell x86 bajo carga; sigue venciendo antes del sleep.
        $q=Start-DashboardFixture "[Console]::Out.WriteLine('{`"Key`":`"power`",`"Fields`":{`"Name`":`"Fixture`"}}');[Console]::Out.Flush();Start-Sleep -Seconds 20" 6000
        $clock=[Diagnostics.Stopwatch]::StartNew();$task=$q.FetchAsync([Threading.CancellationToken]::None)
        $duplicate=Wait-DashboardTask ($q.FetchAsync([Threading.CancellationToken]::None));$duplicate.Failure|Should Not BeNullOrEmpty
        $result=Wait-DashboardTask $task
        $result.TimedOut|Should Be $true;($clock.ElapsedMilliseconds -lt 11000)|Should Be $true
        $result.Readings.ContainsKey('power')|Should Be $true;$q.IsActive|Should Be $false
    }
    It 'cancela su trabajador sin quedar activo y admite una consulta posterior' {
        $q=Start-DashboardFixture 'Start-Sleep -Seconds 20' 5000
        $cts=New-Object Threading.CancellationTokenSource
        try{$task=$q.FetchAsync($cts.Token);Start-Sleep -Milliseconds 300;$cts.Cancel();$result=Wait-DashboardTask $task;$q.IsActive|Should Be $false;$result.Failure|Should Match 'cancelada'}finally{$cts.Dispose()}
        $cts=New-Object Threading.CancellationTokenSource
        try{$cts.Cancel();$result=Wait-DashboardTask ($q.FetchAsync($cts.Token));$q.IsActive|Should Be $false}finally{$cts.Dispose()}
    }
    It 'convierte salida invalida, duplicados y error del proceso en estado parcial' {
        $q=Start-DashboardFixture "[Console]::Out.WriteLine('invalido');[Console]::Out.WriteLine('{`"Key`":`"power`",`"Fields`":{}}');[Console]::Out.WriteLine('{`"Key`":`"power`",`"Fields`":{}}');exit 7"
        $result=Wait-DashboardTask ($q.FetchAsync([Threading.CancellationToken]::None))
        $result.Failure|Should Not BeNullOrEmpty;$result.Readings.Count|Should Be 1;$q.IsActive|Should Be $false
    }
    It 'trata trabajador ausente como error y libera el estado de ejecucion' {
        $q=New-Object Juno.Preview.ProcessDashboardQuery((Get-Process -Id $PID).Path,(Join-Path $TestDrive 'ausente.ps1'))
        $result=Wait-DashboardTask ($q.FetchAsync([Threading.CancellationToken]::None));$result.Failure|Should Not BeNullOrEmpty;$result.Readings.Count|Should Be 0;$q.IsActive|Should Be $false
    }
    It 'el proveedor solo declara consultas oficiales y no contiene escritores' {
        $source=[IO.File]::ReadAllText((Join-Path $dashboardTestRoot 'ui\WindowsSystemSource.cs'))
        $source|Should Match 'SELECT Caption,Version,BuildNumber,OSArchitecture FROM Win32_OperatingSystem'
        $source|Should Match 'SELECT Name,NumberOfCores,NumberOfLogicalProcessors FROM Win32_Processor'
        $source|Should Match 'GlobalMemoryStatusEx|GetPhysicallyInstalledSystemMemory|PowerGetActiveScheme|PowerReadFriendlyName|TotalFreeSpace'
        $source|Should Not Match 'PowerSet|RegistryKey|OpenSubKey|SetValue|InvokeMethod|\.Put\(|File.Write|File.Delete|Directory.Create|Process.Start'
        $worker=[IO.File]::ReadAllText((Join-Path $dashboardTestRoot 'Juno-DashboardWorker.ps1'))
        $worker|Should Not Match 'Set-ItemProperty|Remove-Item|Stop-Process|Start-Process|powercfg|fsutil|defrag|BackupStore|RecoveryOperations'
    }
}
