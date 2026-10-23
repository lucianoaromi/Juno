#requires -Version 5.1
# Servicio, adaptador, motor, almacén y mutex reales; Windows reemplazado por JSON privado.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$startupBridgeRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledStartup' -as [type])){
    $files=@(Get-ChildItem (Join-Path $startupBridgeRoot 'ui') -Filter *.cs|ForEach-Object{$_.FullName})+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object{$_.FullName})
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $startupBridgeRoot 'BackupStore.ps1')
function New-StartupBridgeEntry([string]$name='Spotify',[string]$scope='Usuario',[string]$command='"C:\Ficticio\Spotify.exe" /inicio'){
    $hive=if($scope -eq 'Equipo'){'LocalMachine'}else{'CurrentUser'}
    $view=if($scope -eq 'Equipo' -and [Environment]::Is64BitOperatingSystem){'Registry64'}else{'Default'}
    $run='Software\Microsoft\Windows\CurrentVersion\Run'
    [pscustomobject]@{Id="$hive|$view|$run|$name";Name=$name;State='Activo';Scope=$scope;Origin='Registro ficticio';Publisher='Ficticio';Command=$command;Recommendation='Opcional';SourceType='Registro';SourceHive=$hive;SourceView=$view;SourceKey=$run;SourceValue=$name;ApprovalHive=$hive;ApprovalView=$view;ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';ApprovalValue=$name;Editable=$true}
}
function New-StartupBridgeFixture {
    $folder=Join-Path $TestDrive ('Inicio ficticio '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
    $mutex='Local\Juno.Tests.Startup.'+[Guid]::NewGuid().ToString('N')
    foreach($file in @('BackupStore.ps1','StartupOperations.ps1','StartupAdapter.ps1')){
        $source=[IO.File]::ReadAllText((Join-Path $startupBridgeRoot $file)).Replace('Global\JUNO.0.8.State',$mutex)
        if($file -eq 'StartupOperations.ps1'){$source=$source.Substring($source.IndexOf('function Open-StartupRegKey('))}
        [IO.File]::WriteAllText((Join-Path $folder $file),$source,[Text.UTF8Encoding]::new($true))
    }
    $boundaries=@'
function Read-StartupFake {Get-Content -LiteralPath '__ROOT__\estado.json' -Raw|ConvertFrom-Json}
function Save-StartupFake($state){[IO.File]::WriteAllText('__ROOT__\estado.json',($state|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true))}
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Test-JunoAdmin {(Read-StartupFake).Admin}
function Get-JunoStartupFolder([string]$hive){'__ROOT__\Inicio'}
function Get-JunoMachineFolder {'__ROOT__\datos'}
function Get-JunoMachineLegacy {return $null}
function Initialize-JunoMachineFolder {Assert-JunoLease;[void][IO.Directory]::CreateDirectory('__ROOT__\datos')}
function Assert-JunoMachineAcl([string]$path) {if(-not $path.StartsWith('__ROOT__\datos',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: ACL fuera de fixture'}}
function Get-JunoStorePath([string]$kind,[string]$scope='User'){
    if($kind -cne 'Startup' -or $scope -cnotin @('User','Machine')){throw 'TEST: almacén fuera de fixture'}
    return '__ROOT__\datos\'+$scope+'.json'
}
function Write-JunoNewFile([string]$path,[byte[]]$bytes,[switch]$Machine){
    if(-not $path.StartsWith('__ROOT__\datos\',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: escritura fuera de fixture'}
    $s=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$s.Write($bytes,0,$bytes.Length);$s.Flush($true)}finally{$s.Dispose()}
}
function Get-StartupEntries {
    $state=Read-StartupFake
    if($state.Delay -gt 0){Start-Sleep -Milliseconds $state.Delay}
    if($state.ReadFailure){throw 'SIMULATED inventory failure'}
    foreach($entry in $state.Entries){$entry.Editable=($entry.ApprovalHive -eq 'CurrentUser' -or $state.Admin);$entry}
}
function Read-StartupRegValue([string]$hive,[string]$view,[string]$path,[string]$name){
    $state=Read-StartupFake
    if($path -ceq 'Software\Microsoft\Windows\CurrentVersion\Run'){
        $found=@($state.Entries|Where-Object{$_.SourceHive -ceq $hive -and $_.SourceView -ceq $view -and $_.SourceValue -ceq $name})
        if($found.Count -eq 1){return [pscustomobject]@{Exists=$true;Kind='String';Data=$found[0].Command}}
        return [pscustomobject]@{Exists=$false;Kind=$null;Data=$null}
    }
    if(-not $path.StartsWith('Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\',[StringComparison]::Ordinal)){throw 'TEST: lectura fuera de StartupApproved'}
    $property=$state.Values.PSObject.Properties["$hive|$view|$path|$name"]
    if($null -eq $property){return [pscustomobject]@{Exists=$false;Kind=$null;Data=$null}}
    [pscustomobject]@{Exists=$true;Kind=$property.Value.Kind;Data=$(if($property.Value.Kind -eq 'Binary'){[Convert]::FromBase64String($property.Value.Data)}else{$property.Value.Data})}
}
function Write-StartupFakeValue([string]$target,$data,[bool]$remove){
    Assert-JunoLease;$state=Read-StartupFake;$state.Writes++
    $fault=($state.Writes -eq $state.FaultAt)
    if($fault -and $state.Fault -eq 'Before'){Save-StartupFake $state;throw 'SIMULATED failure before write'}
    if(-not ($fault -and $state.Fault -eq 'Ignore')){
        if($remove){$state.Values.PSObject.Properties.Remove($target)}
        else{Add-Member -InputObject $state.Values NoteProperty $target ([pscustomobject]@{Kind='Binary';Data=[Convert]::ToBase64String([byte[]]$data)}) -Force}
    }
    Save-StartupFake $state
    if($fault -and $state.Fault -eq 'After'){throw 'SIMULATED failure after write'}
}
function Open-StartupRegKey([string]$hive,[string]$view,[string]$path,[bool]$write,[bool]$create){
    if(-not $write -or -not $path.StartsWith('Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\',[StringComparison]::Ordinal)){throw 'TEST: Registro real prohibido'}
    $key=[pscustomobject]@{Prefix="$hive|$view|$path|"}
    $key|Add-Member ScriptMethod SetValue {param($name,$data,$kind) Write-StartupFakeValue ($this.Prefix+$name) $data $false}
    $key|Add-Member ScriptMethod DeleteValue {param($name,$throwIfMissing) Write-StartupFakeValue ($this.Prefix+$name) $null $true}
    $key|Add-Member ScriptMethod Close {}
    return $key
}
$script:StartupStableSet=${function:Set-StartupState}
function Set-StartupState($entry,[bool]$enable,[string]$expectedFingerprint=$null,$expectedApproval=$null){
    $state=Read-StartupFake
    if($state.Race -eq 'Source'){$state.Entries[0].Command='"C:\Ficticio\CambioTardio.exe"';Save-StartupFake $state}
    if($state.Race -eq 'Approval'){
        $bytes=New-Object byte[] 12;$bytes[0]=6
        Add-Member -InputObject $state.Values NoteProperty ("$($entry.ApprovalHive)|$($entry.ApprovalView)|$($entry.ApprovalKey)|$($entry.ApprovalValue)") ([pscustomobject]@{Kind='Binary';Data=[Convert]::ToBase64String($bytes)}) -Force
        Save-StartupFake $state
    }
    & $script:StartupStableSet $entry $enable $expectedFingerprint $expectedApproval
}
'@
    [IO.File]::AppendAllText((Join-Path $folder 'StartupAdapter.ps1'),("`r`n"+$boundaries.Replace('__ROOT__',$folder.Replace("'","''"))),[Text.UTF8Encoding]::new($true))
    $state=[pscustomobject]@{Entries=@((New-StartupBridgeEntry));Values=[pscustomobject]@{};Writes=0;Admin=$false;Fault='';FaultAt=0;Delay=0;ReadFailure=$false;Race=''}
    $fixture=[pscustomobject]@{Root=$folder;Mutex=$mutex;State=(Join-Path $folder 'estado.json');Backup=(Join-Path $folder 'datos\User.json');Machine=(Join-Path $folder 'datos\Machine.json')}
    Save-StartupBridgeFixture $fixture $state
    return $fixture
}
function Save-StartupBridgeFixture($fixture,$state){[IO.File]::WriteAllText($fixture.State,($state|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($true))}
function Read-StartupBridgeFixture($fixture){Get-Content -LiteralPath $fixture.State -Raw|ConvertFrom-Json}
function Set-StartupBridgeFlag($fixture,$entry,[byte]$flag){
    $state=Read-StartupBridgeFixture $fixture;$bytes=New-Object byte[] 12;$bytes[0]=$flag
    Add-Member -InputObject $state.Values NoteProperty ("$($entry.ApprovalHive)|$($entry.ApprovalView)|$($entry.ApprovalKey)|$($entry.ApprovalValue)") ([pscustomobject]@{Kind='Binary';Data=[Convert]::ToBase64String($bytes)}) -Force
    Save-StartupBridgeFixture $fixture $state
}
function Wait-StartupBridge($task){if(-not $task.Wait(20000)){throw 'TEST: puente no terminó'};return $task.GetAwaiter().GetResult()}
function Invoke-StartupBridge($action='Read',$selected=$null,[bool]$confirmed=$true){
    if($null -eq $selected){return (Wait-StartupBridge ($sBridge.ExecuteAsync($action,'','','',$confirmed)))}
    Wait-StartupBridge ($sBridge.ExecuteAsync($action,$selected.Id,$selected.Fingerprint,$selected.ApprovalToken,$confirmed))
}
function Disable-StartupBridge { $read=Invoke-StartupBridge;Invoke-StartupBridge Disable $read.Entries[0] }
function Set-StartupBridgeDocument($document){[IO.File]::WriteAllText($sFixture.Backup,($document|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($true))}

Describe 'Inicio: puente real con Windows completamente ficticio' {
    BeforeEach {$script:sFixture=New-StartupBridgeFixture;$script:sBridge=New-Object Juno.Preview.PowerShellStartupService($sFixture.Root)}
    AfterEach {$sBridge.Dispose()}
    It 'consulta sin crear respaldos ni cambiar el inventario' {
        $before=[IO.File]::ReadAllText($sFixture.State);$r=Invoke-StartupBridge
        $r.Entries.Count|Should Be 1;$r.Entries[0].State|Should Be Enabled;$r.Entries[0].CanChange|Should Be $true
        [IO.File]::ReadAllText($sFixture.State)|Should Be $before;[IO.File]::Exists($sFixture.Backup)|Should Be $false
    }
    It 'inventario vacío es válido y no inventa aplicaciones' {$s=Read-StartupBridgeFixture $sFixture;$s.Entries=@();Save-StartupBridgeFixture $sFixture $s;(Invoke-StartupBridge).Entries.Count|Should Be 0}
    It 'distingue usuario y equipo sin solicitar elevación' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@(New-StartupBridgeEntry 'Otra' 'Equipo');Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge;$machine=@($r.Entries|Where-Object Scope -eq Equipo)[0];$machine.CanChange|Should Be $false;$machine.Reason|Should Match 'administrador'
        (Invoke-StartupBridge Disable $machine).Outcome|Should Be Blocked;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 0
    }
    It 'entrada desactivada permite activar' {Set-StartupBridgeFlag $sFixture (Read-StartupBridgeFixture $sFixture).Entries[0] 3;$r=Invoke-StartupBridge;$r.Entries[0].State|Should Be Disabled;(Invoke-StartupBridge Enable $r.Entries[0]).Outcome|Should Be Applied}
    It 'estado no reconocido no puede modificarse' {Set-StartupBridgeFlag $sFixture (Read-StartupBridgeFixture $sFixture).Entries[0] 99;$r=Invoke-StartupBridge;$r.Entries[0].State|Should Be Unknown;$r.Entries[0].CanChange|Should Be $false}
    It 'protege componentes importantes por evidencia <Command>' -TestCases @(
        @{Command='"C:\Ficticio\antivirus.exe"'},@{Command='"C:\Ficticio\nvidia-driver.exe"'},@{Command='%windir%\System32\SecurityHealthSystray.exe'}
    ) {param($Command)$s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].Command=$Command;Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge;$r.Entries[0].CanChange|Should Be $false;(Invoke-StartupBridge Disable $r.Entries[0]).Outcome|Should Be Blocked}
    It 'nombre opcional con comando desconocido exige revisar' {$s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].Command='"C:\Desconocido\aplicacion.exe"';Save-StartupBridgeFixture $sFixture $s;(Invoke-StartupBridge).Entries[0].NeedsReview|Should Be $true}
    It 'sincronización y respaldo incluyen advertencia breve <Command>' -TestCases @(@{Command='"C:\Ficticio\OneDrive.exe"'},@{Command='"C:\Ficticio\Backup.exe"'}) {
        param($Command)$s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].Command=$Command;Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge;$r.Entries[0].NeedsReview|Should Be $true;$r.Entries[0].Reason|Should Match 'respaldos|sincronización'
    }
    It 'cancelación sin confirmación no abre respaldo ni escribe' {$r=Invoke-StartupBridge;(Invoke-StartupBridge Disable $r.Entries[0] $false).Outcome|Should Be Cancelled;[IO.File]::Exists($sFixture.Backup)|Should Be $false}
    It 'desactiva solo una entrada y preserva comando y las demás' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@(New-StartupBridgeEntry 'Discord' 'Usuario' '"C:\Ficticio\Discord.exe"');Save-StartupBridgeFixture $sFixture $s
        $before=($s.Entries|ConvertTo-Json -Depth 8 -Compress);$r=Invoke-StartupBridge;$one=@($r.Entries|Where-Object Name -eq Spotify)[0];$after=Invoke-StartupBridge Disable $one
        $after.Outcome|Should Be Applied;$after.Message|Should Match 'mediante esta entrada';$after.Message|Should Not Match 'segundo plano'
        ($after.Entries|Where-Object Name -eq Discord).State|Should Be Enabled;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 1
        ((Read-StartupBridgeFixture $sFixture).Entries|ConvertTo-Json -Depth 8 -Compress)|Should Be $before
    }
    It 'alternar conserva la ausencia original y restaura sin eliminar Run' {
        $r=Disable-StartupBridge;$r.CanRestore|Should Be $true;$r.Entries[0].State|Should Be Disabled
        $r=Invoke-StartupBridge Enable $r.Entries[0];$r.Outcome|Should Be Applied
        $doc=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$doc.Data.Entries[0].OriginalExists|Should Be $false;$doc.Kind|Should Be Startup;$doc.Scope|Should Be User
        (Invoke-StartupBridge Restore).Outcome|Should Be Restored;(Read-StartupBridgeFixture $sFixture).Entries.Count|Should Be 1
        @(Get-ChildItem (Split-Path $sFixture.Backup) -Filter '*.previous.*.json').Count|Should BeGreaterThan 0
    }
    It 'restaura bytes preexistentes exactos' {Set-StartupBridgeFlag $sFixture (Read-StartupBridgeFixture $sFixture).Entries[0] 6;$before=(Read-StartupBridgeFixture $sFixture).Values|ConvertTo-Json -Compress;[void](Disable-StartupBridge);(Invoke-StartupBridge Restore).Outcome|Should Be Restored;((Read-StartupBridgeFixture $sFixture).Values|ConvertTo-Json -Compress)|Should Be $before}
    It 'fallo <Mode> conserva original y permite recuperar' -TestCases @(@{Mode='Before'},@{Mode='After'},@{Mode='Ignore'}) {
        param($Mode)$s=Read-StartupBridgeFixture $sFixture;$s.Fault=$Mode;$s.FaultAt=1;Save-StartupBridgeFixture $sFixture $s
        $r=Disable-StartupBridge;$r.Outcome|Should Be Failed;$r.Pending|Should Be $true;$r.CanRestore|Should Be $true
        $doc=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$doc.Data.Entries[0].OriginalExists|Should Be $false
        (Invoke-StartupBridge Restore).Outcome|Should Be Restored
        (Disable-StartupBridge).Outcome|Should Be Applied
    }
    It 'restauración parcial conserva solo el original conflictivo y reintenta' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@(New-StartupBridgeEntry 'Discord' 'Usuario' '"C:\Ficticio\Discord.exe"');Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge;[void](Invoke-StartupBridge Disable $r.Entries[0]);$r=Invoke-StartupBridge;$next=@($r.Entries|Where-Object State -eq Enabled)[0];[void](Invoke-StartupBridge Disable $next)
        $saved=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].Command='"C:\Ficticio\Cambiada.exe"';Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge Restore;$r.Outcome|Should Be Partial;$r.Remaining|Should Be 1
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].Command='"C:\Ficticio\Spotify.exe" /inicio';Save-StartupBridgeFixture $sFixture $s
        (Invoke-StartupBridge Restore).Outcome|Should Be Restored
    }
    It 'detecta cambios externos aunque mantengan el estado lógico' {
        $r=Disable-StartupBridge;Set-StartupBridgeFlag $sFixture (Read-StartupBridgeFixture $sFixture).Entries[0] 7
        $r=Invoke-StartupBridge;$r.Entries[0].CanChange|Should Be $false;$before=[IO.File]::ReadAllText($sFixture.State)
        (Invoke-StartupBridge Restore).Outcome|Should Be Partial;[IO.File]::ReadAllText($sFixture.State)|Should Be $before
    }
    It 'selección obsoleta por <Change> no escribe ni crea respaldo' -TestCases @(@{Change='Command'},@{Change='Deleted'},@{Change='State'}) {
        param($Change)$r=Invoke-StartupBridge;$one=$r.Entries[0];$s=Read-StartupBridgeFixture $sFixture
        switch($Change){'Command'{$s.Entries[0].Command='"C:\Ficticio\Otra.exe"'} 'Deleted'{$s.Entries=@()} 'State'{Set-StartupBridgeFlag $sFixture $s.Entries[0] 3;$s=Read-StartupBridgeFixture $sFixture}}
        Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge Disable $one;$r.Outcome|Should Match 'Conflict|Blocked';(Read-StartupBridgeFixture $sFixture).Writes|Should Be 0;[IO.File]::Exists($sFixture.Backup)|Should Be $false
    }
    It 'una entrada eliminada no se recrea al restaurar' {[void](Disable-StartupBridge);$s=Read-StartupBridgeFixture $sFixture;$s.Entries=@();Save-StartupBridgeFixture $sFixture $s;(Invoke-StartupBridge Restore).Outcome|Should Be Partial;(Read-StartupBridgeFixture $sFixture).Entries.Count|Should Be 0}
    It 'restaura histórico válido sin perder identidad ni evidencia' {
        [void](Disable-StartupBridge);$doc=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$data=$doc.Data;$data.Entries[0].PSObject.Properties.Remove('Transaction');Set-StartupBridgeDocument $data
        (Invoke-StartupBridge).Historical|Should Be $true;(Invoke-StartupBridge Restore).Outcome|Should Be Restored
        @(Get-ChildItem (Split-Path $sFixture.Backup) -Filter '*.history.*.json').Count|Should BeGreaterThan 0
    }
    It 'respaldo incompatible <Field> bloquea sin reemplazar' -TestCases @(
        @{Field='Sid';Value='OTRO-SID'},@{Field='Machine';Value='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'},@{Field='Version';Value=99},@{Field='Scope';Value='Machine'}
    ) {
        param($Field,$Value)[void](Disable-StartupBridge);$doc=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$doc.$Field=$Value;Set-StartupBridgeDocument $doc;$before=[IO.File]::ReadAllText($sFixture.Backup)
        $r=Invoke-StartupBridge;$r.BackupIssue|Should Not BeNullOrEmpty;$r.CanRestore|Should Be $false;$r.Entries[0].CanChange|Should Be $false
        (Invoke-StartupBridge Restore).Outcome|Should Be Failed;[IO.File]::ReadAllText($sFixture.Backup)|Should Be $before
    }
    It 'diario incompatible conserva bytes sin operaciones' {[void](Disable-StartupBridge);$doc=Get-Content -LiteralPath $sFixture.Backup -Raw|ConvertFrom-Json;$doc.Data.Entries[0].Transaction.Version=2;Set-StartupBridgeDocument $doc;(Invoke-StartupBridge).BackupIssue|Should Be InvalidBackup}
    It 'mutex de otra interfaz bloquea sin abrir almacén y admite reintento' {
        Enter-JunoLease $sFixture.Mutex
        try{(Invoke-StartupBridge).Outcome|Should Be Busy;[IO.File]::Exists($sFixture.Backup)|Should Be $false}finally{Exit-JunoLease}
        (Invoke-StartupBridge).Outcome|Should Be Read
    }
    It 'el servicio rechaza consultas simultáneas mientras enumera' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Delay=500;Save-StartupBridgeFixture $sFixture $s
        $task=$sBridge.ExecuteAsync('Read','','','',$false)
        (Invoke-StartupBridge).Outcome|Should Be Busy;(Wait-StartupBridge $task).Outcome|Should Be Read
    }
    It 'repetir una solicitud obsoleta no duplica la escritura' {$r=Invoke-StartupBridge;$one=$r.Entries[0];[void](Invoke-StartupBridge Disable $one);(Invoke-StartupBridge Disable $one).Outcome|Should Be Conflict;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 1}
    It 'IDs duplicados se bloquean y nombres duplicados mantienen identidad por ámbito' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@(New-StartupBridgeEntry 'Spotify' 'Equipo');Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge;$r.Entries.Count|Should Be 2
        $user=@($r.Entries|Where-Object Scope -eq Usuario)[0];(Invoke-StartupBridge Disable $user).Outcome|Should Be Applied
        $s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@($s.Entries[0]);Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge;@($r.Entries|Where-Object CanChange -eq $true).Count|Should Be 0
    }
    It 'administrador simulado escribe y restaura solo el ámbito de equipo' {
        $s=Read-StartupBridgeFixture $sFixture;$s.Admin=$true;$s.Entries=@(New-StartupBridgeEntry 'Spotify' 'Equipo');Save-StartupBridgeFixture $sFixture $s
        (Disable-StartupBridge).Outcome|Should Be Applied;$doc=Get-Content -LiteralPath $sFixture.Machine -Raw|ConvertFrom-Json;$doc.Scope|Should Be Machine;$doc.Sid|Should BeNullOrEmpty
        (Invoke-StartupBridge Restore).Outcome|Should Be Restored
    }
    It 'error de lectura se informa y libera recursos para reintentar' {$s=Read-StartupBridgeFixture $sFixture;$s.ReadFailure=$true;Save-StartupBridgeFixture $sFixture $s;(Invoke-StartupBridge).Outcome|Should Be Failed;$s.ReadFailure=$false;Save-StartupBridgeFixture $sFixture $s;(Invoke-StartupBridge).Outcome|Should Be Read}
    It 'la arquitectura comparte motor, lease y parámetros sin GUI antigua ni escritores C#' {
        $source=[IO.File]::ReadAllText((Join-Path $startupBridgeRoot 'ui\PowerShellStartupService.cs'));$source|Should Match 'PSThreadOptions.ReuseThread';$source|Should Match 'StartupOperations.ps1';$source|Should Not Match 'Inicio.ps1|Show-StartupManager|Dashboard|\.Stop\(|\.Kill\(|runas|SetValue\('
        $adapter=[IO.File]::ReadAllText((Join-Path $startupBridgeRoot 'StartupAdapter.ps1'));$adapter|Should Match 'Set-StartupState';$adapter|Should Match 'Restore-StartupState';$adapter|Should Not Match 'SetValue\(|DeleteValue\(|Write-JunoStore|Remove-Item|Stop-Process'
    }
    It 'guarda tardía <Race> rechaza cambios entre adaptador y motor antes de respaldar' -TestCases @(@{Race='Source'},@{Race='Approval'}) {
        param($Race)$r=Invoke-StartupBridge;$s=Read-StartupBridgeFixture $sFixture;$s.Race=$Race;Save-StartupBridgeFixture $sFixture $s
        (Invoke-StartupBridge Disable $r.Entries[0]).Outcome|Should Be Conflict;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 0;[IO.File]::Exists($sFixture.Backup)|Should Be $false
    }
    It 'estado ya solicitado no escribe ni crea respaldo' {$r=Invoke-StartupBridge;(Invoke-StartupBridge Enable $r.Entries[0]).Outcome|Should Be Unchanged;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 0;[IO.File]::Exists($sFixture.Backup)|Should Be $false}
    It 'pendiente de otra entrada bloquea nuevos cambios aunque desaparezca <Deleted>' -TestCases @(@{Deleted=$false},@{Deleted=$true}) {
        param($Deleted)$s=Read-StartupBridgeFixture $sFixture;$s.Entries+=@(New-StartupBridgeEntry 'Discord' 'Usuario' '"C:\Ficticio\Discord.exe"');$s.Fault='Before';$s.FaultAt=1;Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge;$one=@($r.Entries|Where-Object Name -eq Spotify)[0];[void](Invoke-StartupBridge Disable $one)
        if($Deleted){$s=Read-StartupBridgeFixture $sFixture;$s.Entries=@($s.Entries|Where-Object Name -ne Spotify);Save-StartupBridgeFixture $sFixture $s}
        $r=Invoke-StartupBridge;$r.Pending|Should Be $true;$other=@($r.Entries|Where-Object Name -eq Discord)[0];$other.CanChange|Should Be $false
        $writes=(Read-StartupBridgeFixture $sFixture).Writes;(Invoke-StartupBridge Disable $other).Outcome|Should Be Blocked;(Read-StartupBridgeFixture $sFixture).Writes|Should Be $writes
    }
    It 'destino de Registro ajeno se bloquea antes de tocarlo' {$s=Read-StartupBridgeFixture $sFixture;$s.Entries[0].ApprovalKey='Software\DestinoAjeno';Save-StartupBridgeFixture $sFixture $s;$r=Invoke-StartupBridge;$r.Entries[0].CanChange|Should Be $false;(Invoke-StartupBridge Disable $r.Entries[0]).Outcome|Should Be Blocked;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 0}
    It 'tipo de StartupApproved no binario queda no disponible' {
        $s=Read-StartupBridgeFixture $sFixture;$e=$s.Entries[0];Add-Member -InputObject $s.Values NoteProperty ("$($e.ApprovalHive)|$($e.ApprovalView)|$($e.ApprovalKey)|$($e.ApprovalValue)") ([pscustomobject]@{Kind='String';Data='ajeno'});Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge;$r.Entries[0].State|Should Be Unknown;$r.Entries[0].CanChange|Should Be $false
    }
    It 'carpeta Inicio conserva el archivo original en aplicación y restauración' {
        $folder=Join-Path $sFixture.Root 'Inicio';[void][IO.Directory]::CreateDirectory($folder);$file=Join-Path $folder 'Prueba.lnk';[IO.File]::WriteAllText($file,'ARCHIVO FICTICIO; NO EJECUTAR')
        $s=Read-StartupBridgeFixture $sFixture;$e=$s.Entries[0];$e.Id='Archivo|'+$file;$e.SourceType='Archivo';$e.SourceHive='';$e.SourceView='';$e.SourceKey=$file;$e.SourceValue='Prueba.lnk';$e.Command=$file;$e.ApprovalValue='Prueba.lnk';$e.ApprovalView=if([Environment]::Is64BitOperatingSystem){'Registry64'}else{'Default'};$e.ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder';Save-StartupBridgeFixture $sFixture $s
        $r=Invoke-StartupBridge;$r.Entries[0].NeedsReview|Should Be $true;(Invoke-StartupBridge Disable $r.Entries[0]).Outcome|Should Be Applied;(Invoke-StartupBridge Restore).Outcome|Should Be Restored
        [IO.File]::ReadAllText($file)|Should Be 'ARCHIVO FICTICIO; NO EJECUTAR'
    }
    It 'principal ausente con previous bloquea en lugar de asumir respaldo vacío' {
        [void](Disable-StartupBridge);[IO.File]::Move($sFixture.Backup,($sFixture.Backup+'.previous.ficticio.json'));$r=Invoke-StartupBridge;$r.BackupIssue|Should Be InvalidBackup;$r.CanRestore|Should Be $false;$r.Entries[0].CanChange|Should Be $false
    }
    It 'vista Run32 del equipo conserva la aprobación nativa en este host' {
        if(-not [Environment]::Is64BitOperatingSystem){return}
        $s=Read-StartupBridgeFixture $sFixture;$s.Admin=$true;$e=New-StartupBridgeEntry 'Spotify' 'Equipo';$e.SourceView='Registry32';$e.Id="LocalMachine|Registry32|$($e.SourceKey)|Spotify";$e.ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32';$s.Entries=@($e);Save-StartupBridgeFixture $sFixture $s
        (Disable-StartupBridge).Outcome|Should Be Applied;$d=Get-Content -LiteralPath $sFixture.Machine -Raw|ConvertFrom-Json;$d.Data.Entries[0].ApprovalView|Should Be Registry64;(Invoke-StartupBridge Restore).Outcome|Should Be Restored
    }
    It 'recuperación general restaura el respaldo sin volver a administrar entradas desde Aplicaciones' {
        [void](Disable-StartupBridge)
        # Extend only this private fixture to exercise the central bridge against the stable startup engine/store.
        foreach($name in @('RecoveryOperations','UiSupport','PowerOperations','TransparencyOperations','VisualInterop','BackgroundInventory','PermisosUsuario','PermisosSegundoPlano','PowerAdapter','TransparencyAdapter','RecoveryAdapter')){
            Copy-Item -LiteralPath (Join-Path $startupBridgeRoot ($name+'.ps1')) -Destination (Join-Path $sFixture.Root ($name+'.ps1'))
        }
        [IO.File]::AppendAllText((Join-Path $sFixture.Root 'RecoveryAdapter.ps1'),"`r`nfunction Get-BPUAccount {'TEST-SID'}`r`nfunction Get-TransparencySnapshot {throw 'TEST: native query forbidden'}`r`n",[Text.UTF8Encoding]::new($true))
        $central=New-Object Juno.Preview.RecoveryController((New-Object Juno.Preview.PowerShellRecoveryService($sFixture.Root)))
        $controller=New-Object Juno.Preview.StartupController($sBridge);$confirm=New-Object Juno.Preview.Testing.ControlledConfirmation;$confirm.Accept=$true
        $d=New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery));$t=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.UnavailableTransparencyService));$p=New-Object Juno.Preview.PowerController((New-Object Juno.Preview.UnavailablePowerService));$v=New-Object Juno.Preview.VisualController((New-Object Juno.Preview.UnavailableVisualService));$settings=New-Object Juno.Preview.Testing.ControlledStartupSettings
        $window=New-Object Juno.Preview.ShellForm($startupBridgeRoot,$d,$t,$confirm,$p,$null,$null,$v,$null,$controller,$settings,$null,$null,$null,$central)
        try{
            $window.Navigate('Aplicaciones');$window.Controls.Find('startup',$true)[0].Controls.Count|Should Be 3;$controller.HasRequested|Should Be $false
            $backup=[IO.File]::ReadAllText($sFixture.Backup);(Read-StartupBridgeFixture $sFixture).Writes|Should Be 1
            $window.Navigate('Restauración');$button=$window.Controls.Find('RecoveryRead',$true)[0]
            [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
            $watch=[Diagnostics.Stopwatch]::StartNew();while($central.IsBusy -and $watch.ElapsedMilliseconds -lt 20000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
            $central.IsBusy|Should Be $false;$central.Find('Startup').CanRestore|Should Be $true;$controller.HasRequested|Should Be $false
            [IO.File]::ReadAllText($sFixture.Backup)|Should Be $backup;(Read-StartupBridgeFixture $sFixture).Writes|Should Be 1
            $window.Navigate('Restauración');$button=$window.Controls.Find('StartupRestore',$true)[0]
            [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
            $watch.Restart();while(($central.IsBusy -or $controller.IsBusy) -and $watch.ElapsedMilliseconds -lt 20000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
            $central.IsBusy|Should Be $false;$controller.IsBusy|Should Be $false;$central.Snapshot.Outcome|Should Be Restored;$confirm.Calls|Should Be 1
            @((Read-StartupBridgeFixture $sFixture).Values.PSObject.Properties).Count|Should Be 0
        }finally{$window.Dispose()}
    }
}
