#requires -Version 5.1
# Ningun cuerpo de modulo se ejecuta; inventario, Registro, dominio y MDM son ficticios.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$backgroundRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $backgroundRoot 'BackupStore.ps1')
. (Join-Path $backgroundRoot 'RecoveryOperations.ps1')
. (Join-Path $backgroundRoot 'BackgroundInventory.ps1')
foreach($spec in @(
    @{File='PermisosSegundoPlano.ps1';Names=@('Get-BPPEnvironment','Get-BPPPackages','Test-BPPAdmin','Get-BPPPolicy','Read-BPPBackup','Write-BPPBackup','Confirm-BPPWrite','Disable-BPPApps','Restore-BPPApps')},
    @{File='PermisosUsuario.ps1';Names=@('Get-BPUBackup','Save-BPUBackup','Test-BPULocalPolicy','Test-BPUValueSnapshot','Initialize-BPUTransaction','Sync-BPUTransaction','Set-BPURegistryValue','Write-BPUTransactionValue','Assert-BPUApplySupported','Disable-BPUApps','Restore-BPUApps')},
    @{File='SegundoPlano.ps1';Names=@('Get-BgSettingsUri')}
)){
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $backgroundRoot $spec.File),[ref]$t,[ref]$e)
    if($e.Count){throw($e.Message -join '; ')}
    foreach($name in $spec.Names){$n=$a.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($n.Extent.Text))}
}
function Get-JunoIdentity {[pscustomobject]@{Sid='TEST-SID';Machine='11111111-2222-3333-4444-555555555555'}}
function Test-JunoAdmin {throw 'TEST: identidad real prohibida'}
function Get-BPPHostInfo {throw 'TEST: Registro del sistema real prohibido'}
function Get-BPPDomainStatus {throw 'TEST: CIM real prohibido'}
function Get-BPPMdmStatus {throw 'TEST: consulta MDM real prohibida'}
function Read-BPPDefinition {throw 'TEST: ADMX real prohibido'}
function Get-BPPInstalledPackages {throw 'TEST: inventario Appx real prohibido'}
function Get-BPPManifest([string]$fullName) {throw 'TEST: manifiestos reales prohibidos'}
function Get-JunoPolicyState {throw 'TEST: Registro real prohibido'}
function Set-JunoPolicyValue([string]$field,$target) {throw 'TEST: Registro real prohibido'}
function Get-BPUAccount {return 'TEST-SID'}
function Get-BPUState([string]$family) {throw 'TEST: Registro real prohibido'}
function Open-BPUWriteKey([string]$family) {throw 'TEST: Registro real prohibido'}
function Get-JunoMachineLegacy([string]$kind) {throw 'TEST: respaldos reales prohibidos'}
function Import-JunoMachineLegacy([string]$kind) {throw 'TEST: respaldos reales prohibidos'}
function Confirm-JunoReview([string]$message) {throw 'TEST: dialogos reales prohibidos'}
function Start-Process {[CmdletBinding()]param([string]$FilePath,[string[]]$ArgumentList) throw 'TEST: abrir aplicaciones reales prohibido'}
function New-BackgroundXml([string]$text) {
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($text),$settings)
    try{$doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.Load($reader);return $doc}finally{$reader.Dispose()}
}
function New-BackgroundManifest([string]$attributes='EntryPoint="Contoso.Chat.App" Executable="Chat.exe"',[string]$extra='') {
    return (New-BackgroundXml ('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"><Identity Name="Contoso.Chat" Publisher="CN=Fixture" Version="1.0.0.0"/><Applications><Application Id="App" '+$attributes+'/></Applications>'+$extra+'</Package>'))
}
function New-BackgroundDefinition {
    return (New-BackgroundXml '<policyDefinitions xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions"><policies><policy name="LetAppsRunInBackground" class="Machine" key="Software\Policies\Microsoft\Windows\AppPrivacy"><elements><enum valueName="LetAppsRunInBackground"><item><value><decimal value="0"/></value></item><item><value><decimal value="1"/></value></item><item><value><decimal value="2"/></value></item></enum><multiText valueName="LetAppsRunInBackground_ForceDenyTheseApps"/><multiText valueName="LetAppsRunInBackground_ForceAllowTheseApps"/><multiText valueName="LetAppsRunInBackground_UserInControlOfTheseApps"/></elements></policy></policies></policyDefinitions>')
}
function New-BackgroundPackage {
    return [pscustomobject]@{Name='Contoso.Chat';PackageFamilyName='Contoso.Chat_testpub';PackageFullName='Contoso.Chat_1.0.0.0_x64__testpub';InstallLocation='C:\Fixtures\Apps\Chat';Status='Ok';IsFramework=$false;IsResourcePackage=$false;IsBundle=$false;NonRemovable=$false}
}
function New-BackgroundValue([bool]$exists,$value){return [pscustomobject]@{Exists=$exists;Value=$value}}
function Reset-BackgroundFake {
    $global:JunoBackgroundFake=[pscustomobject]@{
        Host=[pscustomobject]@{Edition='Professional';Build=22621;Installation='Client'};Admin=$true;Domain=$false;Mdm=$false;Definition=(New-BackgroundDefinition)
        Packages=@(New-BackgroundPackage);Manifest=(New-BackgroundManifest);User=[pscustomobject]@{Version=1;Sid='TEST-SID';Items=@()};Policy=$null
        PolicyState=[pscustomobject]@{Deny=(New-BackgroundValue $false $null);Global=(New-BackgroundValue $false $null);Allow=(New-BackgroundValue $false $null);UserControl=(New-BackgroundValue $false $null)}
        UserStates=@{};Writes=0;Saves=0;FaultWrites=@();FaultSaves=@();FaultMode='Before';History=@();Opened=@()
    }
}
function Invoke-BackgroundFakeWrite([scriptblock]$action) {
    $global:JunoBackgroundFake.Writes++;$fail=$global:JunoBackgroundFake.FaultWrites -contains $global:JunoBackgroundFake.Writes
    if($fail -and $global:JunoBackgroundFake.FaultMode -eq 'Before'){throw 'SIMULATED before write'}
    if(-not($fail -and $global:JunoBackgroundFake.FaultMode -eq 'Ignore')){& $action}
    if($fail -and $global:JunoBackgroundFake.FaultMode -eq 'After'){throw 'SIMULATED after write'}
}
function New-BackgroundUserRecord([bool]$absent=$false) {
    $one=New-BackgroundValue (-not $absent) $(if($absent){$null}else{0})
    $entry=[pscustomobject]@{Family='Contoso.Chat_testpub';Disabled=(Copy-JunoObject $one);DisabledByUser=(Copy-JunoObject $one)}
    $global:JunoBackgroundFake.User.Items=@($entry)
    $global:JunoBackgroundFake.UserStates[$entry.Family]=[pscustomobject]@{Available=$true;Disabled=(New-BackgroundValue $true 1);DisabledByUser=(New-BackgroundValue $true 1)}
    return $entry
}
function New-BackgroundUserKey([string]$family) {
    $key=[pscustomobject]@{Family=$family}
    $key|Add-Member ScriptMethod SetValue {param($name,$value,$kind)
        $target=New-BackgroundValue $true ([int]$value)
        $f=$this.Family
        Invoke-BackgroundFakeWrite {$global:JunoBackgroundFake.UserStates[$f].$name=Copy-JunoObject $target}
    }
    $key|Add-Member ScriptMethod DeleteValue {param($name,$throwIfMissing)
        $f=$this.Family
        Invoke-BackgroundFakeWrite {$global:JunoBackgroundFake.UserStates[$f].$name=New-BackgroundValue $false $null}
    }
    $key|Add-Member ScriptMethod Dispose {}
    return $key
}

Describe 'Segundo plano: inventario, aplicabilidad y recuperacion aislados' {
    BeforeEach {
        Reset-BackgroundFake
        Enter-JunoLease ('Local\Juno.Tests.Background.'+[Guid]::NewGuid().ToString('N'))
        Mock Test-JunoAdmin {$global:JunoBackgroundFake.Admin}
        Mock Get-BPPHostInfo {Copy-JunoObject $global:JunoBackgroundFake.Host}
        Mock Get-BPPDomainStatus {$global:JunoBackgroundFake.Domain}
        Mock Get-BPPMdmStatus {$global:JunoBackgroundFake.Mdm}
        Mock Read-BPPDefinition {$global:JunoBackgroundFake.Definition}
        Mock Get-BPPInstalledPackages {$global:JunoBackgroundFake.Packages}
        Mock Get-BPPManifest {$global:JunoBackgroundFake.Manifest}
        Mock Get-JunoPolicyState {Copy-JunoObject $global:JunoBackgroundFake.PolicyState}
        Mock Get-BPUState {param($family) if($global:JunoBackgroundFake.UserStates.ContainsKey($family)){return (Copy-JunoObject $global:JunoBackgroundFake.UserStates[$family])};return [pscustomobject]@{Available=$false}}
        Mock Read-JunoStore {
            param($kind,$scope,$default)
            $data=switch($kind){'BPU'{$global:JunoBackgroundFake.User}'Policy'{$global:JunoBackgroundFake.Policy}default{throw 'TEST: modulo no permitido'}}
            if($null -eq $data){return $default};Assert-JunoBackupData $kind $data $scope;return (Copy-JunoObject $data)
        }
        Mock Write-JunoStore {
            param($kind,$data,$scope)
            Assert-JunoBackupData $kind $data $scope;$global:JunoBackgroundFake.Saves++
            if($global:JunoBackgroundFake.FaultSaves -contains $global:JunoBackgroundFake.Saves){throw 'SIMULATED save failure'}
            $field=if($kind -eq 'BPU'){'User'}elseif($kind -eq 'Policy'){'Policy'}else{throw 'TEST: modulo no permitido'}
            $global:JunoBackgroundFake.$field=Copy-JunoObject $data
            $global:JunoBackgroundFake.History+=@([pscustomobject]@{Kind=$kind;Data=(Copy-JunoObject $data)})
        }
        Mock Set-JunoPolicyValue {param($field,$target) if($field -notin @('Deny','Global')){throw 'TEST: destino no permitido'};Assert-JunoValueSnapshot $target $field;Invoke-BackgroundFakeWrite {$global:JunoBackgroundFake.PolicyState.$field=Copy-JunoObject $target}}
        Mock Open-BPUWriteKey {param($family) New-BackgroundUserKey $family}
        Mock Get-JunoMachineLegacy {$null}
        Mock Import-JunoMachineLegacy {Assert-JunoLease}
        Mock Confirm-JunoReview {}
        Mock Start-Process {param($FilePath) $global:JunoBackgroundFake.Opened+=@($FilePath)}
    }
    AfterEach {Exit-JunoLease}
    It 'distingue Windows 10/11 Home y Pro sin asumir directivas en Home' -TestCases @(
        @{Edition='Core';Build=19045;Supported=$false},@{Edition='Professional';Build=19045;Supported=$true},
        @{Edition='Core';Build=22621;Supported=$false},@{Edition='Professional';Build=22621;Supported=$true}
    ) {
        param($Edition,$Build,$Supported)
        $global:JunoBackgroundFake.Host.Edition=$Edition;$global:JunoBackgroundFake.Host.Build=$Build
        $env=Get-BPPEnvironment;$env.Supported|Should Be $Supported;$env.CanWrite|Should Be $Supported
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'rechaza versiones anteriores a 1703, ediciones desconocidas y Server' -TestCases @(
        @{Edition='Professional';Build=14393;Installation='Client'},@{Edition='Unknown';Build=22621;Installation='Client'},@{Edition='Professional';Build=22621;Installation='Server'}
    ) {param($Edition,$Build,$Installation);$global:JunoBackgroundFake.Host=[pscustomobject]@{Edition=$Edition;Build=$Build;Installation=$Installation};{Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw;$global:JunoBackgroundFake.Writes|Should Be 0}
    It 'no escribe sin admin, con dominio o MDM' -TestCases @(@{Field='Admin';Value=$false},@{Field='Domain';Value=$true},@{Field='Mdm';Value=$true}) {
        param($Field,$Value);$global:JunoBackgroundFake.$Field=$Value
        (Get-BPPEnvironment).CanWrite|Should Be $false
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'dominio, MDM o ADMX inaccesibles fallan cerrados' -TestCases @(@{Boundary='Domain'},@{Boundary='Mdm'},@{Boundary='Definition'}) {
        param($Boundary)
        switch($Boundary){'Domain'{Mock Get-BPPDomainStatus {throw 'unavailable'}}'Mdm'{Mock Get-BPPMdmStatus {throw 'unavailable'}}'Definition'{Mock Read-BPPDefinition {throw 'unavailable'}}}
        (Get-BPPEnvironment).CanWrite|Should Be $false
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
    }
    It 'comprueba el contrato ADMX exacto sin confundirlo con reconocimiento efectivo' {
        Test-BPPDefinition (New-BackgroundDefinition)|Should Be $true
        $global:JunoBackgroundFake.Definition.SelectSingleNode('//*[@name="LetAppsRunInBackground"]').SetAttribute('key','Software\Other')
        (Get-BPPEnvironment).CanWrite|Should Be $false
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
    }
    It 'identifica UWP, escritorio MSIX y casos no verificables por manifiesto' -TestCases @(
        @{Attributes='EntryPoint="Contoso.Chat.App" Executable="Chat.exe"';Expected='Compatible'},
        @{Attributes='EntryPoint="Contoso.Chat.App" Executable="Chat.exe" uap10:RuntimeBehavior="windowsApp" uap10:TrustLevel="appContainer"';Expected='Compatible'},
        @{Attributes='EntryPoint="windows.fullTrustApplication" Executable="Chat.exe"';Expected='No compatible'},
        @{Attributes='EntryPoint="windows.partialTrustApplication" Executable="Chat.exe"';Expected='No compatible'},
        @{Attributes='Executable="Chat.exe" uap10:RuntimeBehavior="win32App" uap10:TrustLevel="mediumIL"';Expected='No compatible'},
        @{Attributes='Executable="Chat.exe" uap10:RuntimeBehavior="packagedClassicApp" uap10:TrustLevel="appContainer"';Expected='No compatible'},
        @{Attributes='Executable="Chat.exe"';Expected='Compatibilidad no verificada'},
        @{Attributes='EntryPoint="Contoso.Chat.App" Executable="Chat.exe" uap10:TrustLevel="mediumIL"';Expected='Compatibilidad no verificada'}
    ) {param($Attributes,$Expected);$global:JunoBackgroundFake.Manifest=New-BackgroundManifest $Attributes;(Get-BPPPackages)[0].Compatibility|Should Be $Expected}
    It 'un paquete mixto/fulltrust no se ofrece como UWP restringible' {
        $global:JunoBackgroundFake.Manifest=New-BackgroundManifest 'EntryPoint="Contoso.Chat.App" Executable="Chat.exe"' '<Capabilities><rescap:Capability Name="runFullTrust"/></Capabilities>'
        (Get-BPPPackages)[0].Compatibility|Should Be 'No compatible'
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Saves|Should Be 0
    }
    It 'manifiesto faltante, identidad distinta, estado incompleto o instalacion ausente no autorizan escritura' -TestCases @(
        @{Case='Missing'},@{Case='Identity'},@{Case='Status'},@{Case='Location'},@{Case='Metadata'}
    ) {
        param($Case)
        switch($Case){'Missing'{Mock Get-BPPManifest {throw 'unavailable'}}'Identity'{$global:JunoBackgroundFake.Manifest.DocumentElement.FirstChild.SetAttribute('Name','Other')}'Status'{$global:JunoBackgroundFake.Packages[0].Status=$null}'Location'{$global:JunoBackgroundFake.Packages[0].InstallLocation=''}'Metadata'{$global:JunoBackgroundFake.Packages[0].PSObject.Properties.Remove('NonRemovable')}}
        (Get-BPPPackages)[0].Compatibility|Should Be 'Compatibilidad no verificada'
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'deduplica PFN, omite PFN invalido y no oculta componentes con respaldo pendiente' {
        $component=New-BackgroundPackage;$component.Name='Microsoft.Windows.Internal';$component.NonRemovable=$true
        $global:JunoBackgroundFake.Packages=@($component,$component,[pscustomobject]@{PackageFamilyName='bad\path'})
        @(Get-BPPPackages).Count|Should Be 1
        (Get-BPPPermissionView).Rows.Count|Should Be 0
        [void](New-BackgroundUserRecord)
        $view=Get-BPPPermissionView;$view.Rows.Count|Should Be 1;$view.Rows[0].Type|Should Be 'Componente protegido'
        $view.Rows[0].CanRequest|Should Be $false;$view.Rows[0].CanRestore|Should Be $true
    }
    It 'lectura del inventario no aplica cambios ni guarda respaldos' {
        $v=Get-BPPPermissionView;$v.Rows.Count|Should Be 1;$v.Rows[0].CanRequest|Should Be $true
        $global:JunoBackgroundFake.Writes|Should Be 0;$global:JunoBackgroundFake.Saves|Should Be 0
        $v.Rows[0].PolicyRecognized|Should BeNullOrEmpty;$v.Rows[0].EffectiveVerified|Should Be $false
    }
    It 'las peticiones HKCU nuevas se rechazan incluso con claves disponibles' {
        [void](New-BackgroundUserRecord)
        {Disable-BPUApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0;$global:JunoBackgroundFake.Saves|Should Be 0
    }
    It 'solicitud de politica confirma escritura y mantiene reconocimiento/eficacia desconocidos' {
        $message=Disable-BPPApps @('Contoso.Chat_testpub')
        $message|Should Match 'escritura confirmada en Registro';$message|Should Match 'no verificados';$message|Should Not Match 'bloquead[ao].*correctamente'
        $row=(Get-BPPPermissionView).Rows[0];$row.WriteConfirmed|Should Be $true;$row.EffectiveVerified|Should Be $false;$row.PolicyRecognized|Should BeNullOrEmpty
        $row.Classification|Should Be 'Administrada mediante politica'
        Restore-BPPApps @('Contoso.Chat_testpub')|Should Match 'Registro'
        $global:JunoBackgroundFake.PolicyState.Deny.Exists|Should Be $false;$global:JunoBackgroundFake.PolicyState.Global.Exists|Should Be $false
    }
    It 'politicas externas, incluso listas vacias o valor cero, no reciben solicitudes nuevas' -TestCases @(
        @{Field='Global';Value=0},@{Field='Deny';Value=@('Other_pkg')},@{Field='Deny';Value=@()},@{Field='Allow';Value=@('Other_pkg')},@{Field='UserControl';Value=@('Other_pkg')}
    ) {
        param($Field,$Value);$global:JunoBackgroundFake.PolicyState.$Field=New-BackgroundValue $true $Value
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        (Get-BPPPermissionView).Rows[0].CanRequest|Should Be $false
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'errores antes/despues de escribir y API sin efecto conservan intencion para reintentar' -TestCases @(
        @{At=1;Mode='Before'},@{At=1;Mode='After'},@{At=2;Mode='Before'},@{At=2;Mode='After'},@{At=2;Mode='Ignore'}
    ) {
        param($At,$Mode);$global:JunoBackgroundFake.FaultWrites=@($At);$global:JunoBackgroundFake.FaultMode=$Mode
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Policy.Transaction.Pending|Should Not BeNullOrEmpty
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null
        Restore-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $global:JunoBackgroundFake.Policy.Transaction.Phase|Should Be 'Restored'
    }
    It 'fallo al guardar intencion impide modificar politicas' {
        $global:JunoBackgroundFake.FaultSaves=@(1)
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'restauracion parcial de politica se reintenta sin borrar propiedad prematuramente' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;$global:JunoBackgroundFake.FaultWrites=@(4);$global:JunoBackgroundFake.FaultMode='After'
        {Restore-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        ($global:JunoBackgroundFake.Policy.Owned -contains 'Contoso.Chat_testpub')|Should Be $true
        Restore-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $global:JunoBackgroundFake.Policy.Owned.Count|Should Be 0
    }
    It 'no sobrescribe cambios externos posteriores en directivas' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;$count=$global:JunoBackgroundFake.Writes
        $global:JunoBackgroundFake.PolicyState.UserControl=New-BackgroundValue $true @('Other_pkg')
        {Restore-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        (Get-BPPPermissionView).Rows[0].CanRestore|Should Be $false
        $global:JunoBackgroundFake.Writes|Should Be $count
    }
    It 'restaura politica de app desinstalada sin consultar su manifiesto' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;$global:JunoBackgroundFake.Packages=@()
        $view=Get-BPPPermissionView;$view.Rows.Count|Should Be 1;$view.Rows[0].Installed|Should Be $false;$view.Rows[0].CanRestore|Should Be $true
        Restore-BPPApps @('Contoso.Chat_testpub')|Out-Null
    }
    It 'HKCU historico de app desinstalada restaura ausencia original en Home sin solicitar restricciones nuevas' {
        $global:JunoBackgroundFake.Host.Edition='Core';$global:JunoBackgroundFake.Admin=$false;$global:JunoBackgroundFake.Packages=@()
        [void](New-BackgroundUserRecord $true)
        $view=Get-BPPPermissionView;$view.Rows.Count|Should Be 1;$view.Rows[0].CanRestore|Should Be $true;$view.Rows[0].CanRequest|Should Be $false
        Restore-BPUApps @('Contoso.Chat_testpub')|Should Match 'Registro'
        $global:JunoBackgroundFake.UserStates['Contoso.Chat_testpub'].Disabled.Exists|Should Be $false
        $global:JunoBackgroundFake.User.Items.Count|Should Be 0
    }
    It 'HKCU con clave eliminada conserva el respaldo y nunca la recrea' {
        [void](New-BackgroundUserRecord);$global:JunoBackgroundFake.Packages=@();$global:JunoBackgroundFake.UserStates=@{}
        $view=Get-BPPPermissionView;$view.Rows[0].CanRestore|Should Be $false;$view.Rows[0].Reason|Should Match 'Clave del usuario ausente'
        {Restore-BPUApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.User.Items.Count|Should Be 1;$global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'restauracion HKCU parcial mantiene diario y permite reintento' {
        [void](New-BackgroundUserRecord);$global:JunoBackgroundFake.FaultWrites=@(2);$global:JunoBackgroundFake.FaultMode='After'
        {Restore-BPUApps @('Contoso.Chat_testpub')}|Should Throw
        $global:JunoBackgroundFake.User.Items[0].Transaction.Phase|Should Be 'Restoring'
        Restore-BPUApps @('Contoso.Chat_testpub')|Out-Null
        $global:JunoBackgroundFake.User.Items.Count|Should Be 0
    }
    It 'HKCU modificado externamente o gobernado por politica no se sobrescribe' -TestCases @(@{Case='Changed'},@{Case='Policy'},@{Case='Domain'}) {
        param($Case);[void](New-BackgroundUserRecord)
        switch($Case){'Changed'{$global:JunoBackgroundFake.UserStates['Contoso.Chat_testpub'].Disabled.Value=2}'Policy'{$global:JunoBackgroundFake.PolicyState.Global=New-BackgroundValue $true 0}'Domain'{$global:JunoBackgroundFake.Domain=$true}}
        {Restore-BPUApps @('Contoso.Chat_testpub')}|Should Throw
        (Get-BPPPermissionView).Rows[0].CanRestore|Should Be $false
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'inventario inaccesible aun permite mostrar los respaldos y restaurar claves conocidas' {
        [void](New-BackgroundUserRecord);Mock Get-BPPInstalledPackages {throw 'unavailable'}
        $view=Get-BPPPermissionView;$view.Rows.Count|Should Be 1;$view.Errors.Count|Should BeGreaterThan 0
        $view.Rows[0].CanRestore|Should Be $true
    }
    It 'respaldo de version futura bloquea acciones sin ocultar el error' {
        $global:JunoBackgroundFake.User.Version=99
        $view=Get-BPPPermissionView;$view.BackupsValid|Should Be $false
        $view.Rows[0].CanRequest|Should Be $false;$view.Errors[0]|Should Match 'Respaldo HKCU invalido'
    }
    It 'muestra ambitos separados cuando la misma app tiene restauraciones HKCU y HKLM' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;[void](New-BackgroundUserRecord)
        $view=Get-BPPPermissionView;$view.Rows.Count|Should Be 2
        @($view.Rows|Where-Object{$_.Scope -eq 'User'})[0].CanRestore|Should Be $false
        @($view.Rows|Where-Object{$_.Scope -eq 'Policy'})[0].CanRestore|Should Be $true
    }
    It 'historia de politica requiere restauracion revisada antes de nuevas solicitudes' {
        $global:JunoBackgroundFake.Policy=[pscustomobject]@{Owned=@('Contoso.Chat_testpub');MadeGlobal=$true}
        $global:JunoBackgroundFake.PolicyState.Deny=New-BackgroundValue $true @('Contoso.Chat_testpub');$global:JunoBackgroundFake.PolicyState.Global=New-BackgroundValue $true 0
        {Disable-BPPApps @('Contoso.Chat_testpub')}|Should Throw
        Restore-BPPApps @('Contoso.Chat_testpub')|Out-Null
        Assert-MockCalled Confirm-JunoReview -Times 1 -Exactly -Scope It
    }
    It 'seleccion incompatible o cancelada no invoca operaciones' {
        $row=(Get-BPPPermissionView).Rows[0]
        Invoke-BPPSelection Request @($row) $false|Should Match 'cancelada'
        $row.CanRequest=$false
        {Invoke-BPPSelection Request @($row) $true}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0;$global:JunoBackgroundFake.Saves|Should Be 0
    }
    It 'abre solo URI oficiales y nunca comandos procedentes del paquete' {
        Open-BPPSettings 'Contoso.Chat_testpub';$global:JunoBackgroundFake.Opened[0]|Should Be 'ms-settings:appsfeatures-app?Contoso.Chat_testpub'
        {Open-BPPSettings 'bad;cmd_pkg\escape'}|Should Throw
        $global:JunoBackgroundFake.Opened.Count|Should Be 1
        $global:JunoBackgroundFake.Host.Build=19045;Get-BgSettingsUri|Should Be 'ms-settings:privacy-backgroundapps'
        $global:JunoBackgroundFake.Host.Build=22621;Get-BgSettingsUri|Should Be 'ms-settings:appsfeatures'
    }
    It 'exige concesion del mutex tambien para despachar la seleccion' {
        $row=(Get-BPPPermissionView).Rows[0];Exit-JunoLease
        {Invoke-BPPSelection Request @($row) $true}|Should Throw
        $global:JunoBackgroundFake.Writes|Should Be 0
    }
    It 'una restauracion en curso deshabilita solicitudes tambien para apps sin respaldo propio' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $other=New-BackgroundPackage;$other.PackageFamilyName='Contoso.Chat_otherpub'
        $global:JunoBackgroundFake.Packages+=@($other)
        $global:JunoBackgroundFake.Policy.Transaction.Phase='Restoring'
        $rows=(Get-BPPPermissionView).Rows
        @($rows|Where-Object{$_.CanRequest}).Count|Should Be 0
        {Disable-BPPApps @('Contoso.Chat_otherpub')}|Should Throw
    }
    It 'un conflicto de diario deshabilita solicitudes para cualquier otra app' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $other=New-BackgroundPackage;$other.PackageFamilyName='Contoso.Chat_otherpub';$global:JunoBackgroundFake.Packages+=@($other)
        $global:JunoBackgroundFake.PolicyState.Global=New-BackgroundValue $false $null
        @((Get-BPPPermissionView).Rows|Where-Object{$_.CanRequest}).Count|Should Be 0
        {Disable-BPPApps @('Contoso.Chat_otherpub')}|Should Throw
    }
    It 'una directiva propia sigue siendo restaurable despues de pasar a Home' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;$global:JunoBackgroundFake.Host.Edition='Core'
        $row=(Get-BPPPermissionView).Rows[0];$row.CanRequest|Should Be $false;$row.CanRestore|Should Be $true
        Restore-BPPApps @('Contoso.Chat_testpub')|Out-Null
        $global:JunoBackgroundFake.Policy.Transaction.Phase|Should Be 'Restored'
    }
    It 'despacha la restauracion de equipo antes de la del usuario y conserva originales separados' {
        Disable-BPPApps @('Contoso.Chat_testpub')|Out-Null;[void](New-BackgroundUserRecord $true)
        $policy=@((Get-BPPPermissionView).Rows|Where-Object{$_.Scope -eq 'Policy'})[0]
        Invoke-BPPSelection Restore @($policy) $true|Should Match 'Registro'
        $user=@((Get-BPPPermissionView).Rows|Where-Object{$_.Scope -eq 'User'})[0];$user.CanRestore|Should Be $true
        Invoke-BPPSelection Restore @($user) $true|Should Match 'Registro'
        $global:JunoBackgroundFake.User.Items.Count|Should Be 0
        $global:JunoBackgroundFake.UserStates['Contoso.Chat_testpub'].Disabled.Exists|Should Be $false
    }
}
