#requires -Version 5.1
# Identidades/archivos ficticios. Sin SID, ACL, Registro o respaldos de producción.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$identityRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $identityRoot 'BackupStore.ps1')
function Get-JunoIdentity {throw 'TEST: identidad real prohibida'}
function Test-JunoAdmin {throw 'TEST: token real prohibido'}
function Get-JunoMachineFolder {throw 'TEST: almacén real prohibido'}
function New-IdentityData {
    return [pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;TransparencyBackup=[pscustomobject]@{Exists=$false;Kind=$null;Value=$null}}
}
function New-IdentityDocument {
    return [pscustomobject]@{Format='JUNO.Backup';Version=1;Kind='General';Scope='User';Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Revision=[Guid]::NewGuid().ToString();Data=(New-IdentityData)}
}
function Save-IdentityFixture($doc) {
    # Solo el archivo perteneciente al TestDrive del caso.
    [IO.File]::WriteAllText($global:JunoIdentityCase.Path,($doc|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
}
function Receive-IdentityFailure([scriptblock]$action) {
    try{& $action|Out-Null}catch{return $_.Exception}
    throw 'TEST: se esperaba un rechazo'
}
Describe 'Identidad y procedencia del almacén General sin modificar originales' {
    BeforeEach {
        $global:JunoIdentityCase=[pscustomobject]@{Path=(Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.json'));Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555';Elevated=$false}
        Mock Get-JunoIdentity {[pscustomobject]@{Sid=$global:JunoIdentityCase.Sid;Machine=$global:JunoIdentityCase.Machine}}
        Mock Test-JunoAdmin {$global:JunoIdentityCase.Elevated}
        Mock Assert-JunoLease {}
        Mock Get-JunoStorePath {$global:JunoIdentityCase.Path}
        Mock Get-JunoMachineFolder {$TestDrive}
        Mock Assert-JunoMachineAcl {}
    }
    It 'acepta el mismo usuario en ejecución elevada=<Elevated> sin confundir privilegio con identidad' -TestCases @(@{Elevated=$false},@{Elevated=$true}) {
        param($Elevated)
        $global:JunoIdentityCase.Elevated=$Elevated;Save-IdentityFixture (New-IdentityDocument)
        $before=Get-JunoHash (Read-JunoBytes $global:JunoIdentityCase.Path)
        $r=Read-JunoStore General User $null;$r.TransparencyBackup.Exists|Should Be $false
        (Get-JunoHash (Read-JunoBytes $global:JunoIdentityCase.Path))|Should Be $before
        Assert-MockCalled Test-JunoAdmin -Times 0 -Exactly -Scope It
    }
    It 'rechaza <Field> incompatible con un diagnóstico concreto y sin reescritura' -TestCases @(
        @{Field='Sid';Value='OTHER-SID';Code='UserMismatch'},
        @{Field='Machine';Value='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Code='MachineMismatch'},
        @{Field='Scope';Value='Machine';Code='ScopeMismatch'},
        @{Field='Kind';Value='Power';Code='KindMismatch'},
        @{Field='Format';Value='Foreign.Backup';Code='FormatMismatch'}
    ) {
        param($Field,$Value,$Code)
        $doc=New-IdentityDocument;$doc.$Field=$Value;Save-IdentityFixture $doc
        $before=Get-JunoHash (Read-JunoBytes $global:JunoIdentityCase.Path)
        $failure=Receive-IdentityFailure {Read-JunoStore General User $null}
        Get-JunoBackupFailureCode $failure|Should Be $Code
        $failure.Message.Contains($global:JunoIdentityCase.Path)|Should Be $false
        $failure.Message.Contains('OTHER-SID')|Should Be $false
        {Write-JunoStore General (New-IdentityData) User}|Should Throw
        (Get-JunoHash (Read-JunoBytes $global:JunoIdentityCase.Path))|Should Be $before
    }
    It 'elevar con otra identidad no autoriza leer ni restaurar un respaldo de usuario' {
        Save-IdentityFixture (New-IdentityDocument)
        $global:JunoIdentityCase.Sid='DIFFERENT-TOKEN';$global:JunoIdentityCase.Elevated=$true
        $failure=Receive-IdentityFailure {Read-JunoStore General User $null}
        Get-JunoBackupFailureCode $failure|Should Be 'UserMismatch'
    }
    It 'un SID de usuario no se acepta en un sobre de equipo aunque coincida el equipo' {
        $doc=New-IdentityDocument;$doc.Scope='Machine';Save-IdentityFixture $doc
        $failure=Receive-IdentityFailure {Read-JunoStore General Machine $null}
        Get-JunoBackupFailureCode $failure|Should Be 'ScopeMismatch'
    }
    It 'un sobre de equipo válido no se convierte en autoridad HKCU' {
        $doc=New-IdentityDocument;$doc.Scope='Machine';$doc.Sid=$null;Save-IdentityFixture $doc
        {Read-JunoStore General Machine $null}|Should Not Throw
        $failure=Receive-IdentityFailure {Read-JunoStore General User $null}
        Get-JunoBackupFailureCode $failure|Should Be 'ScopeMismatch'
    }
    It 'acepta histórico identificado sin diario y conserva sus bytes al consultar' {
        Save-IdentityFixture (New-IdentityDocument)
        $before=[IO.File]::ReadAllText($global:JunoIdentityCase.Path)
        $r=Read-JunoStore General User $null
        ($r.PSObject.Properties.Name -contains 'Journal')|Should Be $false
        [IO.File]::ReadAllText($global:JunoIdentityCase.Path)|Should Be $before
    }
    It 'un General histórico sin identidad sigue bloqueado con Legacy=<Legacy>' -TestCases @(@{Legacy=$false},@{Legacy=$true}) {
        param($Legacy)
        Save-IdentityFixture (New-IdentityData)
        $before=[IO.File]::ReadAllText($global:JunoIdentityCase.Path)
        $failure=Receive-IdentityFailure {Read-JunoDocument $global:JunoIdentityCase.Path General User -Legacy:$Legacy}
        Get-JunoBackupFailureCode $failure|Should Be 'UnverifiableLegacy'
        {Write-JunoStore General (New-IdentityData) User}|Should Throw
        [IO.File]::ReadAllText($global:JunoIdentityCase.Path)|Should Be $before
    }
    It 'rechaza respaldo incompleto o inválido <Case> sin revelar contenido privado' -TestCases @(@{Case='missing-field'},@{Case='future-version'},@{Case='invalid-json'}) {
        param($Case)
        $doc=New-IdentityDocument
        switch($Case){
            'missing-field' {$doc.PSObject.Properties.Remove('Sid');Save-IdentityFixture $doc}
            'future-version' {$doc.Version=99;Save-IdentityFixture $doc}
            'invalid-json' {[IO.File]::WriteAllText($global:JunoIdentityCase.Path,'{"SECRET_PRIVATE_FIELD":',[Text.UTF8Encoding]::new($true))}
        }
        $before=[IO.File]::ReadAllText($global:JunoIdentityCase.Path)
        $failure=Receive-IdentityFailure {Read-JunoStore General User $null}
        Get-JunoBackupFailureCode $failure|Should Be 'InvalidBackup'
        $failure.Message|Should Not Match 'SECRET_PRIVATE_FIELD'
        [IO.File]::ReadAllText($global:JunoIdentityCase.Path)|Should Be $before
    }
    It 'recuperación de copia General sin identidad no reemplaza el principal ni crea autoridad nueva' {
        Save-IdentityFixture (New-IdentityDocument);$path=$global:JunoIdentityCase.Path
        $copy=$path+'.history.fixture.json'
        [IO.File]::WriteAllText($copy,((New-IdentityData)|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
        $before=[IO.File]::ReadAllText($path);$copyBefore=[IO.File]::ReadAllText($copy)
        {Restore-JunoStoreCopy General $copy User}|Should Throw
        [IO.File]::ReadAllText($path)|Should Be $before
        [IO.File]::ReadAllText($copy)|Should Be $copyBefore
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.recovery.*').Count|Should Be 0
    }
    It 'el código de rechazo sobrevive a excepciones anidadas de PowerShell y .NET' {
        $failure=Receive-IdentityFailure {Stop-JunoBackupValidation UserMismatch 'Mensaje de prueba sin identidad'}
        $wrapped=[InvalidOperationException]::new('Wrapper',[InvalidOperationException]::new('Wrapper',$failure))
        Get-JunoBackupFailureCode $wrapped|Should Be 'UserMismatch'
        foreach($code in @('UserMismatch','MachineMismatch','ScopeMismatch','KindMismatch','FormatMismatch','InvalidBackup','UnverifiableLegacy')){
            $message=Get-JunoBackupFailureText $code
            $message|Should Not Match 'TEST-SID|11111111|[A-Z]:\\'
        }
    }
}
