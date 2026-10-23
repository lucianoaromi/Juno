#requires -Version 5.1
# Real store validation + central preflight. Only private TestDrive files and fake identities/snapshots.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$riRoot=Split-Path $PSScriptRoot -Parent;$script:AppFolder=$env:TEMP
foreach($name in @('BackupStore','RecoveryOperations','TransparencyOperations','TransparencyAdapter','RecoveryAdapter')){. (Join-Path $riRoot ($name+'.ps1'))}
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Get-JunoStorePath($kind,$scope){if($kind -cne 'General' -or $scope -cne 'User'){throw 'TEST: unexpected store'};return $global:JunoRestIdentity.Path}
function Get-TransparencySnapshot {if($global:JunoRestIdentity.QueryError){throw 'SIMULATED registry query failure'};[pscustomobject]@{Exists=$true;Kind='DWord';Value=$global:JunoRestIdentity.Current}}
function Restore-Transparency {throw 'TEST: real restore forbidden'}
function New-RestIdentityDocument {
    [pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;TransparencyBackup=[pscustomobject]@{Exists=$false;Kind=$null;Value=$null};Journal=[pscustomobject]@{Version=1;Visual=$null;Transparency=[pscustomobject]@{Confirmed=[pscustomobject]@{Exists=$true;Kind='DWord';Value='0'};Pending=$null;Phase='Applied'}}}}
}
function Save-RestIdentity($doc){[IO.File]::WriteAllText($global:JunoRestIdentity.Path,($doc|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($true))}
Describe 'Preflight central conserva identidad, historial e integridad del almacén real' {
    BeforeEach {$global:JunoRestIdentity=[pscustomobject]@{Path=(Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.json'));Current='0';QueryError=$false};Enter-JunoLease ('Local\Juno.Tests.RestIdentity.'+[Guid]::NewGuid().ToString('N'))}
    AfterEach {Exit-JunoLease}
    It 'un original ausente válido con diario tiene recuperación y consultar no cambia bytes' {
        Save-RestIdentity (New-RestIdentityDocument);$before=(Get-FileHash $global:JunoRestIdentity.Path).Hash
        $r=Read-JunoRecoveryItem Transparency $false;$r.CanRestore|Should Be $true
        (Get-FileHash $global:JunoRestIdentity.Path).Hash|Should Be $before
    }
    It 'no inventa respaldo al faltar el archivo' {
        (Read-JunoRecoveryItem Transparency $false).State|Should Be Empty;Test-Path -LiteralPath $global:JunoRestIdentity.Path|Should Be $false
    }
    It 'rechaza <Field> incorrecto sin reescribir ni ofrecer restaurar' -TestCases @(@{Field='Sid';Value='OTHER-SID'},@{Field='Machine';Value='aaaaaaaa-2222-3333-4444-555555555555'},@{Field='Scope';Value='Machine'},@{Field='Kind';Value='Power'},@{Field='Format';Value='Foreign'}) {
        param($Field,$Value)$doc=New-RestIdentityDocument;$doc.$Field=$Value;Save-RestIdentity $doc;$hash=(Get-FileHash $global:JunoRestIdentity.Path).Hash
        $r=Read-JunoRecoveryItem Transparency $false;$r.State|Should Be Error;$r.CanRestore|Should Be $false
        (Get-FileHash $global:JunoRestIdentity.Path).Hash|Should Be $hash
    }
    It 'rechaza JSON duplicado y conserva evidencia' {
        [IO.File]::WriteAllText($global:JunoRestIdentity.Path,'{"Version":1,"Version":2}',[Text.UTF8Encoding]::new($true));$hash=(Get-FileHash $global:JunoRestIdentity.Path).Hash
        (Read-JunoRecoveryItem Transparency $false).State|Should Be Error;(Get-FileHash $global:JunoRestIdentity.Path).Hash|Should Be $hash
    }
    It 'un principal ausente con previous no se interpreta como almacén vacío' {
        [IO.File]::WriteAllText(($global:JunoRestIdentity.Path+'.previous.fixture.json'),'historical evidence');$before=(Get-FileHash ($global:JunoRestIdentity.Path+'.previous.fixture.json')).Hash
        (Read-JunoRecoveryItem Transparency $false).State|Should Be Error
        (Get-FileHash ($global:JunoRestIdentity.Path+'.previous.fixture.json')).Hash|Should Be $before;Test-Path -LiteralPath $global:JunoRestIdentity.Path|Should Be $false
    }
    It 'el legado sin identidad y el original sin diario no habilitan recuperación automática' {
        $doc=New-RestIdentityDocument;Save-RestIdentity $doc.Data;(Read-JunoRecoveryItem Transparency $false).CanRestore|Should Be $false
        $doc.Data.Journal.Transparency=$null;Save-RestIdentity $doc;(Read-JunoRecoveryItem Transparency $false).State|Should Be Blocked
    }
    It 'un cambio externo o error de consulta bloquea el original validado' -TestCases @(@{Error=$false},@{Error=$true}) {
        param($Error)Save-RestIdentity (New-RestIdentityDocument);$global:JunoRestIdentity.Current='1';$global:JunoRestIdentity.QueryError=$Error
        $r=Read-JunoRecoveryItem Transparency $false;$r.CanRestore|Should Be $false
        if(-not $Error){$r.State|Should Be Conflict}
    }
    It 'la comprobación de procedencia rechaza archivos raw y valida sobres de <Kind>' -TestCases @(@{Kind='Startup'},@{Kind='BPU'}) {
        param($Kind)
        # Exercise the real provenance reader, independent of the module's Windows providers.
        $path=$global:JunoRestIdentity.Path
        Mock Get-JunoStorePath {$global:JunoRestIdentity.Path}
        $doc=New-RestIdentityDocument;$doc.Kind=$Kind
        $doc.Data=if($Kind -eq 'Startup'){[pscustomobject]@{Entries=@()}}else{[pscustomobject]@{Version=1;Sid='TEST-SID';Items=@()}}
        Save-RestIdentity $doc.Data;$before=(Get-FileHash $path).Hash
        Test-JunoRecoveryUserProvenance $Kind|Should Be $false;(Get-FileHash $path).Hash|Should Be $before
        Save-RestIdentity $doc;Test-JunoRecoveryUserProvenance $Kind|Should Be $true
        $doc.Machine='aaaaaaaa-2222-3333-4444-555555555555';Save-RestIdentity $doc
        {Test-JunoRecoveryUserProvenance $Kind}|Should Throw
    }
}
