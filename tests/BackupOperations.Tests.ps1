#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$operationRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $operationRoot 'BackupStore.ps1')
. (Join-Path $operationRoot 'RecoveryOperations.ps1')
. (Join-Path $operationRoot 'BackgroundInventory.ps1')
foreach($spec in @(
    @{File='Juno.ps1';Names=@('Enable-HighPerformance','Restore-PowerPlan','Apply-VisualEffects','Restore-VisualEffects')},
    @{File='TransparencyOperations.ps1';Names=@('Get-Backup','Save-Backup','Set-Transparency','Restore-Transparency')},
    @{File='PermisosSegundoPlano.ps1';Names=@('Read-BPPBackup','Write-BPPBackup','Disable-BPPApps','Restore-BPPApps')},
    @{File='Discos.ps1';Names=@('Update-DiskDetails')}
)){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $operationRoot $spec.File),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw($errors.Message -join '; ')}
    foreach($name in $spec.Names){$n=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($n.Extent.Text))}
}
# Todas las fronteras reales se reemplazan tambien fuera de los mocks, para fallar cerradas.
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Test-JunoAdmin {throw 'TEST: identidad real prohibida'}
function Get-JunoMachineFolder {throw 'TEST: ProgramData real prohibido'}
function Confirm-JunoReview([string]$message) {throw 'TEST: dialogo real prohibido'}
function Get-ActivePlan {throw 'TEST: powercfg real prohibido'}
function Invoke-PowerCfg([string[]]$arguments) {throw 'TEST: powercfg real prohibido'}
function Get-CurrentEffects {throw 'TEST: SPI real prohibido'}
function Get-VisualRegistrySnapshot {throw 'TEST: Registro real prohibido'}
function Set-JunoEffects($effects) {throw 'TEST: SPI real prohibido'}
function Restore-VisualRegistry($snapshots) {throw 'TEST: Registro real prohibido'}
function Get-TransparencySnapshot {throw 'TEST: Registro real prohibido'}
function Set-JunoTransparencySnapshot($target) {throw 'TEST: Registro real prohibido'}
function Notify-TransparencyChange {throw 'TEST: mensajes reales prohibidos'}
function Open-JunoPolicyKey([bool]$write) {throw 'TEST: Registro real prohibido'}
function Get-JunoPolicyState {throw 'TEST: Registro real prohibido'}
function Set-JunoPolicyValue([string]$field,$target) {throw 'TEST: Registro real prohibido'}
function Confirm-BPPWrite {throw 'TEST: directivas reales prohibidas'}
function Get-BPPPackages {throw 'TEST: Appx real prohibido'}
function Get-DiskTrimState {throw 'TEST: fsutil real prohibido'}
function Invoke-JunoTrimValue([int]$value) {throw 'TEST: fsutil real prohibido'}
function Get-DiskSelectedVolume {throw 'TEST: UI real prohibida'}

function New-OperationSnapshot([bool]$exists,$value) {return [pscustomobject]@{Exists=$exists;Value=$value}}
function Reset-OperationFake {
    $effects=[pscustomobject]@{}
    foreach($n in @('UIEffects','ClientAreaAnimation','MenuAnimation','ComboBoxAnimation','ListSmoothScrolling','MenuFade','SelectionFade','ToolTipAnimation','ToolTipFade','CursorShadow','DropShadow','MinimizeAnimation','FontSmoothing','DragFullWindows')){Add-Member -InputObject $effects NoteProperty $n $true}
    $registry=@()
    foreach($r in @(Get-JunoVisualTargets|Where-Object{$_[1] -ne 'EnableTransparency'})){
        $value=if($r[2] -eq 'Binary'){'AAAAAAAAAAA='}elseif($r[1] -eq 'FontSmoothing'){'2'}else{'1'}
        $registry+=@([pscustomobject]@{Key=$r[0];Name=$r[1];Exists=$true;Kind=$r[2];Value=$value})
    }
    $global:JunoOperationFake=[pscustomobject]@{
        General=[pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=$null}
        Power=$null;PowerActive='381b4222-f694-41f0-9685-ff5bb260df2e';Plans=@('381b4222-f694-41f0-9685-ff5bb260df2e','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        Policy=$null;PolicyState=[pscustomobject]@{Deny=(New-OperationSnapshot $false $null);Global=(New-OperationSnapshot $false $null);Allow=(New-OperationSnapshot $false $null);UserControl=(New-OperationSnapshot $false $null)}
        Trim=$null;TrimState=1;VisualState=[pscustomobject]@{Effects=$effects;Registry=$registry};Transparency=[pscustomobject]@{Exists=$true;Kind='DWord';Value='1'}
        Writes=0;Saves=0;FaultWrites=@();FaultSaves=@();FaultMode='Before';SaveMode='Before';VisualFault=$false;History=@();PowerArguments=@()
    }
    $script:HighPerformanceGuid='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
}
function Save-OperationFake([string]$kind,$data,[string]$scope) {
    Assert-JunoBackupData $kind $data $scope
    $global:JunoOperationFake.Saves++
    $fail=$global:JunoOperationFake.FaultSaves -contains $global:JunoOperationFake.Saves
    if($fail -and $global:JunoOperationFake.SaveMode -eq 'Before'){throw 'SIMULATED backup before save'}
    $copy=Copy-JunoObject $data;$global:JunoOperationFake.$kind=$copy
    $global:JunoOperationFake.History+=@([pscustomobject]@{Kind=$kind;Data=$copy})
    if($fail){throw 'SIMULATED backup after save'}
}
function Write-OperationFake([scriptblock]$action) {
    $global:JunoOperationFake.Writes++
    $fail=$global:JunoOperationFake.FaultWrites -contains $global:JunoOperationFake.Writes
    if($fail -and $global:JunoOperationFake.FaultMode -eq 'Before'){throw 'SIMULATED before write'}
    if(-not($fail -and $global:JunoOperationFake.FaultMode -eq 'Ignore')){& $action}
    if($fail -and $global:JunoOperationFake.FaultMode -eq 'After'){throw 'SIMULATED after write'}
}

Describe 'Diarios de energia, visuales, transparencia, directiva y TRIM sin Windows real' {
    BeforeEach {
        Reset-OperationFake
        Enter-JunoLease ('Local\Juno.Tests.Operations.'+[Guid]::NewGuid().ToString('N'))
        Mock Test-JunoAdmin {$true}
        Mock Confirm-JunoReview {}
        Mock Import-JunoMachineLegacy {Assert-JunoLease}
        Mock Get-JunoMachineLegacy {$null}
        Mock Read-JunoStore {
            param($kind,$scope,$default)
            $saved=$global:JunoOperationFake.$kind
            if($null -eq $saved){return $default}
            Assert-JunoBackupData $kind $saved $scope
            return (Copy-JunoObject $saved)
        }
        Mock Write-JunoStore {param($kind,$data,$scope) Save-OperationFake $kind $data $scope}
        Mock Get-ActivePlan {[pscustomobject]@{Guid=$global:JunoOperationFake.PowerActive}}
        Mock Invoke-PowerCfg {
            param($arguments)
            $global:JunoOperationFake.PowerArguments+=@($arguments -join ' ')
            switch($arguments[0]){
                '/list' {return ($global:JunoOperationFake.Plans -join "`n")}
                '/setactive' {Assert-JunoGuid $arguments[1];Write-OperationFake {$global:JunoOperationFake.PowerActive=$arguments[1]}}
                '/duplicatescheme' {Assert-JunoGuid $arguments[2];Write-OperationFake {$global:JunoOperationFake.Plans+=@($arguments[2])};return $arguments[2]}
                default {throw 'TEST: comando powercfg no permitido'}
            }
        }
        Mock Get-CurrentEffects {Copy-JunoObject $global:JunoOperationFake.VisualState.Effects}
        Mock Get-VisualRegistrySnapshot {return ,(Copy-JunoObject $global:JunoOperationFake.VisualState.Registry)}
        Mock Set-JunoEffects {
            param($effects)
            Assert-JunoEffects $effects
            $i=0
            foreach($p in $effects.PSObject.Properties){$global:JunoOperationFake.VisualState.Effects.($p.Name)=$p.Value;$i++;if($global:JunoOperationFake.VisualFault -and $i -eq 3){$global:JunoOperationFake.VisualFault=$false;throw 'SIMULATED partial SPI'}}
            $global:JunoOperationFake.Writes++
        }
        Mock Restore-VisualRegistry {
            param($snapshots)
            Assert-JunoVisualRegistry $snapshots
            foreach($r in $snapshots){for($i=0;$i -lt $global:JunoOperationFake.VisualState.Registry.Count;$i++){if($global:JunoOperationFake.VisualState.Registry[$i].Name -ceq $r.Name){$global:JunoOperationFake.VisualState.Registry[$i]=Copy-JunoObject $r}}}
            $global:JunoOperationFake.Writes++
        }
        Mock Get-TransparencySnapshot {Copy-JunoObject $global:JunoOperationFake.Transparency}
        Mock Set-JunoTransparencySnapshot {param($target)Assert-JunoVisualSnapshot $target -Transparency;Write-OperationFake {$global:JunoOperationFake.Transparency=Copy-JunoObject $target}}
        Mock Notify-TransparencyChange {$true}
        Mock Confirm-BPPWrite {
            if($global:JunoOperationFake.PolicyState.Global.Exists -and $global:JunoOperationFake.PolicyState.Global.Value -ne 0){throw 'Directiva general externa'}
            return [pscustomobject]@{}
        }
        # Esta suite aísla el motor de diario histórico. Las restricciones de elegibilidad
        # y propiedad de etapa 4 se ejercitan sin este mock en Background.Tests.ps1.
        Mock Assert-BPPPolicyOwnership {}
        Mock Get-BPPPackages {@([pscustomobject]@{Family='Test_pkg';Compatibility='Compatible';Type='UWP';Installed=$true;Protected=$false},[pscustomobject]@{Family='Other_pkg';Compatibility='Compatible';Type='UWP';Installed=$true;Protected=$false})}
        Mock Get-JunoPolicyState {Copy-JunoObject $global:JunoOperationFake.PolicyState}
        Mock Set-JunoPolicyValue {param($field,$target)Assert-JunoValueSnapshot $target $field;Write-OperationFake {$global:JunoOperationFake.PolicyState.$field=Copy-JunoObject $target}}
        Mock Get-DiskTrimState {[pscustomobject]@{State=$global:JunoOperationFake.TrimState}}
        Mock Invoke-JunoTrimValue {param($value)Assert-JunoInt $value 0 1;Write-OperationFake {$global:JunoOperationFake.TrimState=$value}}
    }
    AfterEach {Exit-JunoLease}
    It 'energia conserva original, confirma cambio y restaura sin eliminar planes' {
        Enable-HighPerformance|Should Match 'verificado'
        $global:JunoOperationFake.Power.PowerScheme|Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        Restore-PowerPlan|Should Match 'restaurado y verificado'
        Restore-PowerPlan|Should Match 'no hay una restauracion pendiente'
        @($global:JunoOperationFake.PowerArguments|Where-Object{$_ -like '/delete*'}).Count|Should Be 0
    }
    It 'energia detecta cambios posteriores y preserva el respaldo' {
        Enable-HighPerformance|Out-Null;$global:JunoOperationFake.PowerActive='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        {Restore-PowerPlan}|Should Throw
        $global:JunoOperationFake.Writes|Should Be 1
        $global:JunoOperationFake.Power.PowerScheme|Should Not BeNullOrEmpty
    }
    It 'un GUID historico no autoriza reutilizar ni eliminar un plan ajeno' {
        $foreign='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $global:JunoOperationFake.Power=[pscustomobject]@{PowerScheme=$global:JunoOperationFake.PowerActive;CreatedPowerScheme=$foreign}
        $global:JunoOperationFake.Plans=@($global:JunoOperationFake.PowerActive,$foreign)
        Enable-HighPerformance|Out-Null
        $global:JunoOperationFake.Power.CreatedPowerScheme|Should Not Be $foreign
        @($global:JunoOperationFake.PowerArguments|Where-Object{$_ -eq ('/setactive '+$foreign) -or $_ -like '/delete*'}).Count|Should Be 0
        Assert-MockCalled Confirm-JunoReview -Times 1 -Exactly -Scope It
    }
    It 'energia reintenta errores antes/despues de escribir sin perder el original' -TestCases @(@{Mode='Before'},@{Mode='After'},@{Mode='Ignore'}) {
        param($Mode)
        $global:JunoOperationFake.FaultMode=$Mode;$global:JunoOperationFake.FaultWrites=@(1)
        {Enable-HighPerformance}|Should Throw
        $global:JunoOperationFake.Power.Transaction.Pending|Should Not BeNullOrEmpty
        Enable-HighPerformance|Out-Null;Restore-PowerPlan|Out-Null
        $global:JunoOperationFake.PowerActive|Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
    }
    It 'energia persiste el GUID de duplicacion antes de crear y lo reutiliza' {
        $global:JunoOperationFake.Plans=@('381b4222-f694-41f0-9685-ff5bb260df2e')
        $global:JunoOperationFake.FaultMode='After';$global:JunoOperationFake.FaultWrites=@(1)
        {Enable-HighPerformance}|Should Throw
        $created=$global:JunoOperationFake.Power.CreatedPowerScheme;Assert-JunoGuid $created
        Enable-HighPerformance|Out-Null
        $global:JunoOperationFake.Power.CreatedPowerScheme|Should Be $created
        @($global:JunoOperationFake.PowerArguments|Where-Object{$_ -like '/duplicatescheme*'}).Count|Should Be 1
        Restore-PowerPlan|Out-Null;($global:JunoOperationFake.Plans -contains $created)|Should Be $true
    }
    It 'transparencia guarda intencion antes de escribir y conserva ausencia original' {
        $global:JunoOperationFake.Transparency=[pscustomobject]@{Exists=$false;Kind=$null;Value=$null}
        Set-Transparency $true|Out-Null
        $global:JunoOperationFake.History[0].Data.Journal.Transparency.Pending.Value|Should Be '1'
        $global:JunoOperationFake.History[0].Data.TransparencyBackup.Exists|Should Be $false
        Restore-Transparency|Should Match 'restaurado y verificado'
        $global:JunoOperationFake.Transparency.Exists|Should Be $false
        Restore-Transparency|Should Match 'no hay una restauracion pendiente'
    }
    It 'transparencia reintenta fallo de checkpoint despues de cambiar Windows' {
        $global:JunoOperationFake.FaultSaves=@(2)
        {Set-Transparency $false}|Should Throw
        $global:JunoOperationFake.General.Journal.Transparency.Pending.Value|Should Be '0'
        Restore-Transparency|Out-Null
        $global:JunoOperationFake.Transparency.Value|Should Be '1'
    }
    It 'transparencia detecta modificacion externa sin otra escritura' {
        Set-Transparency $false|Out-Null;$global:JunoOperationFake.Transparency.Value='2'
        {Restore-Transparency}|Should Throw;$global:JunoOperationFake.Writes|Should Be 1
    }
    It 'transparencia no confirma una API que no efectuo la escritura' {
        $global:JunoOperationFake.FaultMode='Ignore';$global:JunoOperationFake.FaultWrites=@(1)
        {Set-Transparency $false}|Should Throw
        $global:JunoOperationFake.General.Journal.Transparency.Pending.Value|Should Be '0'
        Restore-Transparency|Out-Null;$global:JunoOperationFake.Transparency.Value|Should Be '1'
    }
    It 'efectos restaura todos los originales y ausencias sin reescribir el primer respaldo' {
        $global:JunoOperationFake.VisualState.Registry[0].Exists=$false;$global:JunoOperationFake.VisualState.Registry[0].Kind=$null;$global:JunoOperationFake.VisualState.Registry[0].Value=$null
        $original=Copy-JunoObject $global:JunoOperationFake.VisualState
        Apply-VisualEffects $true|Out-Null
        $saved=Copy-JunoObject $global:JunoOperationFake.General.VisualRegistry
        Apply-VisualEffects $false|Out-Null
        Test-JunoEqual $saved $global:JunoOperationFake.General.VisualRegistry|Should Be $true
        Restore-VisualEffects|Should Match 'restaurados y verificados'
        Test-JunoEqual $original $global:JunoOperationFake.VisualState|Should Be $true
        Restore-VisualEffects|Should Match 'no hay una restauracion pendiente'
    }
    It 'efectos conserva estado parcial observable y permite reintentar restauracion' {
        $original=Copy-JunoObject $global:JunoOperationFake.VisualState
        $global:JunoOperationFake.VisualFault=$true
        {Apply-VisualEffects $true}|Should Throw
        $global:JunoOperationFake.General.Journal.Visual.Phase|Should Be 'Partial'
        Restore-VisualEffects|Out-Null
        Test-JunoEqual $original $global:JunoOperationFake.VisualState|Should Be $true
    }
    It 'efectos exige revision si se interrumpe entre escritura y confirmacion' {
        $global:JunoOperationFake.FaultSaves=@(2)
        {Apply-VisualEffects $false}|Should Throw
        $global:JunoOperationFake.General.Journal.Visual.Pending|Should Be $true
        {Apply-VisualEffects $false}|Should Throw
        Restore-VisualEffects|Out-Null
        Assert-MockCalled Confirm-JunoReview -Times 1 -Exactly -Scope It
    }
    It 'efectos rechaza cambios posteriores o lecturas incompletas sin modificar Windows' {
        Apply-VisualEffects $true|Out-Null;$count=$global:JunoOperationFake.Writes
        $global:JunoOperationFake.VisualState.Effects.MenuAnimation=$true
        {Restore-VisualEffects}|Should Throw;$global:JunoOperationFake.Writes|Should Be $count
        $global:JunoOperationFake.VisualState.Effects.PSObject.Properties.Remove('MenuAnimation')
        {Apply-VisualEffects $true}|Should Throw;$global:JunoOperationFake.Writes|Should Be $count
    }
    It 'restauracion visual parcial retiene el original hasta confirmarse' {
        $original=Copy-JunoObject $global:JunoOperationFake.VisualState
        Apply-VisualEffects $false|Out-Null;$global:JunoOperationFake.VisualFault=$true
        {Restore-VisualEffects}|Should Throw
        $global:JunoOperationFake.General.VisualEffects|Should Not BeNullOrEmpty
        Restore-VisualEffects|Out-Null
        Test-JunoEqual $original $global:JunoOperationFake.VisualState|Should Be $true
    }
    It 'directiva restaura existencia de listas vacias y valor global ausente' {
        $global:JunoOperationFake.PolicyState.Deny=New-OperationSnapshot $true @()
        Disable-BPPApps @('Test_pkg','Other_pkg')|Out-Null
        Restore-BPPApps @('Test_pkg')|Out-Null
        ($global:JunoOperationFake.Policy.Owned -contains 'Other_pkg')|Should Be $true
        Restore-BPPApps @('Other_pkg')|Out-Null
        $global:JunoOperationFake.PolicyState.Deny.Exists|Should Be $true
        $global:JunoOperationFake.PolicyState.Deny.Value.Count|Should Be 0
        $global:JunoOperationFake.PolicyState.Global.Exists|Should Be $false
        Restore-BPPApps @('Other_pkg')|Should Match 'no hay cambios seleccionados pendientes'
    }
    It 'directiva reintenta aplicacion parcial por valor' -TestCases @(@{At=1;Mode='Before'},@{At=1;Mode='After'},@{At=2;Mode='Before'},@{At=2;Mode='After'},@{At=2;Mode='Ignore'}) {
        param($At,$Mode)
        $global:JunoOperationFake.FaultWrites=@($At);$global:JunoOperationFake.FaultMode=$Mode
        {Disable-BPPApps @('Test_pkg')}|Should Throw
        Disable-BPPApps @('Test_pkg')|Out-Null
        ($global:JunoOperationFake.PolicyState.Deny.Value -contains 'Test_pkg')|Should Be $true
        Restore-BPPApps @('Test_pkg')|Out-Null
        $global:JunoOperationFake.PolicyState.Deny.Exists|Should Be $false
        $global:JunoOperationFake.PolicyState.Global.Exists|Should Be $false
    }
    It 'directiva reintenta restauracion parcial sin borrar propiedad prematuramente' {
        Disable-BPPApps @('Test_pkg')|Out-Null
        $global:JunoOperationFake.FaultWrites=@(4);$global:JunoOperationFake.FaultMode='After'
        {Restore-BPPApps @('Test_pkg')}|Should Throw
        ($global:JunoOperationFake.Policy.Owned -contains 'Test_pkg')|Should Be $true
        Restore-BPPApps @('Test_pkg')|Out-Null
        $global:JunoOperationFake.Policy.Transaction.Phase|Should Be 'Restored'
    }
    It 'directiva detecta cambios externos en listas que JUNO no escribe' -TestCases @(@{Field='Allow'},@{Field='UserControl'},@{Field='Deny'}) {
        param($Field)
        Disable-BPPApps @('Test_pkg')|Out-Null;$count=$global:JunoOperationFake.Writes
        $global:JunoOperationFake.PolicyState.$Field=New-OperationSnapshot $true @('External_pkg')
        {Restore-BPPApps @('Test_pkg')}|Should Throw
        $global:JunoOperationFake.Writes|Should Be $count
    }
    It 'directiva no se apropia de un bloqueo previo' {
        $global:JunoOperationFake.PolicyState.Deny=New-OperationSnapshot $true @('Test_pkg')
        Disable-BPPApps @('Test_pkg')|Should Match 'otra configuracion'
        $global:JunoOperationFake.Policy|Should BeNullOrEmpty;$global:JunoOperationFake.Writes|Should Be 0
    }
    It 'TRIM restaura e informa idempotencia conservando el diario' {
        Invoke-JunoTrim $false|Should Match 'verificado'
        $global:JunoOperationFake.Trim.Original|Should Be 1
        Invoke-JunoTrim $true|Should Match 'restaurado y verificado'
        Invoke-JunoTrim $true|Should Match 'ya confirmada'
        $global:JunoOperationFake.Writes|Should Be 2
        $global:JunoOperationFake.Trim.Transaction.Phase|Should Be 'Restored'
    }
    It 'TRIM reintenta errores anteriores y posteriores sin perder el original' -TestCases @(@{Mode='Before'},@{Mode='After'},@{Mode='Ignore'}) {
        param($Mode)
        $global:JunoOperationFake.FaultWrites=@(1);$global:JunoOperationFake.FaultMode=$Mode
        {Invoke-JunoTrim $false}|Should Throw
        Invoke-JunoTrim $false|Out-Null;Invoke-JunoTrim $true|Out-Null
        $global:JunoOperationFake.TrimState|Should Be 1
    }
    It 'TRIM detecta cambios externos incluso despues de una restauracion confirmada' {
        Invoke-JunoTrim $false|Out-Null;Invoke-JunoTrim $true|Out-Null
        $global:JunoOperationFake.TrimState=0
        {Invoke-JunoTrim $true}|Should Throw
        $global:JunoOperationFake.Writes|Should Be 2
    }
    It 'TRIM desconocido, permisos y cambios posteriores fallan sin nuevas escrituras' {
        $global:JunoOperationFake.TrimState=$null
        {Invoke-JunoTrim $false}|Should Throw;$global:JunoOperationFake.Writes|Should Be 0
        $global:JunoOperationFake.TrimState=1;Invoke-JunoTrim $false|Out-Null;$global:JunoOperationFake.TrimState=1
        {Invoke-JunoTrim $true}|Should Throw;$global:JunoOperationFake.Writes|Should Be 1
        Mock Test-JunoAdmin {$false};{Invoke-JunoTrim $true}|Should Throw
    }
    It 'fallo al guardar intencion impide modificar configuraciones' -TestCases @(@{Kind='Power'},@{Kind='General'},@{Kind='Policy'},@{Kind='Trim'}) {
        param($Kind)
        $global:JunoOperationFake.FaultSaves=@(1)
        {switch($Kind){'Power'{Enable-HighPerformance}'General'{Set-Transparency $false}'Policy'{Disable-BPPApps @('Test_pkg')}'Trim'{Invoke-JunoTrim $false}}}|Should Throw
        $global:JunoOperationFake.Writes|Should Be 0
    }
    It 'diagnostico de discos normal no intenta acceder al respaldo administrativo' {
        $script:DiskDialog=[pscustomobject]@{};$script:DiskIsAdmin=$false;$script:DiskProcess=$null
        $script:DiskOptimizeButton=[pscustomobject]@{Enabled=$true};$script:DiskRestoreTrimButton=[pscustomobject]@{Enabled=$true}
        $script:DiskEnableTrimButton=[pscustomobject]@{Enabled=$true};$script:DiskDetails=[pscustomobject]@{Text=''}
        Mock Get-DiskSelectedVolume {$null}
        Update-DiskDetails
        $script:DiskRestoreTrimButton.Enabled|Should Be $false
        $script:DiskDetails.Text|Should Match 'Selecciona una unidad'
    }
}
