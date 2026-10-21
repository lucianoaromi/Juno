#requires -Version 5.1
# Barreras cerradas y datos ficticios: nunca se ejecuta powercfg real ni ProgramData.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$powerRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledPower' -as [type])) {
    if('Juno.Preview.ShellForm' -as [type]){throw 'Ejecuta en un proceso nuevo para compilar todos los fixtures.'}
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\PowerModel.cs','ui\PowerPlatform.cs','ui\PowerShellPowerService.cs','ui\JunoShell.cs','tests\Dashboard.TestSupport.cs','tests\Transparency.TestSupport.cs','tests\Power.TestSupport.cs')|ForEach-Object{Join-Path $powerRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $powerRoot 'BackupStore.ps1')
. (Join-Path $powerRoot 'RecoveryOperations.ps1')
. (Join-Path $powerRoot 'PowerOperations.ps1')
. (Join-Path $powerRoot 'PowerAdapter.ps1')
function Invoke-PowerCfg([string[]]$arguments){throw 'TEST: powercfg real prohibido'}
function Get-JunoPowerCapabilities {throw 'TEST: capacidades reales prohibidas'}
function Test-JunoAdmin {throw 'TEST: token real prohibido'}
function Get-JunoMachineFolder {throw 'TEST: ProgramData real prohibido'}
function Get-JunoMachineLegacy([string]$kind){throw 'TEST: respaldo histórico real prohibido'}
function Import-JunoMachineLegacy([string]$kind){throw 'TEST: importación real prohibida'}
function Confirm-JunoReview([string]$message){throw 'TEST: diálogo real prohibido'}
function Get-JunoStorePath([string]$kind,[string]$scope='User'){throw 'TEST: ruta real prohibida'}
function Read-JunoStore([string]$kind,[string]$scope='User',$default){throw 'TEST: respaldo real prohibido'}
function Write-JunoStore([string]$kind,$data,[string]$scope='User'){throw 'TEST: escritor real prohibido'}
function Reset-PowerFake {
    $global:JunoPowerFake=[pscustomobject]@{Active='381b4222-f694-41f0-9685-ff5bb260df2e';Plans=@('381b4222-f694-41f0-9685-ff5bb260df2e','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c');Backup=$null;Admin=$true;Modern=$false;Writes=0;Saves=0;Fail='';Reads=0;Commands=@();Legacy=$null;Names=@{};Prefix='Esquema de energía GUID:'}
}
Describe 'Adaptador de energía y motor estable con planes ficticios' {
    BeforeEach {
        Reset-PowerFake
        Mock Enter-JunoLease {$script:JunoLease=[pscustomobject]@{Abandoned=$false}}
        Mock Assert-JunoLease {}
        Mock Exit-JunoLease {$script:JunoLease=$null}
        Mock Test-JunoAdmin {$global:JunoPowerFake.Admin}
        Mock Get-JunoPowerCapabilities {$global:JunoPowerFake.Modern}
        Mock Get-JunoStorePath {Join-Path $TestDrive 'No existente\power-backup.json'}
        Mock Get-JunoMachineLegacy {$global:JunoPowerFake.Legacy}
        Mock Import-JunoMachineLegacy {
            if($null -ne $global:JunoPowerFake.Legacy){Confirm-JunoReview 'Importación ficticia';$global:JunoPowerFake.Backup=Copy-JunoObject $global:JunoPowerFake.Legacy.Data;$global:JunoPowerFake.Legacy=$null}
        }
        Mock Confirm-JunoReview {}
        Mock Read-JunoStore {
            param($kind,$scope,$default)
            if($null -eq $global:JunoPowerFake.Backup){return $default}
            Assert-JunoBackupData Power $global:JunoPowerFake.Backup Machine
            Copy-JunoObject $global:JunoPowerFake.Backup
        }
        Mock Write-JunoStore {
            param($kind,$data,$scope)
            $kind|Should Be Power;$scope|Should Be Machine
            Assert-JunoBackupData Power $data Machine
            $global:JunoPowerFake.Backup=Copy-JunoObject $data;$global:JunoPowerFake.Saves++
        }
        Mock Invoke-PowerCfg {
            param($arguments)
            $f=$global:JunoPowerFake;$f.Commands+=@($arguments -join ' ')
            switch($arguments[0]) {
                '/getactivescheme' {$f.Reads++;if($f.Fail -eq 'Read'){throw 'SIMULATED powercfg denied'};return ('GUID: '+$f.Active+' (Plan ficticio)')}
                '/list' {return (@($f.Plans|ForEach-Object{$name=if($f.Names.ContainsKey($_)){$f.Names[$_]}else{'Plan ficticio'};$f.Prefix+' '+$_+' ('+$name+')'}) -join "`n")}
                '/duplicatescheme' {
                    Assert-JunoGuid $arguments[2]
                    $f.Backup.CreatedPowerScheme|Should Be $arguments[2]
                    if($f.Fail -eq 'Create'){throw 'SIMULATED creation denied'}
                    $f.Plans+=@($arguments[2]);$f.Writes++;if($f.Fail -eq 'CreateAfter'){throw 'SIMULATED creation completed then failed'};return $arguments[2]
                }
                '/setactive' {
                    Assert-JunoGuid $arguments[1];$f.Saves|Should BeGreaterThan 0;$f.Writes++
                    if($f.Fail -eq 'WriteBefore'){throw 'SIMULATED setactive before'}
                    if($f.Fail -ne 'NoEffect'){$f.Active=$arguments[1]}
                    if($f.Fail -eq 'WriteAfter'){throw 'SIMULATED setactive after'}
                }
                default {throw 'TEST: comando fuera del alcance'}
            }
        }
    }
    It 'lee plan activo y enumera sin escribir ni respaldar' {
        $r=Invoke-JunoPowerRequest Read
        $r.ActiveGuid|Should Be $global:JunoPowerFake.Active;$r.ActiveName|Should Match 'Plan ficticio'
        $r.Plans.Count|Should Be 2;$r.Outcome|Should Be Read;$r.CanApply|Should Be $true
        $global:JunoPowerFake.Writes|Should Be 0;$global:JunoPowerFake.Saves|Should Be 0
    }
    It 'identifica Alto rendimiento <Present> sin asumir que la creación tendrá éxito' -TestCases @(@{Present=$true;Expected='Available'},@{Present=$false;Expected='Missing'}) {
        param($Present,$Expected)
        if(-not $Present){$global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active)}
        $r=Invoke-JunoPowerRequest Read;$r.HighAvailable|Should Be $Present;$r.Availability|Should Be $Expected
        $r.CanApply|Should Be $true;$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'Modern Standby bloquea creación y aplicación aunque el plan esté enumerado' {
        $global:JunoPowerFake.Modern=$true
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.Availability|Should Be Unsupported;$r.Message|Should Match 'Modern Standby'
        $r.CanApply|Should Be $false;$r.CanRestore|Should Be $false;$global:JunoPowerFake.Writes|Should Be 0;$global:JunoPowerFake.Saves|Should Be 0
    }
    It 'capacidades desconocidas fallan cerradas' {
        $global:JunoPowerFake.Modern=$null
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.Outcome|Should Be Failed;$r.CanApply|Should Be $false
        $global:JunoPowerFake.Writes|Should Be 0
    }
    It 'sin administrador conserva las consultas y bloquea cambios sin elevar' {
        $global:JunoPowerFake.Admin=$false
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.ActiveGuid|Should Not BeNullOrEmpty;$r.Administrator|Should Be $false
        $r.Message|Should Match 'Requiere administrador';$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
        $global:JunoPowerFake.Saves|Should Be 0;$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'confirmación ausente no consulta ni adquiere mutex' {
        (Invoke-JunoPowerRequest Apply).Outcome|Should Be Cancelled
        Assert-MockCalled Enter-JunoLease -Times 0 -Exactly -Scope It
        $global:JunoPowerFake.Reads|Should Be 0;$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'aplica y restaura el GUID original, con diario y verificación' {
        $original=$global:JunoPowerFake.Active
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.Outcome|Should Be Applied;$r.HighActive|Should Be $true;$r.CanApply|Should Be $false
        $global:JunoPowerFake.Backup.PowerScheme|Should Be $original
        $r=Invoke-JunoPowerRequest Restore -Confirmed;$r.Outcome|Should Be Restored;$r.ActiveGuid|Should Be $original;$r.CanRestore|Should Be $false
        @($global:JunoPowerFake.Commands|Where-Object{$_ -match '/delete'}).Count|Should Be 0
    }
    It 'powercfg falla y no se informa éxito' {
        $global:JunoPowerFake.Fail='Read'
        $r=Invoke-JunoPowerRequest Read;$r.Outcome|Should Be Failed;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
    }
    It 'la creación fallida conserva original y GUID elegido antes de la llamada' {
        $global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active);$global:JunoPowerFake.Fail='Create'
        $r=Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate;$r.Outcome|Should Be Failed;$r.Pending|Should Be $true
        $global:JunoPowerFake.Backup.PowerScheme|Should Be $global:JunoPowerFake.Active
        Assert-JunoGuid $global:JunoPowerFake.Backup.CreatedPowerScheme
        @($global:JunoPowerFake.Commands|Where-Object{$_ -like '/setactive*'}).Count|Should Be 0
    }
    It 'creación simulada se verifica y nunca se elimina en restauración' {
        $global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active)
        $r=Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate;$r.Outcome|Should Be Applied
        $created=$global:JunoPowerFake.Backup.CreatedPowerScheme;$r.ActiveGuid|Should Be $created
        (Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Restored
        ($global:JunoPowerFake.Plans -contains $created)|Should Be $true
    }
    It 'tras creación fallida restaura y reintenta conservando el GUID reservado' {
        $global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active);$global:JunoPowerFake.Fail='Create'
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Failed
        $created=$global:JunoPowerFake.Backup.CreatedPowerScheme
        $global:JunoPowerFake.Fail=''
        (Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Restored
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Applied
        $global:JunoPowerFake.Backup.CreatedPowerScheme|Should Be $created
    }
    It 'fallo al guardar intención impide tocar el plan activo' {
        Mock Write-JunoStore {throw 'SIMULATED backup write denied'}
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.Outcome|Should Be Failed
        $global:JunoPowerFake.Writes|Should Be 0
        $global:JunoPowerFake.Active|Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
    }
    It 'un plan creado eliminado se reconoce y restaura sin borrar nada ajeno' {
        $original=$global:JunoPowerFake.Active;$created='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $global:JunoPowerFake.Backup=[pscustomobject]@{PowerScheme=$original;CreatedPowerScheme=$created;Transaction=[pscustomobject]@{Version=1;Confirmed=$original;Pending=$created;Phase='Applying'}}
        $r=Invoke-JunoPowerRequest Read;$r.Message|Should Match 'ya no existe';$r.Pending|Should Be $true;$r.CanRestore|Should Be $true
        (Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Restored
    }
    It 'plan original inexistente bloquea restauración y conserva su GUID' {
        Invoke-JunoPowerRequest Apply -Confirmed|Out-Null
        $original=$global:JunoPowerFake.Backup.PowerScheme;$global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active)
        $r=Invoke-JunoPowerRequest Restore -Confirmed;$r.Outcome|Should Be Failed;$r.Message|Should Match 'original no existe'
        $global:JunoPowerFake.Backup.PowerScheme|Should Be $original
    }
    It 'restauración parcial <Fault> conserva diario y permite reintento seguro' -TestCases @(@{Fault='WriteBefore'},@{Fault='WriteAfter'},@{Fault='NoEffect'}) {
        param($Fault)
        $original=$global:JunoPowerFake.Active;Invoke-JunoPowerRequest Apply -Confirmed|Out-Null
        $global:JunoPowerFake.Fail=$Fault
        $r=Invoke-JunoPowerRequest Restore -Confirmed;$r.Outcome|Should Be Failed;$r.Pending|Should Be $true;$r.CanApply|Should Be $false
        $global:JunoPowerFake.Backup.PowerScheme|Should Be $original
        $global:JunoPowerFake.Fail='';$r=Invoke-JunoPowerRequest Restore -Confirmed
        $r.Outcome|Should Be Restored;$r.ActiveGuid|Should Be $original
    }
    It 'cambio externo bloquea restauración y aplicación sin perder el original' {
        Invoke-JunoPowerRequest Apply -Confirmed|Out-Null;$writes=$global:JunoPowerFake.Writes
        $global:JunoPowerFake.Active='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$global:JunoPowerFake.Plans+=@($global:JunoPowerFake.Active)
        (Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Conflict
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Conflict
        $global:JunoPowerFake.Writes|Should Be $writes;$global:JunoPowerFake.Backup.PowerScheme|Should Not BeNullOrEmpty
    }
    It 'un diario restaurado permite comenzar otra operación tras cambio manual posterior' {
        Invoke-JunoPowerRequest Apply -Confirmed|Out-Null;Invoke-JunoPowerRequest Restore -Confirmed|Out-Null
        $global:JunoPowerFake.Active='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$global:JunoPowerFake.Plans+=@($global:JunoPowerFake.Active)
        (Invoke-JunoPowerRequest Read).CanApply|Should Be $true
    }
    It 'respaldo <Code> bloquea antes del motor con motivo específico' -TestCases @(@{Code='InvalidBackup'},@{Code='MachineMismatch'},@{Code='ScopeMismatch'},@{Code='KindMismatch'}) {
        param($Code)
        $global:PowerFailureCode=$Code
        Mock Read-JunoStore {Stop-JunoBackupValidation $global:PowerFailureCode 'TEST_PRIVATE'}
        $r=Invoke-JunoPowerRequest Apply -Confirmed;$r.BackupIssue|Should Be $Code;$r.CanApply|Should Be $false;$r.CanRestore|Should Be $false
        $r.Message|Should Not Match 'TEST_PRIVATE';$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'histórico consulta sin importar y cancelar revisión conserva datos' {
        $global:JunoPowerFake.Legacy=[pscustomobject]@{Data=[pscustomobject]@{PowerScheme=$global:JunoPowerFake.Active;CreatedPowerScheme=$null}}
        $r=Invoke-JunoPowerRequest Read;$r.Historical|Should Be $true;$r.CanRestore|Should Be $true
        Assert-MockCalled Import-JunoMachineLegacy -Times 0 -Exactly -Scope It
        Mock Confirm-JunoReview {throw [OperationCanceledException]::new('SIMULATED cancel')}
        (Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Cancelled
        $global:JunoPowerFake.Legacy.Data.PowerScheme|Should Not BeNullOrEmpty;$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'oficial activo no modifica ni importa aunque haya otros planes posibles' {
        $f=$global:JunoPowerFake;$f.Active=$script:HighPerformanceGuid;$f.Plans+=@('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        1..3|ForEach-Object{(Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Unchanged}
        (Invoke-JunoPowerRequest Read).Message|Should Match 'Ya estás utilizando Alto rendimiento'
        $f.Saves|Should Be 0;$f.Writes|Should Be 0
        Assert-MockCalled Import-JunoMachineLegacy -Times 0 -Exactly -Scope It
        Enable-HighPerformance|Should Match 'Ya estás utilizando Alto rendimiento'
        $f.Saves|Should Be 0
    }
    It 'un plan creado y confirmado activo no genera nueva reserva' {
        $f=$global:JunoPowerFake;$created='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$original=$f.Active
        $f.Active=$created;$f.Plans=@($original,$created)
        $f.Backup=[pscustomobject]@{PowerScheme=$original;CreatedPowerScheme=$created;Transaction=[pscustomobject]@{Version=1;Confirmed=$created;Pending=$null;Phase='Applied'}}
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Unchanged
        $f.Writes|Should Be 0;$f.Saves|Should Be 0;$f.Backup.PowerScheme|Should Be $original
    }
    It '<Count> planes personalizados del mismo nombre requieren elección y prohíben crear' -TestCases @(@{Count=1},@{Count=2},@{Count=3}) {
        param($Count)
        $f=$global:JunoPowerFake;$f.Plans=@($f.Active)
        foreach($n in 1..$Count){$guid=('aaaaaaaa-bbbb-cccc-dddd-'+$n.ToString('000000000000'));$f.Plans+=@($guid);$f.Names[$guid]='Alto rendimiento'}
        $r=Invoke-JunoPowerRequest Read;$r.RequiresSelection|Should Be $true;$r.RequiresCreation|Should Be $false
        $r.HighAvailable|Should Be $false;$r.Choices.Count|Should Be $Count;$r.Choices[0].Name|Should Be 'Alto rendimiento'
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Failed
        $f.Saves|Should Be 0;$f.Writes|Should Be 0
        @($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 0
    }
    It 'oficial más un personalizado prioriza el GUID oficial sin duplicar' {
        $global:JunoPowerFake.Plans+=@('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        $r=Invoke-JunoPowerRequest Read;$r.HighAvailable|Should Be $true;$r.RequiresSelection|Should Be $false
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Applied
        $global:JunoPowerFake.Active|Should Be '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        @($global:JunoPowerFake.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 0
    }
    It 'elección explícita guarda original, verifica, repite sin escrituras y restaura sin crear' {
        $f=$global:JunoPowerFake;$original=$f.Active;$chosen='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $f.Plans=@($original,$chosen,'bbbbbbbb-cccc-dddd-eeee-ffffffffffff');$f.Names[$chosen]='Alto rendimiento'
        $r=Invoke-JunoPowerRequest Apply -Confirmed -TargetGuid $chosen;$r.Outcome|Should Be Applied;$r.ActiveGuid|Should Be $chosen;$r.CanApply|Should Be $false
        $f.Backup.PowerScheme|Should Be $original;$f.Backup.CreatedPowerScheme|Should BeNullOrEmpty
        $writes=$f.Writes;$saves=$f.Saves
        (Invoke-JunoPowerRequest Apply -Confirmed -TargetGuid $chosen).Outcome|Should Be Unchanged
        $f.Writes|Should Be $writes;$f.Saves|Should Be $saves
        (Invoke-JunoPowerRequest Restore -Confirmed).ActiveGuid|Should Be $original
        $f.Plans.Count|Should Be 3;@($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 0
    }
    It 'elegir el plan activo por su GUID es un no-op sin inventar equivalencia' {
        $f=$global:JunoPowerFake;$f.Active='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$f.Plans=@($f.Active)
        $r=Invoke-JunoPowerRequest Apply -Confirmed -TargetGuid $f.Active
        $r.Outcome|Should Be Unchanged;$r.HighActive|Should Be $false;$r.Message|Should Match 'ya está activo'
        $f.Saves|Should Be 0;$f.Writes|Should Be 0
    }
    It 'selección desaparecida o inválida nunca se transforma en duplicación' -TestCases @(@{Target='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'},@{Target='no-guid'}) {
        param($Target)
        $r=Invoke-JunoPowerRequest Apply -Confirmed -TargetGuid $Target -AllowCreate
        $r.Outcome|Should Be Failed;$global:JunoPowerFake.Saves|Should Be 0;$global:JunoPowerFake.Writes|Should Be 0
    }
    It 'sin reutilizables crear exige autorización adicional' {
        $f=$global:JunoPowerFake;$f.Plans=@($f.Active,'a1841308-3541-4fab-bc81-f71556f20b4a')
        $r=Invoke-JunoPowerRequest Read;$r.RequiresCreation|Should Be $true;$r.RequiresSelection|Should Be $false
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Failed
        $f.Saves|Should Be 0;$f.Writes|Should Be 0
        {Enable-HighPerformance}|Should Throw
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Applied
        1..3|ForEach-Object{(Invoke-JunoPowerRequest Restore -Confirmed).Outcome|Should Be Restored;(Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Applied}
        @($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 1
    }
    It 'fallo tras duplicar reusa la reserva sin crear otra copia al reintentar' {
        $f=$global:JunoPowerFake;$original=$f.Active;$f.Plans=@($original);$f.Fail='CreateAfter'
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Failed
        $created=$f.Backup.CreatedPowerScheme;$f.Plans.Count|Should Be 2
        $f.Fail='';$null=Enable-HighPerformance -AllowCreate
        $f.Active|Should Be $created;$f.Backup.Transaction.Phase|Should Be Applied
        $f.Backup.CreatedPowerScheme|Should Be $created
        $null=Restore-PowerPlan;$f.Active|Should Be $original
        @($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 1;$f.Active|Should Be $original
    }
    It 'un plan aparecido al persistir reserva impide duplicar inmediatamente después' {
        $f=$global:JunoPowerFake;$f.Plans=@($f.Active)
        Mock Write-JunoStore {param($kind,$data,$scope)$global:JunoPowerFake.Backup=Copy-JunoObject $data;$global:JunoPowerFake.Saves++;$global:JunoPowerFake.Plans+=@('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')}
        (Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate).Outcome|Should Be Failed
        @($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 0;$f.Writes|Should Be 0
    }
    It 'la desaparición del destino tras guardar Pending bloquea setactive' {
        Mock Write-JunoStore {param($kind,$data,$scope)$global:JunoPowerFake.Backup=Copy-JunoObject $data;$global:JunoPowerFake.Saves++;$global:JunoPowerFake.Plans=@($global:JunoPowerFake.Active)}
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Failed
        $global:JunoPowerFake.Writes|Should Be 0;$global:JunoPowerFake.Backup.Transaction.Pending|Should Not BeNullOrEmpty
    }
    It 'nombres y prefijos <Language> no determinan identidad ni selección' -TestCases @(@{Language='es';Prefix='Esquema de energía GUID:';Name='Alto rendimiento'},@{Language='en';Prefix='Power Scheme GUID:';Name='High performance'},@{Language='de';Prefix='Energieschema-GUID:';Name='Höchstleistung'},@{Language='ja';Prefix='電源設定の GUID:';Name='高パフォーマンス'}) {
        param($Language,$Prefix,$Name)
        $f=$global:JunoPowerFake;$f.Prefix=$Prefix;$guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$f.Plans=@($f.Active,$guid);$f.Names[$guid]=$Name
        $r=Invoke-JunoPowerRequest Read;$r.Choices[0].Name|Should Be $Name;$r.RequiresSelection|Should Be $true;$r.HighAvailable|Should Be $false
        (Invoke-JunoPowerRequest Apply -Confirmed -TargetGuid $guid).Outcome|Should Be Applied
        @($f.Commands|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 0
    }
    It 'enumeración ambigua bloquea en lugar de crear' {
        Mock Invoke-PowerCfg {param($arguments)if($arguments[0] -eq '/getactivescheme'){return '381b4222-f694-41f0-9685-ff5bb260df2e (Equilibrado)'};return 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee (Nombre 11111111-2222-3333-4444-555555555555)'}
        $r=Invoke-JunoPowerRequest Apply -Confirmed -AllowCreate;$r.Outcome|Should Be Failed;$r.CanApply|Should Be $false
        $global:JunoPowerFake.Saves|Should Be 0
    }
    It 'mutex ocupado rechaza sin consultas ni escritura' {
        Mock Enter-JunoLease {throw 'Recurso ocupado'}
        (Invoke-JunoPowerRequest Apply -Confirmed).Outcome|Should Be Busy
        $global:JunoPowerFake.Reads|Should Be 0;$global:JunoPowerFake.Writes|Should Be 0
        Assert-MockCalled Exit-JunoLease -Times 0 -Exactly -Scope It
    }
}

function Test-PowerButtonFlag($form,[string]$name,[string]$flag){$buttons=@($form.Controls.Find($name,$true));return ($buttons.Count -gt 0 -and [bool]$buttons[0].$flag)}
function Get-PowerButton($form,[string]$name){@($form.Controls.Find($name,$true))[0]}
function Wait-PowerUi($form){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}while(($form.Power.IsBusy -or $form.Transparency.IsBusy) -and $watch.ElapsedMilliseconds -lt 4000)
    if($form.Power.IsBusy -or $form.Transparency.IsBusy){throw 'TEST: falta resultado UI'}
}
function New-PowerUiResult {
    $r=New-Object Juno.Preview.PowerResult;$r.ActiveGuid='381b4222-f694-41f0-9685-ff5bb260df2e';$r.ActiveName='Equilibrado ficticio';$r.CanApply=$true;$r.HighAvailable=$true;$r.Availability='Available';$r.Administrator=$true;$r.Message='Consulta simulada';return $r
}
Describe 'Tarjeta de energía con tareas controladas sin Windows real' {
    BeforeEach {
        $script:powerProvider=New-Object Juno.Preview.Testing.ControlledPower
        $script:powerController=New-Object Juno.Preview.PowerController($powerProvider)
        $script:powerTrans=New-Object Juno.Preview.Testing.ControlledTransparency
        $script:powerConfirmation=New-Object Juno.Preview.Testing.ControlledConfirmation
        $script:powerLauncher=New-Object Juno.Preview.Testing.ControlledPowerPlans
        $script:powerSelection=New-Object Juno.Preview.Testing.ControlledPowerSelection
        $script:powerForm=New-Object Juno.Preview.ShellForm($powerRoot,(New-Object Juno.Preview.DashboardController((New-Object Juno.Preview.UnavailableDashboardQuery))),(New-Object Juno.Preview.TransparencyController($powerTrans)),$powerConfirmation,$powerController,$powerLauncher,$powerSelection)
    }
    AfterEach {$powerForm.Dispose();$powerProvider.Complete((New-Object Juno.Preview.PowerResult));$powerTrans.Complete((New-Object Juno.Preview.TransparencyResult))}
    It 'construir y navegar oculto no ejecuta operaciones' {
        foreach($section in [Juno.Preview.ShellForm]::Sections){$powerForm.Navigate($section)}
        $powerProvider.Calls|Should Be 0;$powerProvider.WriteCalls|Should Be 0;$powerTrans.Calls|Should Be 0
    }
    It 'abrir Rendimiento consulta ambos módulos secuencialmente sin escribir' {
        $powerForm.Show();$powerForm.Navigate('Rendimiento');$powerProvider.Calls|Should Be 0
        $powerTrans.Complete((New-Object Juno.Preview.TransparencyResult))
        $powerProvider.Complete((New-PowerUiResult));Wait-PowerUi $powerForm
        $powerProvider.Calls|Should Be 1;$powerProvider.LastAction|Should Be Read;$powerProvider.WriteCalls|Should Be 0
        (Test-PowerButtonFlag $powerForm PowerApply Enabled)|Should Be $true;(Test-PowerButtonFlag $powerForm PowerApply Accent)|Should Be $true
        (Test-PowerButtonFlag $powerForm PowerRestore Enabled)|Should Be $false
    }
    It 'cancelar confirmación no llega al servicio' {
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete((New-PowerUiResult));$powerController.Poll()|Out-Null
        $powerForm.Navigate('Rendimiento');$powerForm.RequestPower('Apply')|Should Be $false
        $powerProvider.WriteCalls|Should Be 0;$powerConfirmation.Calls|Should Be 1
    }
    It 'estado <Kind> bloquea botones incompatibles y resalta solo acciones válidas' -TestCases @(@{Kind='Admin'},@{Kind='Standby'},@{Kind='Unknown'},@{Kind='Pending'},@{Kind='Active'}) {
        param($Kind)
        $r=New-PowerUiResult;$r.CanApply=$false
        switch($Kind){Admin{$r.Administrator=$false;$r.Message='Requiere administrador'} Standby{$r.Availability='Unsupported';$r.Message='Modern Standby'} Unknown{$r.Outcome='Failed';$r.Message='Consulta fallida'} Pending{$r.Pending=$true;$r.CanRestore=$true;$r.Message='Diario pendiente'} Active{$r.HighActive=$true;$r.CanRestore=$true}}
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete($r);$powerController.Poll()|Out-Null;$powerForm.Navigate('Rendimiento')
        (Test-PowerButtonFlag $powerForm PowerApply Enabled)|Should Be $false;(Test-PowerButtonFlag $powerForm PowerApply Accent)|Should Be $false
        (Test-PowerButtonFlag $powerForm PowerRestore Enabled)|Should Be $r.CanRestore
    }
    It 'aplicación mantiene instantánea, bloquea duplicados y cierre y actualiza al terminar' {
        $powerForm.Show();$powerForm.Navigate('Rendimiento');$powerTrans.Complete((New-Object Juno.Preview.TransparencyResult));$powerProvider.Complete((New-PowerUiResult));Wait-PowerUi $powerForm
        $powerProvider.Next();$powerConfirmation.Accept=$true
        $powerForm.RequestPower('Apply')|Should Be $true;$powerForm.RequestPower('Apply')|Should Be $false;$powerForm.RequestTransparency('Read')|Should Be $false
        $powerController.Snapshot.ActiveName|Should Be 'Equilibrado ficticio'
        foreach($name in @('PowerRead','PowerApply','PowerPlans','PowerRestore','TransparencyRead','TransparencyEnable')){(Test-PowerButtonFlag $powerForm $name Enabled)|Should Be $false}
        $powerForm.Close();$powerForm.IsDisposed|Should Be $false
        $powerForm.Navigate('Inicio');$powerForm.Navigate('Aplicaciones')
        $r=New-PowerUiResult;$r.ActiveName='Alto rendimiento ficticio';$r.HighActive=$true;$r.CanApply=$false;$r.CanRestore=$true;$r.Outcome='Applied'
        $powerProvider.Complete($r);Wait-PowerUi $powerForm;$powerForm.Navigate('Rendimiento')
        (Test-PowerButtonFlag $powerForm PowerApply Accent)|Should Be $false;(Test-PowerButtonFlag $powerForm PowerRestore Enabled)|Should Be $true
        $powerProvider.WriteCalls|Should Be 1;$powerForm.Close();$powerForm.ResourcesReleased|Should Be $true
    }
    It 'Ver planes usa el lanzador inyectado sin comandos o escritor' {
        $details=$powerForm.CreateToolDetails($true)
        try{
            $button=Get-PowerButton $details PowerPlans
            [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
            $powerLauncher.Calls|Should Be 1;$powerProvider.WriteCalls|Should Be 0
        }finally{$details.Dispose()}
    }
    It 'cerrar durante lectura libera UI sin detener ni escribir' {
        $powerForm.Show();$powerForm.Navigate('Rendimiento');$powerTrans.Complete((New-Object Juno.Preview.TransparencyResult))
        $watch=[Diagnostics.Stopwatch]::StartNew();while($powerProvider.Calls -eq 0 -and $watch.ElapsedMilliseconds -lt 3000){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
        $powerProvider.Calls|Should Be 1;$powerForm.Close();$powerProvider.Disposed|Should Be $true
        $powerProvider.Complete((New-PowerUiResult));$powerController.Poll()|Should Be $false;$powerProvider.WriteCalls|Should Be 0
    }
    It 'elegir y cancelar no confirman ni envían escrituras' {
        $r=New-PowerUiResult;$r.RequiresSelection=$true;$r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Name='Alto rendimiento'},[Juno.Preview.PowerPlanChoice]@{Guid='bbbbbbbb-cccc-dddd-eeee-ffffffffffff';Name='Alto rendimiento'})
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete($r);$powerController.Poll()|Out-Null;$powerForm.Navigate('Rendimiento')
        $powerForm.RequestPower('Apply')|Should Be $false;$powerSelection.Calls|Should Be 1
        $powerConfirmation.Calls|Should Be 0;$powerProvider.WriteCalls|Should Be 0
        (Get-PowerButton $powerForm PowerApply).Text|Should Match 'Elegir plan existente'
    }
    It 'selección explícita viaja por el controlador sin autorizar creación' {
        $r=New-PowerUiResult;$r.RequiresSelection=$true;$guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $r.Choices=@([Juno.Preview.PowerPlanChoice]@{Guid=$guid;Name='Alto rendimiento'})
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete($r);$powerController.Poll()|Out-Null
        $powerProvider.Next();$powerSelection.Selected=$guid;$powerConfirmation.Accept=$true
        $powerForm.RequestPower('Apply')|Should Be $true;$powerProvider.LastTarget|Should Be $guid;$powerProvider.LastCreate|Should Be $false
    }
    It 'crear exige confirmar su intención diferenciada y se transmite de forma explícita' {
        $r=New-PowerUiResult;$r.RequiresCreation=$true
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete($r);$powerController.Poll()|Out-Null;$powerForm.Navigate('Rendimiento')
        (Get-PowerButton $powerForm PowerApply).Text|Should Match 'Crear Alto rendimiento'
        $powerForm.RequestPower('Apply')|Should Be $false;$powerProvider.WriteCalls|Should Be 0
        $powerProvider.Next();$powerConfirmation.Accept=$true
        $powerForm.RequestPower('Apply')|Should Be $true;$powerProvider.LastCreate|Should Be $true;$powerProvider.LastTarget|Should BeNullOrEmpty
    }
    It 'diálogo no preselecciona y distingue nombres iguales con detalles del GUID' {
        $choices=@([Juno.Preview.PowerPlanChoice]@{Guid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Name='Alto rendimiento'},[Juno.Preview.PowerPlanChoice]@{Guid='bbbbbbbb-cccc-dddd-eeee-ffffffffffff';Name='Alto rendimiento'})
        $global:PowerDialogObserved=$null;$timer=New-Object Windows.Forms.Timer;$timer.Interval=100
        $timer.Add_Tick({
            $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object{$_.Name -eq 'PowerSelection'})
            if($dialog.Count -eq 0){return};$dialog=$dialog[0]
            try{
                $list=$dialog.Controls.Find('PowerPlanList',$true)[0];$details=$dialog.Controls.Find('PowerPlanDetails',$true)[0]
                $unselected=($list.SelectedIndex -eq -1);$cancelDefault=($dialog.AcceptButton.Text -eq 'Cancelar')
                $list.SelectedIndex=1
                $global:PowerDialogObserved=[pscustomobject]@{Unselected=$unselected;CancelDefault=$cancelDefault;Details=$details.Text;Names=($list.Items -join '|')}
                $dialog.DialogResult=[Windows.Forms.DialogResult]::OK
            }finally{$dialog.Close()}
        })
        try{
            $timer.Start();$selector=New-Object Juno.Preview.PowerPlanSelectionDialog($powerForm)
            $selected=$selector.Choose($choices)
            $selected|Should Be $choices[1].Guid;$global:PowerDialogObserved.Unselected|Should Be $true;$global:PowerDialogObserved.CancelDefault|Should Be $true
            $global:PowerDialogObserved.Details|Should Match $choices[1].Guid
            $global:PowerDialogObserved.Names|Should Match 'opción 1';$global:PowerDialogObserved.Names|Should Match 'opción 2'
        }finally{$timer.Stop();$timer.Dispose()}
    }
    It 'fallo de tarea borra elegibilidad anterior y permite consultar nuevamente' {
        $powerController.Start('Read',$powerConfirmation)|Out-Null;$powerProvider.Complete((New-PowerUiResult));$powerController.Poll()|Out-Null
        $powerProvider.Next();$powerController.Start('Read',$powerConfirmation)|Out-Null
        $powerProvider.Completion.TrySetException([InvalidOperationException]::new('SIMULATED failure'))|Out-Null
        $powerController.Poll()|Should Be $true;$powerForm.Navigate('Rendimiento')
        (Test-PowerButtonFlag $powerForm PowerApply Enabled)|Should Be $false
        (Test-PowerButtonFlag $powerForm PowerApply Accent)|Should Be $false
        $powerController.CanStart('Read')|Should Be $true
        (Get-PowerButton $powerForm PowerState).Text|Should Match 'No se pudo completar el cambio'
    }
}

Describe 'Separación de arquitectura y ABI x86/x64 de energía' {
    It 'el layout nativo reserva el tamaño completo y AoAc de Windows 10/11' {
        $type=[Juno.Preview.PowerPlatform].GetNestedType('Capabilities',[Reflection.BindingFlags]::NonPublic)
        [Runtime.InteropServices.Marshal]::SizeOf([type]$type)|Should Be 76
        [Runtime.InteropServices.Marshal]::OffsetOf($type,'AoAc').ToInt32()|Should Be 20
    }
    It 'el puente usa el mismo hilo y bloqueo sin timeout ni cancelación forzada de escrituras' {
        $source=[IO.File]::ReadAllText((Join-Path $powerRoot 'ui\PowerShellPowerService.cs'))
        $source|Should Match 'PSThreadOptions.ReuseThread'
        $source|Should Match "'UiSupport.ps1'"
        $source|Should Not Match 'ProcessDashboardQuery|\.Kill\(|\.Stop\(|\.BeginStop\(|CancelAfter\(|WaitForExit\(|runas'
        $adapter=[IO.File]::ReadAllText((Join-Path $powerRoot 'PowerAdapter.ps1'))
        $adapter|Should Not Match '/setactive|/duplicatescheme|/delete|Write-JunoStore|SetValue\('
        $adapter|Should Match 'Enter-JunoLease';$adapter|Should Match 'finally \{if\(\$owned\)\{Exit-JunoLease\}\}'
    }
}
