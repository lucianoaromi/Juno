#requires -Version 5.1
# Runspace real con copias privadas, identidad ficticia y ninguna llamada al powercfg real.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$powerBridgeRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledPower' -as [type])) {
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\PowerModel.cs','ui\PowerPlatform.cs','ui\PowerShellPowerService.cs','ui\VisualModel.cs','ui\PowerShellVisualService.cs','ui\JunoShell.cs','tests\Dashboard.TestSupport.cs','tests\Transparency.TestSupport.cs','tests\Power.TestSupport.cs','tests\Visual.TestSupport.cs')|ForEach-Object{Join-Path $powerBridgeRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $powerBridgeRoot 'BackupStore.ps1')
function New-PowerBridgeFixture {
    $folder=Join-Path $TestDrive ('Energía con espacios '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
    $mutex='Local\Juno.Tests.PowerBridge.'+[Guid]::NewGuid().ToString('N')
    foreach($file in @('BackupStore.ps1','UiSupport.ps1','RecoveryOperations.ps1','PowerOperations.ps1','PowerAdapter.ps1')) {
        $source=[IO.File]::ReadAllText((Join-Path $powerBridgeRoot $file)).Replace('Global\JUNO.0.8.State',$mutex)
        [IO.File]::WriteAllText((Join-Path $folder $file),$source,[Text.UTF8Encoding]::new($true))
    }
    $boundary=@'
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Get-JunoMachineFolder {return '__FOLDER__\almacén privado'}
function Get-JunoStorePath([string]$kind,[string]$scope='User') {
    if($kind -cne 'Power' -or $scope -cne 'Machine'){throw 'TEST: ámbito fuera de fixture'}
    return '__FOLDER__\almacén privado\power-backup.json'
}
function Get-JunoMachineLegacy {return $null}
function Initialize-JunoMachineFolder {Assert-JunoLease;[void][IO.Directory]::CreateDirectory('__FOLDER__\almacén privado')}
function Assert-JunoMachineAcl([string]$path) {}
function Write-JunoNewFile([string]$path,[byte[]]$bytes,[switch]$Machine) {
    if(-not $path.StartsWith('__FOLDER__\almacén privado\',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: salida del fixture'}
    $s=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$s.Write($bytes,0,$bytes.Length);$s.Flush($true)}finally{$s.Dispose()}
}
function Read-PowerFake {Get-Content -LiteralPath '__FOLDER__\planes-ficticios.json' -Raw|ConvertFrom-Json}
function Test-JunoAdmin {(Read-PowerFake).Admin}
function Get-JunoPowerCapabilities {(Read-PowerFake).Modern}
function Invoke-PowerCfg([string[]]$arguments) {
    $state=Read-PowerFake
    switch($arguments[0]) {
        '/getactivescheme' {return ('GUID: '+$state.Active+' (Plan ficticio)')}
        '/list' {return (@($state.Plans|ForEach-Object{'Power Scheme GUID: '+$_+' (Plan de prueba)'}) -join "`n")}
        '/duplicatescheme' {Assert-JunoLease;Assert-JunoGuid $arguments[2];$state.Plans+=@($arguments[2]);$state.CreateCalls++}
        '/setactive' {Assert-JunoLease;Assert-JunoGuid $arguments[1];$state.Active=$arguments[1]}
        default {throw 'TEST: powercfg no autorizado'}
    }
    [IO.File]::WriteAllText('__FOLDER__\planes-ficticios.json',($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
}
'@
    [IO.File]::AppendAllText((Join-Path $folder 'PowerAdapter.ps1'),("`r`n"+$boundary.Replace('__FOLDER__',$folder.Replace("'","''"))),[Text.UTF8Encoding]::new($true))
    $state=[pscustomobject]@{Active='381b4222-f694-41f0-9685-ff5bb260df2e';Plans=@('381b4222-f694-41f0-9685-ff5bb260df2e','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c');Admin=$true;Modern=$false;CreateCalls=0}
    [IO.File]::WriteAllText((Join-Path $folder 'planes-ficticios.json'),($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{Root=$folder;Mutex=$mutex;Backup=(Join-Path $folder 'almacén privado\power-backup.json');State=(Join-Path $folder 'planes-ficticios.json')}
}
function Wait-PowerBridge($task){if(-not $task.Wait(15000)){throw 'TEST: puente no terminó'};return $task.GetAwaiter().GetResult()}
Describe 'Puente energía, Machine y mutex privados' {
    BeforeEach {$script:powerFixture=New-PowerBridgeFixture;$script:powerBridge=New-Object Juno.Preview.PowerShellPowerService($powerFixture.Root)}
    AfterEach {$powerBridge.Dispose()}
    It 'consulta sin crear carpeta ni alterar los bytes de los planes' {
        $before=[IO.File]::ReadAllText($powerFixture.State)
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Read',$false));$r.CanApply|Should Be $true;$r.ActiveGuid|Should Not BeNullOrEmpty
        [IO.Directory]::Exists((Split-Path $powerFixture.Backup -Parent))|Should Be $false
        [IO.File]::ReadAllText($powerFixture.State)|Should Be $before
    }
    It 'rechaza escrituras directas sin confirmación' {
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$false))).Outcome|Should Be Cancelled
        [IO.File]::Exists($powerFixture.Backup)|Should Be $false
    }
    It 'activa y restaura por runspace conservando sobre Machine y copias previous' {
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Applied
        $doc=Get-Content -LiteralPath $powerFixture.Backup -Raw|ConvertFrom-Json
        $doc.Format|Should Be 'JUNO.Backup';$doc.Kind|Should Be Power;$doc.Scope|Should Be Machine;$doc.Sid|Should BeNullOrEmpty
        $doc.Data.PowerScheme|Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Restore',$true));$r.Outcome|Should Be Restored;$r.ActiveGuid|Should Be $doc.Data.PowerScheme
        @(Get-ChildItem -LiteralPath (Split-Path $powerFixture.Backup -Parent) -Filter '*.previous.*.json').Count|Should BeGreaterThan 0
        $lease=[Threading.Mutex]::new($false,$powerFixture.Mutex)
        try{$lease.WaitOne(0)|Should Be $true;$lease.ReleaseMutex()}finally{$lease.Dispose()}
    }
    It 'mutex de interfaz antigua bloquea lectura y escritura del nuevo servicio' {
        Enter-JunoLease $powerFixture.Mutex
        try{(Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Busy;[IO.File]::Exists($powerFixture.Backup)|Should Be $false}
        finally{Exit-JunoLease}
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Read',$false))).Outcome|Should Be Read
    }
    It 'sobre de <Field> incorrecto bloquea sin cambiar bytes ni planes' -TestCases @(@{Field='Machine';Value='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Code='MachineMismatch'},@{Field='Scope';Value='User';Code='ScopeMismatch'},@{Field='Sid';Value='TEST-SID';Code='ScopeMismatch'}) {
        param($Field,$Value,$Code)
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Applied
        $doc=Get-Content -LiteralPath $powerFixture.Backup -Raw|ConvertFrom-Json;$doc.$Field=$Value
        [IO.File]::WriteAllText($powerFixture.Backup,($doc|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($powerFixture.Backup);$state=[IO.File]::ReadAllText($powerFixture.State)
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Restore',$true));$r.BackupIssue|Should Be $Code;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
        [IO.File]::ReadAllText($powerFixture.Backup)|Should Be $before;[IO.File]::ReadAllText($powerFixture.State)|Should Be $state
    }
    It 'histórico Machine identificado solicita revisión adicional cancelable' {
        [void][IO.Directory]::CreateDirectory((Split-Path $powerFixture.Backup -Parent))
        $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='Power';Scope='Machine';Sid=$null;Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=[pscustomobject]@{PowerScheme='381b4222-f694-41f0-9685-ff5bb260df2e';CreatedPowerScheme=$null}}
        [IO.File]::WriteAllText($powerFixture.Backup,($doc|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true));$before=[IO.File]::ReadAllText($powerFixture.Backup)
        $task=$powerBridge.ExecuteAsync('Restore',$true);$watch=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $powerBridge.PendingReview -and -not $task.IsCompleted -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 5}
        $review=$powerBridge.PendingReview
        if($null -eq $review){throw ('TEST: falta revisión '+(Wait-PowerBridge $task).Message)}
        $review.Answer($false);(Wait-PowerBridge $task).Outcome|Should Be Cancelled
        [IO.File]::ReadAllText($powerFixture.Backup)|Should Be $before
    }
    It 'tres planes posibles viajan como opciones sin creación y el GUID explícito llega al diario' {
        $state=Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json;$original=$state.Active
        $chosen='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$state.Plans=@($original,$chosen,'bbbbbbbb-cccc-dddd-eeee-ffffffffffff','cccccccc-dddd-eeee-ffff-000000000000')
        [IO.File]::WriteAllText($powerFixture.State,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true));$before=[IO.File]::ReadAllText($powerFixture.State)
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Read',$false));$r.RequiresSelection|Should Be $true;$r.Choices.Length|Should Be 3
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true,$null,$true))).Outcome|Should Be Failed
        [IO.File]::ReadAllText($powerFixture.State)|Should Be $before
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true,$chosen,$false))).Outcome|Should Be Applied
        $doc=Get-Content -LiteralPath $powerFixture.Backup -Raw|ConvertFrom-Json
        $doc.Data.PowerScheme|Should Be $original;$doc.Data.Transaction.Confirmed|Should Be $chosen;$doc.Data.CreatedPowerScheme|Should BeNullOrEmpty
        $hash=Get-FileHash -LiteralPath $powerFixture.Backup
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true,$chosen,$false))).Outcome|Should Be Unchanged
        (Get-FileHash -LiteralPath $powerFixture.Backup).Hash|Should Be $hash.Hash
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Restore',$true))).ActiveGuid|Should Be $original
        (Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json).CreateCalls|Should Be 0
    }
    It 'creación excepcional confirmada se realiza una sola vez a través del puente' {
        $state=Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json;$state.Plans=@($state.Active)
        [IO.File]::WriteAllText($powerFixture.State,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Failed
        [IO.File]::Exists($powerFixture.Backup)|Should Be $false
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true,$null,$true))).Outcome|Should Be Applied
        1..2|ForEach-Object{(Wait-PowerBridge ($powerBridge.ExecuteAsync('Restore',$true))).Outcome|Should Be Restored;(Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Applied}
        $state=Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json;$state.CreateCalls|Should Be 1;$state.Plans.Count|Should Be 2
    }
    It 'dos servicios no crean simultáneamente mientras uno conserva la revisión y el mutex' {
        $state=Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json;$state.Plans=@($state.Active)
        [IO.File]::WriteAllText($powerFixture.State,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
        [void][IO.Directory]::CreateDirectory((Split-Path $powerFixture.Backup -Parent))
        $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='Power';Scope='Machine';Sid=$null;Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=[pscustomobject]@{PowerScheme=$state.Active;CreatedPowerScheme=$null}}
        [IO.File]::WriteAllText($powerFixture.Backup,($doc|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true))
        $task=$powerBridge.ExecuteAsync('Apply',$true,$null,$true);$watch=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $powerBridge.PendingReview -and -not $task.IsCompleted -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 5}
        $review=$powerBridge.PendingReview;if($null -eq $review){throw ('TEST: falta revisión '+(Wait-PowerBridge $task).Message)}
        $other=New-Object Juno.Preview.PowerShellPowerService($powerFixture.Root)
        try{(Wait-PowerBridge ($other.ExecuteAsync('Apply',$true,$null,$true))).Outcome|Should Be Busy}
        finally{$other.Dispose()}
        (Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json).CreateCalls|Should Be 0
        $review.Answer($true);(Wait-PowerBridge $task).Outcome|Should Be Applied
        (Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json).CreateCalls|Should Be 1
    }
    It 'JSON inválido se preserva sin usar previous como sustituto silencioso' {
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true))).Outcome|Should Be Applied
        [IO.File]::WriteAllText($powerFixture.Backup,'{INVALID',[Text.UTF8Encoding]::new($true))
        $state=[IO.File]::ReadAllText($powerFixture.State)
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Restore',$true));$r.BackupIssue|Should Be InvalidBackup
        [IO.File]::ReadAllText($powerFixture.Backup)|Should Be '{INVALID'
        [IO.File]::ReadAllText($powerFixture.State)|Should Be $state
    }
    It 'permisos y Modern Standby se revalidan dentro del servicio antes de escribir' -TestCases @(@{Field='Admin';Value=$false},@{Field='Modern';Value=$true}) {
        param($Field,$Value)
        (Wait-PowerBridge ($powerBridge.ExecuteAsync('Read',$false))).CanApply|Should Be $true
        $state=Get-Content -LiteralPath $powerFixture.State -Raw|ConvertFrom-Json;$state.$Field=$Value
        [IO.File]::WriteAllText($powerFixture.State,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($powerFixture.State)
        $r=Wait-PowerBridge ($powerBridge.ExecuteAsync('Apply',$true));$r.Outcome|Should Be Failed;$r.CanApply|Should Be $false
        [IO.File]::ReadAllText($powerFixture.State)|Should Be $before;[IO.File]::Exists($powerFixture.Backup)|Should Be $false
    }
}
