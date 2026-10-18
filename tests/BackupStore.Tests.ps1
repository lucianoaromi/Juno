#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$storeRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $storeRoot 'BackupStore.ps1')
# Pester 3.4 conserva algunos mocks hasta finalizar Describe: base real explicita por caso.
$realNewFile=(Get-Command Write-JunoNewFile).ScriptBlock.ToString()
. ([scriptblock]::Create('function Invoke-StoreRealNewFile {'+$realNewFile+'}'))
$realReplace=(Get-Command Replace-JunoFile).ScriptBlock.ToString()
. ([scriptblock]::Create('function Invoke-StoreRealReplace {'+$realReplace+'}'))
# Fronteras fail-closed: incluso un mock faltante no llega a datos/identidades reales.
function Get-JunoIdentity { [pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'} }
function Test-JunoAdmin { throw 'TEST: identidad real prohibida' }
function Get-JunoMachineFolder { throw 'TEST: ProgramData real prohibido' }
function Confirm-JunoReview([string]$message) { throw 'TEST: dialogos reales prohibidos' }
function New-StoreData([string]$kind) {
    switch($kind){
        'General' { return [pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null} }
        'BPU' { return [pscustomobject]@{Version=1;Sid='TEST-SID';Items=@([pscustomobject]@{Family='Test_pkg';Disabled=[pscustomobject]@{Exists=$false;Value=$null};DisabledByUser=[pscustomobject]@{Exists=$true;Value=0}})} }
        'Policy' { return [pscustomobject]@{Owned=@('Test_pkg');MadeGlobal=$true} }
        'Trim' { return [pscustomobject]@{Original=1;Date='2026-10-17T00:00:00.0000000Z';Action='NTFS DisableDeleteNotify'} }
        'Power' { return [pscustomobject]@{PowerScheme='381b4222-f694-41f0-9685-ff5bb260df2e';CreatedPowerScheme=$null} }
        'Startup' {
            $run='Software\Microsoft\Windows\CurrentVersion\Run'
            return [pscustomobject]@{Entries=@([pscustomobject]@{Id="CurrentUser|Default|$run|Example";Name='Example';ApprovalHive='CurrentUser';ApprovalView='Default';ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';ApprovalValue='Example';SourceType='Registro';SourceHive='CurrentUser';SourceView='Default';SourceKey=$run;SourceValue='Example';Fingerprint='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';OriginalExists=$false;OriginalData=$null;LastWrittenData=$null})}
        }
    }
}
function Set-StoreRaw([string]$path,[string]$json) {
    if(-not $path.StartsWith($global:JunoStoreFixture.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: escritura fuera del fixture'}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($true))
}
function Initialize-StoreFixture([string]$drive) {
    $case=Join-Path $drive ([Guid]::NewGuid().ToString('N'))
    $global:JunoStoreFixture=[pscustomobject]@{Root=$case;Machine=(Join-Path $case 'machine')}
    $script:AppFolder=Join-Path $case 'user'
    Enter-JunoLease ('Local\Juno.Tests.Store.'+[Guid]::NewGuid().ToString('N'))
}

Describe 'Contratos historicos y destinos permitidos' {
    It 'acepta cada esquema historico conocido' -TestCases @(@{Kind='General';Scope='User'},@{Kind='BPU';Scope='User'},@{Kind='Startup';Scope='User'},@{Kind='Policy';Scope='Machine'},@{Kind='Trim';Scope='Machine'},@{Kind='Power';Scope='Machine'}) {
        param($Kind,$Scope)
        { Assert-JunoBackupData $Kind (New-StoreData $Kind) $Scope } | Should Not Throw
    }
    It 'rechaza tipos y propiedades ambiguos de JSON' -TestCases @(
        @{Json='{"Version":"1","Sid":"TEST-SID","Items":[]}'},@{Json='{"Version":1,"Sid":"TEST-SID","Items":null}'},
        @{Json='{"Version":99,"Sid":"TEST-SID","Items":[]}'},@{Json='{"Version":1,"Items":[]}'},
        @{Json='{"Version":1,"Sid":"OTHER-SID","Items":[]}'},@{Json='{"Version":1,"Sid":"TEST-SID","Items":[],"Hive":"LocalMachine"}'},
        @{Json='[]'},@{Json='null'},@{Json='false'},@{Json='{"Version":1,"Sid":"TEST-SID","Items":[]'},
        @{Json='{"Version":1,"Version":1,"Sid":"TEST-SID","Items":[]}'},@{Json='{"Version":1,"\u0056ersion":1,"Sid":"TEST-SID","Items":[]}'}
    ) {
        param($Json)
        { $d=ConvertFrom-JunoJson $Json; Assert-JunoBackupData BPU $d User } | Should Throw
    }
    It 'rechaza destinos de inicio arbitrarios antes de leer o escribir Windows' -TestCases @(
        @{Field='ApprovalKey';Value='Software\Microsoft\Windows\CurrentVersion\Run'},
        @{Field='ApprovalKey';Value='Software\JUNO\Arbitrary'},@{Field='ApprovalHive';Value='Users'},
        @{Field='ApprovalView';Value='Registry32'},@{Field='SourceKey';Value='Software\Arbitrary'},
        @{Field='SourceType';Value='Command'},@{Field='SourceHive';Value='LocalMachine'},@{Field='Id';Value='fake'},
        @{Field='OriginalExists';Value='false'},@{Field='OriginalData';Value='AAAA'},@{Field='Fingerprint';Value='bad'}
    ) {
        param($Field,$Value)
        $d=New-StoreData Startup; $d.Entries[0].$Field=$Value
        { Assert-JunoStartupData $d User } | Should Throw
    }
    It 'rechaza inicio del equipo dentro de un sobre de usuario' {
        $d=New-StoreData Startup;$r=$d.Entries[0]
        $r.ApprovalHive='LocalMachine';$r.SourceHive='LocalMachine'
        $r.SourceView=if([Environment]::Is64BitOperatingSystem){'Registry64'}else{'Default'};$r.ApprovalView=$r.SourceView
        $r.Id="LocalMachine|$($r.SourceView)|$($r.SourceKey)|$($r.SourceValue)"
        {Assert-JunoStartupData $d Machine}|Should Not Throw
        {Assert-JunoStartupData $d User}|Should Throw
    }
    It 'valida la carpeta Inicio contra KnownFolders, nunca contra la ruta del JSON' {
        Mock Get-JunoStartupFolder { 'C:\Fixtures\Startup' }
        $d=New-StoreData Startup;$r=$d.Entries[0]
        $r.SourceType='Archivo';$r.SourceHive='';$r.SourceView='';$r.SourceKey='C:\Fixtures\Startup\App.lnk';$r.SourceValue='App.lnk'
        $r.ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        $r.ApprovalView=if([Environment]::Is64BitOperatingSystem){'Registry64'}else{'Default'};$r.ApprovalValue='App.lnk';$r.Id='Archivo|'+$r.SourceKey
        {Assert-JunoStartupData $d User}|Should Not Throw
        $r.SourceKey='C:\Windows\App.lnk';$r.Id='Archivo|'+$r.SourceKey
        {Assert-JunoStartupData $d User}|Should Throw
    }
    It 'rechaza destinos visuales ajenos, tipos de Registro inesperados y duplicados' {
        $s=[pscustomobject]@{Key='Control Panel\Desktop';Name='FontSmoothing';Exists=$true;Kind='String';Value='2'}
        {Assert-JunoVisualRegistry @($s)}|Should Not Throw
        {Assert-JunoVisualRegistry @($s,$s)}|Should Throw
        $s.Kind='ExpandString';{Assert-JunoVisualRegistry @($s)}|Should Throw
        $s.Kind='String';$s.Key='Software\Arbitrary';{Assert-JunoVisualRegistry @($s)}|Should Throw
    }
    It 'rechaza planes con argumentos y paquetes que intentan escapar de la subclave' -TestCases @(
        @{Kind='Power';Field='PowerScheme';Value='381b4222-f694-41f0-9685-ff5bb260df2e /delete'},
        @{Kind='Policy';Field='Owned';Value=@('Test_pkg\Other')},@{Kind='Policy';Field='MadeGlobal';Value=1},
        @{Kind='Trim';Field='Action';Value='ReFS DisableDeleteNotify'},@{Kind='Trim';Field='Original';Value='1'}
    ) { param($Kind,$Field,$Value);$d=New-StoreData $Kind;$d.$Field=$Value;{Assert-JunoBackupData $Kind $d Machine}|Should Throw }
    It 'rechaza familias duplicadas y diarios de version futura' {
        $d=New-StoreData BPU;$d.Items+=@($d.Items[0]);{Assert-JunoBackupData BPU $d User}|Should Throw
        $d=New-StoreData Startup;Add-Member -InputObject $d.Entries[0] NoteProperty Transaction ([pscustomobject]@{Version=2;Confirmed=[pscustomobject]@{Exists=$false;Data=$null};Pending=$null})
        {Assert-JunoBackupData Startup $d User}|Should Throw
    }
    It 'rechaza valores anidados incorrectos y ausencia que contiene datos' -TestCases @(
        @{Field='Exists';Value='false'},@{Field='Value';Value=0},@{Field='Exists';Value=0}
    ) {
        param($Field,$Value)
        $d=New-StoreData BPU;$d.Items[0].Disabled.$Field=$Value
        {Assert-JunoBackupData BPU $d User}|Should Throw
    }
    It 'compara objetos por contenido, no por orden de propiedades ni wrappers ETS' {
        $a=[pscustomobject]@{Exists=$true;Value=@('Test_pkg'|Select-Object -Unique)}
        $b=[pscustomobject]@{Value=@('Test_pkg');Exists=$true}
        Test-JunoEqual $a $b|Should Be $true
        $copy=Copy-JunoObject @([pscustomobject]@{Name='only'})
        ($copy -is [array])|Should Be $true;$copy.Count|Should Be 1
        Test-JunoEqual @() (Copy-JunoObject @())|Should Be $true
    }
    It 'rechaza un diario de transparencia que perdio su original' {
        $d=New-StoreData General
        Add-Member -InputObject $d NoteProperty TransparencyBackup $null
        Add-Member -InputObject $d NoteProperty Journal ([pscustomobject]@{Version=1;Visual=$null;Transparency=[pscustomobject]@{Confirmed=[pscustomobject]@{Exists=$true;Kind='DWord';Value='0'};Pending=$null;Phase='Applied'}})
        {Assert-JunoBackupData General $d User}|Should Throw
    }
    It 'rechaza una fase final de TRIM que conserva intencion o valor contradictorio' {
        $d=New-StoreData Trim
        Add-Member -InputObject $d NoteProperty Transaction ([pscustomobject]@{Version=1;Confirmed=0;Pending=1;Phase='Restored'})
        {Assert-JunoBackupData Trim $d Machine}|Should Throw
    }
}

Describe 'Persistencia aislada, recuperacion y compatibilidad' {
    BeforeEach {
        Initialize-StoreFixture $TestDrive
        Mock Get-JunoMachineFolder {$global:JunoStoreFixture.Machine}
        Mock Test-JunoAdmin {$true}
        Mock Assert-JunoMachineAcl {}
        Mock Initialize-JunoMachineFolder { Assert-JunoLease; [void][IO.Directory]::CreateDirectory($global:JunoStoreFixture.Machine) }
        Mock Confirm-JunoReview { throw 'SIMULATED cancel' }
        Mock Write-JunoNewFile {param($path,$bytes) Invoke-StoreRealNewFile $path $bytes}
        Mock Replace-JunoFile {param($temp,$path,$previous) Invoke-StoreRealReplace $temp $path $previous}
    }
    AfterEach {Exit-JunoLease}
    It 'un respaldo inexistente devuelve el vacio definido sin crear carpetas' {
        $d=Read-JunoStore General User (New-StoreData General)
        $d.PowerScheme|Should BeNullOrEmpty
        Test-Path -LiteralPath $global:JunoStoreFixture.Root|Should Be $false
    }
    It 'leer un formato antiguo no modifica ni migra sus bytes' {
        $path=Get-JunoStorePath General User
        Set-StoreRaw $path '{"PowerScheme":null,"CreatedPowerScheme":null,"VisualEffects":null}'
        $hash=Get-JunoHash (Read-JunoBytes $path)
        [void](Read-JunoStore General User $null)
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
        @(Get-JunoRecoveryCandidates $path).Count|Should Be 0
    }
    It 'primera escritura de un historico conserva una copia verificada y no pierde ausencias' {
        $path=Get-JunoStorePath BPU User;$d=New-StoreData BPU
        Set-StoreRaw $path ($d|ConvertTo-Json -Depth 10)
        $hash=Get-JunoHash (Read-JunoBytes $path)
        Write-JunoStore BPU $d User
        $loaded=Read-JunoStore BPU User $null
        $loaded.Items[0].Disabled.Exists|Should Be $false
        $history=@(Get-JunoRecoveryCandidates $path|Where-Object{$_.Name -like '*.history.*'})
        $history.Count|Should Be 1
        (Get-JunoHash (Read-JunoBytes $history[0].FullName))|Should Be $hash
        (ConvertFrom-JunoBytes (Read-JunoBytes $path)).Format|Should Be 'JUNO.Backup'
    }
    It 'rechaza sobres de otro usuario, equipo, version, tipo o ambito sin tocarlos' -TestCases @(
        @{Field='Sid';Value='OTHER'},@{Field='Machine';Value='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'},@{Field='Version';Value=2},
        @{Field='Kind';Value='Power'},@{Field='Scope';Value='Machine'},@{Field='Revision';Value='fake'}
    ) {
        param($Field,$Value)
        Write-JunoStore BPU (New-StoreData BPU) User;$path=Get-JunoStorePath BPU User
        $doc=ConvertFrom-JunoBytes (Read-JunoBytes $path);$doc.$Field=$Value;Set-StoreRaw $path ($doc|ConvertTo-Json -Depth 20)
        $hash=Get-JunoHash (Read-JunoBytes $path)
        {Read-JunoStore BPU User $null}|Should Throw
        {Write-JunoStore BPU (New-StoreData BPU) User}|Should Throw
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
    }
    It 'un JSON truncado se conserva aunque exista una copia valida' {
        Write-JunoStore General (New-StoreData General) User
        Write-JunoStore General (New-StoreData General) User
        $path=Get-JunoStorePath General User;Set-StoreRaw $path '{"PowerScheme":'
        {Read-JunoStore General User $null}|Should Throw
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        [IO.File]::ReadAllText($path)|Should Be '{"PowerScheme":'
        @(Get-JunoRecoveryCandidates $path).Count|Should Be 1
    }
    It 'fallo de escritura no cambia el ultimo principal valido' {
        Write-JunoStore General (New-StoreData General) User;$path=Get-JunoStorePath General User;$hash=Get-JunoHash (Read-JunoBytes $path)
        Mock Write-JunoNewFile {throw 'SIMULATED full disk'}
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
    }
    It 'interrupcion anterior a Replace conserva principal y temporal unico validado' {
        Write-JunoStore General (New-StoreData General) User;$path=Get-JunoStorePath General User;$hash=Get-JunoHash (Read-JunoBytes $path)
        Mock Replace-JunoFile {throw 'SIMULATED interruption'}
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
        $temps=@(Get-ChildItem -LiteralPath $script:AppFolder -Filter '*.pending.*')
        $temps.Count|Should Be 2
        foreach($file in $temps){[void](Read-JunoDocument $file.FullName General User)}
    }
    It 'fallo posterior a Replace mantiene nuevo principal y copia anterior recuperables' {
        Write-JunoStore General (New-StoreData General) User;$path=Get-JunoStorePath General User;$hash=Get-JunoHash (Read-JunoBytes $path)
        Mock Replace-JunoFile {param($temp,$path,$previous) [IO.File]::Replace($temp,$path,$previous,$false);throw 'SIMULATED after replace'}
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        [void](Read-JunoStore General User $null)
        $copy=@(Get-JunoRecoveryCandidates $path)[0]
        (Get-JunoHash (Read-JunoBytes $copy.FullName))|Should Be $hash
    }
    It 'recupera solo por seleccion explicita y conserva incluso el principal rechazado' {
        Write-JunoStore General (New-StoreData General) User;Write-JunoStore General (New-StoreData General) User
        $path=Get-JunoStorePath General User;$copy=@(Get-JunoRecoveryCandidates $path)[0];Set-StoreRaw $path '{bad'
        Restore-JunoStoreCopy General $copy.FullName User|Should Match 'No se aplicaron ajustes'
        [void](Read-JunoStore General User $null)
        $bad=@(Get-ChildItem -LiteralPath $script:AppFolder -Filter '*.rejected.*')
        $bad.Count|Should Be 1;[IO.File]::ReadAllText($bad[0].FullName)|Should Be '{bad'
    }
    It 'principal ausente con copias previas no se considera un respaldo vacio' {
        $path=Get-JunoStorePath General User;Set-StoreRaw ($path+'.previous.fake.json') ((New-StoreData General)|ConvertTo-Json)
        {Read-JunoStore General User $null}|Should Throw
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
        Test-Path -LiteralPath $path|Should Be $false
    }
    It 'no permite recuperar una ruta arbitraria' {
        {Restore-JunoStoreCopy General 'C:\Windows\backup.json' User}|Should Throw
    }
    It 'cancelar importacion de equipo no crea archivos ni cambia el historico' {
        $path=Get-JunoStorePath Policy User;Set-StoreRaw $path ((New-StoreData Policy)|ConvertTo-Json)
        $hash=Get-JunoHash (Read-JunoBytes $path)
        {Import-JunoMachineLegacy Policy}|Should Throw
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
        Test-Path -LiteralPath $global:JunoStoreFixture.Machine|Should Be $false
    }
    It 'importacion aprobada valida, copia y verifica en carpeta protegida sin sobrescribir origen' {
        Mock Confirm-JunoReview {}
        $path=Get-JunoStorePath Policy User;Set-StoreRaw $path ((New-StoreData Policy)|ConvertTo-Json)
        $hash=Get-JunoHash (Read-JunoBytes $path)
        Import-JunoMachineLegacy Policy
        (Read-JunoStore Policy Machine $null).MadeGlobal|Should Be $true
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
        $copies=@(Get-JunoRecoveryCandidates (Get-JunoStorePath Policy Machine))
        (Get-JunoHash (Read-JunoBytes $copies[0].FullName))|Should Be $hash
        Assert-MockCalled Initialize-JunoMachineFolder -Times 1 -Exactly -Scope It
    }
    It 'detecta sustitucion del historico durante la revision' {
        $path=Get-JunoStorePath Policy User;Set-StoreRaw $path ((New-StoreData Policy)|ConvertTo-Json)
        Mock Confirm-JunoReview {Set-StoreRaw (Get-JunoStorePath Policy User) '{"Owned":[],"MadeGlobal":false}'}
        {Import-JunoMachineLegacy Policy}|Should Throw
        Test-Path -LiteralPath $global:JunoStoreFixture.Machine|Should Be $false
    }
    It 'recupera una importacion interrumpida desde su evidencia, con otra revision explicita' {
        $path=Get-JunoStorePath Policy Machine;$copy=$path+'.history.fixture.json'
        Set-StoreRaw $copy ((New-StoreData Policy)|ConvertTo-Json)
        {Read-JunoStore Policy Machine $null}|Should Throw
        Mock Confirm-JunoReview {}
        Restore-JunoStoreCopy Policy $copy Machine|Should Match 'Copia recuperada'
        (Read-JunoStore Policy Machine $null).MadeGlobal|Should Be $true
        Assert-MockCalled Confirm-JunoReview -Times 1 -Exactly -Scope It
    }
    It 'separar HKCU conserva el acceso a HKLM historico archivado' {
        $d=New-StoreData Startup;$r=$d.Entries[0]
        $r.ApprovalHive='LocalMachine';$r.SourceHive='LocalMachine';$r.SourceView=if([Environment]::Is64BitOperatingSystem){'Registry64'}else{'Default'};$r.ApprovalView=$r.SourceView
        $r.Id="LocalMachine|$($r.SourceView)|$($r.SourceKey)|$($r.SourceValue)"
        $path=Get-JunoStorePath Startup User;Set-StoreRaw $path ($d|ConvertTo-Json -Depth 12)
        Write-JunoStore Startup ([pscustomobject]@{Entries=@()}) User
        $legacy=Get-JunoMachineLegacy Startup
        $legacy.Data.Entries.Count|Should Be 1
        $legacy.Path|Should Match '\.history\.'
    }
    It 'rechaza permisos insuficientes antes de persistir en el ambito de equipo' {
        Mock Initialize-JunoMachineFolder {throw [UnauthorizedAccessException]::new('SIMULATED denied')}
        {Write-JunoStore Policy (New-StoreData Policy) Machine}|Should Throw
        Test-Path -LiteralPath $global:JunoStoreFixture.Machine|Should Be $false
    }
}

Describe 'ACL y rutas de respaldos de equipo' {
    It 'crea descriptores protegidos con propietario administrativo tambien para los archivos' {
        foreach($directory in @($false,$true)){
            $acl=New-JunoMachineSecurity -Directory:$directory
            $acl.AreAccessRulesProtected|Should Be $true
            $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value|Should Be 'S-1-5-32-544'
            $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $rules.Count|Should Be 2
            foreach($rule in $rules){($rule.IdentityReference.Value -in @('S-1-5-18','S-1-5-32-544'))|Should Be $true;$rule.FileSystemRights|Should Be ([Security.AccessControl.FileSystemRights]::FullControl)}
        }
    }
    It 'rechaza propietario no administrativo en una carpeta ficticia real' {
        $dir=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($dir)
        $acl=Get-Acl -LiteralPath $dir
        # Inspeccion de ACL real, sin modificarla. El resultado depende del token del runner.
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){
            {Assert-JunoMachineAcl $dir}|Should Throw
        }else{
            $untrusted=[Security.AccessControl.DirectorySecurity]::new()
            $untrusted.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
            Mock Get-Acl {$untrusted}
            {Assert-JunoMachineAcl $dir}|Should Throw
        }
    }
    It 'rechaza escritura a Users aunque el propietario sea Administradores' {
        $global:JunoAclFixture=[Security.AccessControl.DirectorySecurity]::new()
        $global:JunoAclFixture.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $global:JunoAclFixture.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Modify','Allow'))
        Mock Get-Acl {$global:JunoAclFixture}
        {Assert-JunoMachineAcl $TestDrive}|Should Throw
    }
    It 'rechaza junctions reales y rutas UNC, relativas o con ADS' {
        $dir=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));$target=Join-Path $dir 'target';$link=Join-Path $dir 'link'
        [void][IO.Directory]::CreateDirectory($target)
        [void](New-Item -ItemType Junction -Path $link -Target $target)
        {Assert-JunoLocalPath (Join-Path $link 'backup.json')}|Should Throw
        foreach($path in @('..\backup.json','\\server\share\backup.json','C:\backup.json:stream','C:\a\..\b.json')){{Assert-JunoLocalPath $path}|Should Throw}
    }
}

Describe 'Revision de recuperacion sin mostrar ventanas' {
    BeforeEach {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $storeRoot 'BackupStore.ps1'),[ref]$tokens,[ref]$errors)
        $n=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-JunoReview'},$true)
        $source=$n.Extent.Text.Replace('function Confirm-JunoReview','function Invoke-StoreReviewFixture').Replace('$dialog.ShowDialog()','(& $global:JunoReviewProbe $dialog)')
        . ([scriptblock]::Create($source))
    }
    It 'muestra todo el texto como solo lectura y cancela por defecto' {
        $global:JunoReviewProbe={param($dialog)
            $dialog.AcceptButton.Text|Should Be 'Cancelar';$dialog.CancelButton.Text|Should Be 'Cancelar'
            $text=@($dialog.Controls|Where-Object{$_ -is [Windows.Forms.TextBox]})[0]
            $text.ReadOnly|Should Be $true;$text.Multiline|Should Be $true;$text.ScrollBars.ToString()|Should Be 'Both'
            $text.Text.Length|Should Be 50000
            return [Windows.Forms.DialogResult]::No
        }
        {Invoke-StoreReviewFixture ('x'*50000)}|Should Throw
    }
    It 'solo acepta la autorizacion explicita' {
        $global:JunoReviewProbe={param($dialog) return [Windows.Forms.DialogResult]::Yes}
        {Invoke-StoreReviewFixture 'fixture'}|Should Not Throw
    }
}

function Start-StorePeer([string]$body) {
    $peer=if([Environment]::Is64BitProcess){Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'}else{Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'}
    if(-not(Test-Path -LiteralPath $peer)){throw 'TEST: no se encontro el PowerShell de arquitectura opuesta'}
    $code='$ErrorActionPreference=''Stop'';$ProgressPreference=''SilentlyContinue'';. '''+(Join-Path $storeRoot 'BackupStore.ps1')+''';'+$body
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$peer;$info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardError=$true;$info.RedirectStandardOutput=$true
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start();return $p
}
Describe 'Mutex real entre procesos x86 y x64' {
    AfterEach {Exit-JunoLease}
    It 'otro proceso queda ocupado y puede adquirirlo despues de liberar' {
        $name='Global\Juno.Tests.Peer.'+[Guid]::NewGuid().ToString('N');Enter-JunoLease $name
        $script:AppFolder=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        Write-JunoStore General (New-StoreData General) User
        $path=Get-JunoStorePath General User;$hash=Get-JunoHash (Read-JunoBytes $path)
        $writer='$script:AppFolder='''+$script:AppFolder+''';function Get-JunoIdentity {[pscustomobject]@{Sid=''TEST-SID'';Machine=''11111111-2222-3333-4444-555555555555''}};'
        $writer+='try {Enter-JunoLease '''+$name+''';try {Write-JunoStore General ([pscustomobject]@{PowerScheme=''381b4222-f694-41f0-9685-ff5bb260df2e'';CreatedPowerScheme=$null;VisualEffects=$null}) User} finally {Exit-JunoLease};exit 0} catch {if($_.Exception.Message -like ''Recurso ocupado*''){exit 23};throw}'
        $p=Start-StorePeer $writer
        try { $p.WaitForExit(15000)|Should Be $true;$p.ExitCode|Should Be 23 } finally {if(-not $p.HasExited){$p.Kill()};$p.Dispose()}
        (Get-JunoHash (Read-JunoBytes $path))|Should Be $hash
        Exit-JunoLease
        $p=Start-StorePeer $writer
        try {$p.WaitForExit(15000)|Should Be $true;$p.ExitCode|Should Be 0}finally{if(-not $p.HasExited){$p.Kill()};$p.Dispose()}
        Enter-JunoLease $name
        (Read-JunoStore General User $null).PowerScheme|Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
    }
    It 'un cierre abrupto no deja bloqueo permanente y se detecta abandono' {
        $case=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($case)
        $ready=Join-Path $case 'ready';$gate=Join-Path $case 'exit';$name='Global\Juno.Tests.Crash.'+[Guid]::NewGuid().ToString('N')
        $body='Enter-JunoLease '''+$name+''';[IO.File]::WriteAllText('''+$ready+''',''ready'');$watch=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists('''+$gate+''')){if($watch.ElapsedMilliseconds -gt 10000){exit 4};Start-Sleep -Milliseconds 25};[Environment]::Exit(0)'
        $p=Start-StorePeer $body;$observer=$null
        try {
            $watch=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists($ready) -and -not $p.HasExited -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 25}
            [IO.File]::Exists($ready)|Should Be $true
            $observer=[Threading.Mutex]::OpenExisting($name,[Security.AccessControl.MutexRights]'Synchronize,Modify,ReadPermissions')
            [IO.File]::WriteAllText($gate,'exit');$p.WaitForExit(15000)|Should Be $true;$p.ExitCode|Should Be 0
            Enter-JunoLease $name
            $script:JunoLease.Abandoned|Should Be $true
            Assert-JunoLease
        } finally {if($observer){$observer.Dispose()};if(-not $p.HasExited){$p.Kill()};$p.Dispose()}
    }
    It 'libera el recurso mediante finally despues de una excepcion' {
        $name='Global\Juno.Tests.Finally.'+[Guid]::NewGuid().ToString('N')
        try {Enter-JunoLease $name;throw 'SIMULATED'}catch{}finally{Exit-JunoLease}
        {Enter-JunoLease $name;Assert-JunoLease}|Should Not Throw
    }
    It 'una funcion mutadora sin lease falla antes de crear archivos' {
        {Write-JunoStore General (New-StoreData General) User}|Should Throw
    }
}
