#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$visualBridgeRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledVisual' -as [type])){
    $files=@(Get-ChildItem (Join-Path $visualBridgeRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@('Dashboard.TestSupport.cs','Transparency.TestSupport.cs','Power.TestSupport.cs','Visual.TestSupport.cs'|ForEach-Object{Join-Path $PSScriptRoot $_})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $visualBridgeRoot 'BackupStore.ps1')
function New-VisualBridge {
    $folder=Join-Path $TestDrive ('Efectos ficticios '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
    $mutex='Local\Juno.Tests.VisualBridge.'+[Guid]::NewGuid().ToString('N')
    foreach($file in @('BackupStore.ps1','RecoveryOperations.ps1','TransparencyOperations.ps1','VisualEffectsOperations.ps1','VisualInterop.ps1','VisualAdapter.ps1')){
        $source=[IO.File]::ReadAllText((Join-Path $visualBridgeRoot $file)).Replace('Global\JUNO.0.8.State',$mutex)
        [IO.File]::WriteAllText((Join-Path $folder $file),$source,[Text.UTF8Encoding]::new($true))
    }
    $effects=[ordered]@{};foreach($name in @('UIEffects','ClientAreaAnimation','MenuAnimation','ComboBoxAnimation','ListSmoothScrolling','MenuFade','SelectionFade','ToolTipAnimation','ToolTipFade','CursorShadow','DropShadow','MinimizeAnimation','FontSmoothing','DragFullWindows')){$effects[$name]=$true}
    $registry=@(Get-JunoVisualTargets|Where-Object{$_[1] -ne 'EnableTransparency'}|ForEach-Object{[pscustomobject]@{Key=$_[0];Name=$_[1];Exists=$true;Kind=$_[2];Value=$(if($_[2] -eq 'Binary'){'AAAAAAAAAAA='}elseif($_[1] -eq 'FontSmoothing'){'2'}else{'1'})}})
    $state=[pscustomobject]@{Effects=[pscustomobject]$effects;Registry=$registry}
    [IO.File]::WriteAllText((Join-Path $folder 'estado-ficticio.json'),($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
    $literal=$folder.Replace("'","''")
    $barriers=@'
function Initialize-JunoVisualInterop {}
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Get-JunoStorePath([string]$kind,[string]$scope='User'){
    if($kind -cne 'General' -or $scope -cne 'User'){throw 'TEST: ámbito prohibido'}
    return '__FOLDER__\Datos ficticios\backup.json'
}
function Get-CurrentEffects {return (Get-Content -LiteralPath '__FOLDER__\estado-ficticio.json' -Raw|ConvertFrom-Json).Effects}
function Get-VisualRegistrySnapshot {return ,(Get-Content -LiteralPath '__FOLDER__\estado-ficticio.json' -Raw|ConvertFrom-Json).Registry}
function Set-JunoEffects($effects){
    Assert-JunoLease;$state=Get-Content -LiteralPath '__FOLDER__\estado-ficticio.json' -Raw|ConvertFrom-Json
    foreach($p in $effects.PSObject.Properties){$state.Effects.($p.Name)=$p.Value}
    [IO.File]::WriteAllText('__FOLDER__\estado-ficticio.json',($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
}
function Restore-VisualRegistry($snapshots){
    Assert-JunoLease;$state=Get-Content -LiteralPath '__FOLDER__\estado-ficticio.json' -Raw|ConvertFrom-Json
    foreach($r in $snapshots){for($i=0;$i -lt $state.Registry.Count;$i++){if($state.Registry[$i].Name -ceq $r.Name){$state.Registry[$i]=$r;break}}}
    [IO.File]::WriteAllText('__FOLDER__\estado-ficticio.json',($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
}
'@
    [IO.File]::AppendAllText((Join-Path $folder 'VisualAdapter.ps1'),("`r`n"+$barriers.Replace('__FOLDER__',$literal)),[Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{Root=$folder;Mutex=$mutex;Backup=(Join-Path $folder 'Datos ficticios\backup.json');Original=$state}
}
function Wait-VisualBridge($task){if(-not $task.Wait(15000)){throw 'TEST: no terminó el puente'};return $task.GetAwaiter().GetResult()}
function New-VisualHistorical($fixture,[string]$sid='TEST-SID'){
    [void][IO.Directory]::CreateDirectory((Split-Path $fixture.Backup -Parent))
    $data=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$fixture.Original.Effects;VisualRegistry=$fixture.Original.Registry;TransparencyBackup=$null}
    $document=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid=$sid;Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=$data}
    [IO.File]::WriteAllText($fixture.Backup,($document|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
}
Describe 'Puente visual real con API, Registro, almacén y mutex ficticios' {
    BeforeEach {$script:vFixture=New-VisualBridge;$script:vBridge=New-Object Juno.Preview.PowerShellVisualService($vFixture.Root)}
    AfterEach {$vBridge.Dispose()}
    It 'lee sin crear respaldos y rechaza escritura no confirmada antes de abrir el almacén' {
        $r=Wait-VisualBridge ($vBridge.ExecuteAsync('Read',$false));$r.State|Should Be Custom;$r.CanApply|Should Be $true
        [IO.Directory]::Exists((Split-Path $vFixture.Backup -Parent))|Should Be $false
        (Wait-VisualBridge ($vBridge.ExecuteAsync('Maximum',$false))).Outcome|Should Be Cancelled
        [IO.File]::Exists($vFixture.Backup)|Should Be $false
    }
    It 'aplica, verifica, restaura y libera mutex en el mismo hilo sin cambiar formato' {
        (Wait-VisualBridge ($vBridge.ExecuteAsync('Quality',$true))).State|Should Be Quality
        $saved=Get-Content -LiteralPath $vFixture.Backup -Raw|ConvertFrom-Json
        $saved.Kind|Should Be General;$saved.Scope|Should Be User;$saved.Sid|Should Be TEST-SID;$saved.Data.Journal.Visual.Phase|Should Be Applied
        (Wait-VisualBridge ($vBridge.ExecuteAsync('Restore',$true))).Outcome|Should Be Restored
        $after=Get-Content -LiteralPath (Join-Path $vFixture.Root 'estado-ficticio.json') -Raw|ConvertFrom-Json
        Test-JunoEqual $after $vFixture.Original|Should Be $true
        $lease=[Threading.Mutex]::new($false,$vFixture.Mutex);try{$lease.WaitOne(0)|Should Be $true;$lease.ReleaseMutex()}finally{$lease.Dispose()}
    }
    It 'mutex de otra interfaz impide abrir el respaldo' {
        Enter-JunoLease $vFixture.Mutex
        try{(Wait-VisualBridge ($vBridge.ExecuteAsync('Quality',$true))).Outcome|Should Be Busy;[IO.File]::Exists($vFixture.Backup)|Should Be $false}finally{Exit-JunoLease}
    }
    It 'histórico pide una revisión y cancelar conserva bytes; otra solicitud no entra' {
        New-VisualHistorical $vFixture;$before=[IO.File]::ReadAllBytes($vFixture.Backup)
        $task=$vBridge.ExecuteAsync('Restore',$true);$watch=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $vBridge.PendingReview -and -not $task.IsCompleted -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
        $review=$vBridge.PendingReview;if($null -eq $review){throw 'TEST: falta revisión histórica'}
        $review.Message|Should Match 'Actual:'
        (Wait-VisualBridge ($vBridge.ExecuteAsync('Read',$false))).Outcome|Should Be Busy
        $other=New-Object Juno.Preview.PowerShellVisualService($vFixture.Root)
        try{(Wait-VisualBridge ($other.ExecuteAsync('Read',$false))).Outcome|Should Be Busy}finally{$other.Dispose()}
        $review.Answer($false);(Wait-VisualBridge $task).Outcome|Should Be Cancelled
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($vFixture.Backup))|Should Be ([Convert]::ToBase64String($before))
    }
    It 'aceptar histórico guarda copia anterior y restaura con verificación' {
        New-VisualHistorical $vFixture;$before=[IO.File]::ReadAllText($vFixture.Backup)
        $task=$vBridge.ExecuteAsync('Restore',$true);$watch=[Diagnostics.Stopwatch]::StartNew()
        while($null -eq $vBridge.PendingReview -and -not $task.IsCompleted -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
        if($null -eq $vBridge.PendingReview){throw 'TEST: falta revisión'};$vBridge.PendingReview.Answer($true)
        (Wait-VisualBridge $task).Outcome|Should Be Restored
        @(Get-ChildItem -LiteralPath (Split-Path $vFixture.Backup -Parent) -Filter '*.previous.*.json'|Where-Object{[IO.File]::ReadAllText($_.FullName) -ceq $before}).Count|Should BeGreaterThan 0
    }
    It 'respaldo de otra identidad bloquea sin revelar SID ajeno ni tocar archivos' {
        New-VisualHistorical $vFixture 'OTHER-PRIVATE-SID';$before=[IO.File]::ReadAllText($vFixture.Backup)
        $r=Wait-VisualBridge ($vBridge.ExecuteAsync('Quality',$true));$r.BackupIssue|Should Be UserMismatch;$r.Message|Should Not Match 'OTHER-PRIVATE-SID';$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
        [IO.File]::ReadAllText($vFixture.Backup)|Should Be $before
    }
    It 'la arquitectura no utiliza el dashboard ni cancelación forzada de escritura' {
        $source=[IO.File]::ReadAllText((Join-Path $visualBridgeRoot 'ui\PowerShellVisualService.cs'))
        $source|Should Match 'PSThreadOptions.ReuseThread';$source|Should Match 'ApartmentState.STA'
        $source|Should Not Match 'ProcessDashboardQuery|\.Kill\(|\.Stop\(|CancelAfter|runas|WaitForExit'
        $adapter=[IO.File]::ReadAllText((Join-Path $visualBridgeRoot 'VisualAdapter.ps1'))
        $adapter|Should Not Match 'SetValue\(|DeleteValue\(|SystemParametersInfo|Write-JunoStore'
        $adapter|Should Match 'finally \{if\(\$owned\)\{Exit-JunoLease\}\}'
    }
    It 'la declaración nativa existente conserva ANIMATIONINFO de ocho bytes en este host' {
        . (Join-Path $visualBridgeRoot 'VisualInterop.ps1');Initialize-JunoVisualInterop
        [Runtime.InteropServices.Marshal]::SizeOf([type][WinVisualEffects+ANIMATIONINFO])|Should Be 8
        [Runtime.InteropServices.Marshal]::OffsetOf([type][WinVisualEffects+ANIMATIONINFO],'iMinAnimate').ToInt32()|Should Be 4
    }
}
