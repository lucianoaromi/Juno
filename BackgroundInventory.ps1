# JUNO: inventario y decisiones de compatibilidad. Importar no consulta ni cambia Windows.
function Get-BPPProperty($object,[string]$name,$default=$null) {
    if($null -ne $object -and $object.PSObject.Properties.Name -contains $name){return $object.$name}
    return $default
}
function Get-BPPHostInfo {
    $view=if([Environment]::Is64BitOperatingSystem){[Microsoft.Win32.RegistryView]::Registry64}else{[Microsoft.Win32.RegistryView]::Default}
    $root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
    try {
        $key=$root.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion',$false)
        try {return [pscustomobject]@{Edition=[string]$key.GetValue('EditionID');Build=[int]$key.GetValue('CurrentBuildNumber');Installation=[string]$key.GetValue('InstallationType')}}
        finally{if($key){$key.Dispose()}}
    } finally{$root.Dispose()}
}
function Get-BPPDomainStatus { return [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain }
function Get-BPPMdmStatus {
    if(-not('JunoBackgroundManagement' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class JunoBackgroundManagement {
    [DllImport("MDMRegistration.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern int IsDeviceRegisteredWithManagement(
        [MarshalAs(UnmanagedType.Bool)] out bool registered, uint length, IntPtr upn);
}
'@
    }
    $registered=$false
    $hr=[JunoBackgroundManagement]::IsDeviceRegisteredWithManagement([ref]$registered,0,[IntPtr]::Zero)
    if($hr -ne 0){throw 'No se pudo consultar la inscripcion MDM.'}
    return [bool]$registered
}
function Read-BPPDefinition {
    $path=Join-Path $env:WINDIR 'PolicyDefinitions\AppPrivacy.admx'
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=2097152
    $reader=[Xml.XmlReader]::Create($path,$settings)
    try{$doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null;$doc.Load($reader);return $doc}finally{$reader.Dispose()}
}
function Test-BPPDefinition($document) {
    if($document -isnot [Xml.XmlDocument] -or $null -ne $document.DocumentType){return $false}
    $n=[Xml.XmlNamespaceManager]::new($document.NameTable);$n.AddNamespace('p','http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions')
    $policy=$document.SelectSingleNode('/p:policyDefinitions/p:policies/p:policy[@name="LetAppsRunInBackground"]',$n)
    if($null -eq $policy -or $policy.GetAttribute('class') -cne 'Machine' -or $policy.GetAttribute('key') -ine 'Software\Policies\Microsoft\Windows\AppPrivacy'){return $false}
    foreach($name in @('LetAppsRunInBackground_ForceDenyTheseApps','LetAppsRunInBackground_ForceAllowTheseApps','LetAppsRunInBackground_UserInControlOfTheseApps')){
        if($null -eq $policy.SelectSingleNode(('p:elements/p:multiText[@valueName="'+$name+'"]'),$n)){return $false}
    }
    $values=@($policy.SelectNodes('p:elements/p:enum[@valueName="LetAppsRunInBackground"]/p:item/p:value/p:decimal',$n)|ForEach-Object{$_.GetAttribute('value')})
    return ($values.Count -eq 3 -and ($values -join ',') -ceq '0,1,2')
}
function Get-BPPEnvironmentInfo {
    $hostInfo=$null;$domain=$false;$mdm=$false;$known=$true;$definition=$false;$admin=$false
    try{$hostInfo=Get-BPPHostInfo}catch{$known=$false}
    try{$domain=Get-BPPDomainStatus}catch{$known=$false}
    try{$mdm=Get-BPPMdmStatus}catch{$known=$false}
    try{$admin=Test-BPPAdmin}catch{$known=$false}
    $edition=if($hostInfo){$hostInfo.Edition}else{'Desconocida'}
    $build=if($hostInfo){$hostInfo.Build}else{0}
    # Tabla Microsoft: Pro y familias profesionales, Enterprise, Education e IoT Enterprise; 1703+.
    $editions=@('Professional','ProfessionalN','ProfessionalEducation','ProfessionalEducationN','ProfessionalWorkstation','ProfessionalWorkstationN','Enterprise','EnterpriseN','EnterpriseS','EnterpriseSN','Education','EducationN','IoTEnterprise','IoTEnterpriseS')
    $supported=$null -ne $hostInfo -and $hostInfo.Installation -ceq 'Client' -and $build -ge 15063 -and $editions -ccontains $edition
    if($supported){try{$definition=Test-BPPDefinition (Read-BPPDefinition)}catch{$definition=$false}}
    $reason=if(-not $known){'No se pudo determinar el sistema o la administracion del equipo.'}elseif($domain -or $mdm){'Equipo de dominio o inscrito en MDM: gestion externa; solo consulta.'}elseif(-not $supported){'Edicion o version sin soporte documentado para esta directiva; usa Ajustes.'}elseif(-not $definition){'Definicion ADMX ausente o incompatible; no se escribiran directivas.'}elseif(-not $admin){'La directiva de equipo requiere administrador.'}else{'Metodo documentado disponible; eficacia por aplicacion no verificada.'}
    $restore=$null -ne $hostInfo -and $hostInfo.Installation -ceq 'Client' -and $build -ge 10240 -and $known -and -not $domain -and -not $mdm -and $admin
    return [pscustomobject]@{Edition=$edition;Build=$build;Supported=[bool]$supported;Admin=[bool]$admin;Domain=[bool]$domain;Mdm=[bool]$mdm;ManagementKnown=$known;Managed=($domain -or $mdm);DefinitionKnown=$definition;CanWrite=($supported -and $definition -and $known -and -not $domain -and -not $mdm -and $admin);CanRestorePolicy=[bool]$restore;Reason=$reason}
}
function Get-BPPInstalledPackages { return @(Get-AppxPackage -ErrorAction Stop) }
function Get-BPPManifest([string]$fullName) { return (Get-AppxPackageManifest -Package $fullName -ErrorAction Stop) }
function Get-BPPManifestType($manifest,[string]$packageName) {
    $unknown=[pscustomobject]@{Type='Desconocido';Compatibility='Compatibilidad no verificada';Reason='Manifiesto ausente, contradictorio o no reconocido.'}
    if($manifest -isnot [Xml.XmlDocument] -or $null -ne $manifest.DocumentType -or $manifest.OuterXml.Length -gt 2097152){return $unknown}
    $ns=[Xml.XmlNamespaceManager]::new($manifest.NameTable)
    $ns.AddNamespace('f','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $identity=$manifest.SelectSingleNode('/f:Package/f:Identity',$ns)
    if($null -eq $identity -or $identity.GetAttribute('Name') -cne $packageName){return $unknown}
    $apps=@($manifest.SelectNodes('/f:Package/f:Applications/f:Application',$ns))
    if($apps.Count -eq 0){return $unknown}
    $desktop=$false;$uwp=$false
    foreach($node in @($manifest.SelectNodes('//*'))){
        if(($node.LocalName -eq 'Capability' -and $node.GetAttribute('Name') -ieq 'runFullTrust') -or
            ($node.LocalName -eq 'Extension' -and $node.GetAttribute('Category') -iin @('windows.fullTrustProcess','windows.service'))){$desktop=$true}
        if($node.LocalName -eq 'Extension'){
            $r=$node.GetAttribute('RuntimeBehavior','http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
            $t=$node.GetAttribute('TrustLevel','http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
            $e=$node.GetAttribute('EntryPoint')
            if($r -in @('packagedClassicApp','win32App') -or $t -eq 'mediumIL' -or $e -iin @('windows.fullTrustApplication','windows.partialTrustApplication')){$desktop=$true}
            elseif(($r -and $r -cne 'windowsApp') -or ($t -and $t -cne 'appContainer')){return $unknown}
        }
    }
    foreach($app in $apps){
        foreach($attribute in $app.Attributes){if($attribute.LocalName -in @('RuntimeBehavior','TrustLevel') -and $attribute.NamespaceURI -cne 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10'){return $unknown}}
        $entry=$app.GetAttribute('EntryPoint');$executable=$app.GetAttribute('Executable')
        $runtime=$app.GetAttribute('RuntimeBehavior','http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
        $trust=$app.GetAttribute('TrustLevel','http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
        if($runtime -cin @('packagedClassicApp','win32App') -or $entry -iin @('windows.fullTrustApplication','windows.partialTrustApplication')){$desktop=$true;continue}
        if(-not $entry -or -not $executable -or ($runtime -and $runtime -cne 'windowsApp') -or ($trust -and $trust -cne 'appContainer')){return $unknown}
        $uwp=$true
    }
    if($desktop){return [pscustomobject]@{Type=$(if($uwp){'Mixto UWP/escritorio'}else{'Escritorio empaquetado'});Compatibility='No compatible';Reason='La directiva UWP no acredita una restriccion de los componentes de escritorio del paquete.'}}
    return [pscustomobject]@{Type='UWP';Compatibility='Compatible';Reason='Activacion UWP/AppContainer identificada en el manifiesto; esto no demuestra restriccion efectiva.'}
}
function Test-BPPProtectedPackage($package) {
    foreach($flag in @('IsFramework','IsResourcePackage','IsBundle','NonRemovable')){if((Get-BPPProperty $package $flag $false) -eq $true){return $true}}
    $name=[string](Get-BPPProperty $package 'Name' '')
    if($name -match '^(Microsoft\.Windows|Microsoft\.AAD|Microsoft\.Account|Microsoft\.UI\.|Microsoft\.VCLibs|Microsoft\.NET\.|Microsoft\.Services\.Store|Microsoft\.DesktopAppInstaller|Microsoft\.StorePurchaseApp|Microsoft\.SecHealth|Windows\.|Microsoft\.XboxIdentityProvider)'){return $true}
    $location=[string](Get-BPPProperty $package 'InstallLocation' '')
    if($location -and $location.StartsWith(($env:WINDIR.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){return $true}
    return $false
}
function Get-BPPPackageInventory {
    $result=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($p in @(Get-BPPInstalledPackages)){
        $name=[string](Get-BPPProperty $p 'Name' '');$family=Get-BPPProperty $p 'PackageFamilyName';$full=[string](Get-BPPProperty $p 'PackageFullName' '')
        try{Assert-JunoFamily $family}catch{continue}
        if($seen.ContainsKey($family)){continue};$seen[$family]=$true
        $protected=Test-BPPProtectedPackage $p
        $type=[pscustomobject]@{Type='Desconocido';Compatibility='Compatibilidad no verificada';Reason='No se pudo leer el manifiesto.'}
        if(-not $protected -and $full -and $name){try{$type=Get-BPPManifestType (Get-BPPManifest $full) $name}catch{}}
        if($protected){$type=[pscustomobject]@{Type='Componente protegido';Compatibility='No compatible';Reason='Componente interno, framework, recurso, bundle o no extraible; no se ofrecen restricciones nuevas.'}}
        $status=Get-BPPProperty $p 'Status' 'Unknown'
        $healthy=$null -ne $status -and $status.ToString() -ceq 'Ok'
        foreach($flag in @('IsFramework','IsResourcePackage','IsBundle','NonRemovable')){if((Get-BPPProperty $p $flag) -isnot [bool]){$healthy=$false}}
        $location=[string](Get-BPPProperty $p 'InstallLocation' '')
        if(-not $healthy -or [string]::IsNullOrWhiteSpace($location)){$type=[pscustomobject]@{Type=$type.Type;Compatibility='Compatibilidad no verificada';Reason='Paquete sin ubicacion o estado de instalacion comprobado.'}}
        $result.Add([pscustomobject]@{Name=$name;Family=$family;PackageFullName=$full;Type=$type.Type;Compatibility=$type.Compatibility;Reason=$type.Reason;Protected=$protected;Installed=$true})
    }
    return @($result.ToArray()|Sort-Object Name,Family)
}
function Assert-BPPPolicyOwnership($backup,$state,[switch]$Request) {
    if(-not $Request){return} # Restaurar conserva el original y concilia el diario completo.
    $hasTransaction=$backup.PSObject.Properties.Name -contains 'Transaction'
    if(-not $hasTransaction -and ($backup.Owned.Count -gt 0 -or $backup.MadeGlobal)){throw 'Directiva historica pendiente: restaurala antes de solicitar nuevas restricciones.'}
    $external=$state.Allow.Exists -or $state.UserControl.Exists
    if($hasTransaction -and $backup.Transaction.Phase -ne 'Restored'){
        $external=$external -or $backup.Transaction.Original.Deny.Exists -or $backup.Transaction.Original.Global.Exists
        $external=$external -or @($state.Deny.Value|Where-Object{$null -ne $_ -and $backup.Owned -notcontains $_}).Count -gt 0
    }else{$external=$external -or $state.Deny.Exists -or $state.Global.Exists}
    if($external){throw 'Configuracion de directiva preexistente o externa: JUNO no agregara restricciones. Usa su administrador o Ajustes.'}
}
function Get-BPPRecoveryCheck($entry,$state,[string]$scope,$backup=$null) {
    try{
        if($scope -eq 'User'){
            if(-not $state.Available){return [pscustomobject]@{Allowed=$false;Reason='Clave del usuario ausente: respaldo conservado, sin recrearla.'}}
            $copy=Copy-JunoObject $entry;Initialize-BPUTransaction $copy;Sync-BPUTransaction $copy $state
        }elseif($backup.PSObject.Properties.Name -contains 'Transaction'){$copy=Copy-JunoObject $backup;Sync-JunoPolicy $copy $state}
        return [pscustomobject]@{Allowed=$true;Reason='Original respaldado; restauracion sujeta a revalidacion inmediata.'}
    }catch{return [pscustomobject]@{Allowed=$false;Reason=('Conflicto o estado desconocido: '+$_.Exception.Message)}}
}
function New-BPPInventoryRows($environment,$packages,$userBackup,$policyBackup,$policyState,$userStates,[string[]]$errors=@()) {
    $all=@{};$rows=New-Object 'Collections.Generic.List[object]'
    foreach($p in $packages){$all[$p.Family]=$p}
    foreach($family in @(@($userBackup.Items|ForEach-Object{$_.Family})+@($policyBackup.Owned))){
        if(-not $all.ContainsKey($family)){$all[$family]=[pscustomobject]@{Name=$family;Family=$family;PackageFullName='';Type='No instalada / no inventariada';Compatibility='Compatibilidad no verificada';Reason='Entrada recuperable aunque no figure en el inventario actual.';Protected=$false;Installed=$false}}
    }
    foreach($p in @($all.Values|Sort-Object Name,Family)){
        $entry=@($userBackup.Items|Where-Object{$_.Family -eq $p.Family}|Select-Object -First 1)
        $owned=$policyBackup.Owned -contains $p.Family
        if($p.Protected -and $entry.Count -eq 0 -and -not $owned){continue}
        $scopes=@()
        if($entry.Count -gt 0){$scopes+=@('User')}
        if($owned -or $entry.Count -eq 0){$scopes+=@('Policy')}
        foreach($scope in $scopes){
            $canRequest=$false;$canRestore=$false;$confirmed=$false;$request='Ninguna';$configuration='Sin solicitud propia registrada';$classification=$p.Compatibility
            $reason=$p.Reason+' '+$environment.Reason
            if($scope -eq 'Policy'){
                if($null -eq $policyState){$classification='Configuracion desconocida';$configuration='No se pudo consultar la directiva'}
                else{
                    $configured=$policyState.Global.Exists -or $policyState.Deny.Exists -or $policyState.Allow.Exists -or $policyState.UserControl.Exists
                    if($configured){$classification='Administrada mediante politica';$configuration='Configuracion de politica observada; efecto no verificado'}
                    if($policyState.Deny.Value -contains $p.Family){$request='ForceDeny observado en Registro'}
                    if($owned){
                        $check=Get-BPPRecoveryCheck $null $policyState 'Policy' $policyBackup
                        $canRestore=$environment.CanRestorePolicy -and $check.Allowed -and (-not $policyState.Global.Exists -or $policyState.Global.Value -eq 0)
                        $reason+=' '+$check.Reason
                        if($policyBackup.PSObject.Properties.Name -contains 'Transaction'){
                            $t=$policyBackup.Transaction
                            $confirmed=$check.Allowed -and $null -eq $t.Pending -and $t.Phase -eq 'Applied' -and $policyState.Deny.Value -contains $p.Family
                            $configuration=if($confirmed){'Escritura confirmada; efecto no verificado'}else{'Operacion pendiente de conciliar/restaurar'}
                        }else{$configuration='Respaldo historico; resultado desconocido'}
                    }
                    $canRequest=$environment.CanWrite -and $p.Installed -and -not $p.Protected -and $p.Compatibility -ceq 'Compatible'
                    if($canRequest){try{Assert-BPPPolicyOwnership $policyBackup $policyState -Request;if($policyBackup.PSObject.Properties.Name -contains 'Transaction'){$copy=Copy-JunoObject $policyBackup;Sync-JunoPolicy $copy $policyState;if($copy.Transaction.Phase -eq 'Restoring'){$canRequest=$false}}}catch{$canRequest=$false;$reason+=' '+$_.Exception.Message}}
                }
                $label='Equipo / directiva'
            }else{
                $label='Usuario / legado';$request='Cambio HKCU historico';$configuration='Respaldo HKCU pendiente de restaurar'
                $state=if($userStates.ContainsKey($p.Family)){$userStates[$p.Family]}else{$null}
                if($null -ne $state){$check=Get-BPPRecoveryCheck $entry[0] $state 'User';$canRestore=$environment.ManagementKnown -and -not $environment.Managed -and $check.Allowed;$reason+=' '+$check.Reason}
                else{$reason+=' No se pudo consultar el estado individual.';$classification='Configuracion desconocida'}
                if($null -eq $policyState -or $policyState.Global.Exists -or $policyState.Deny.Exists -or $policyState.Allow.Exists -or $policyState.UserControl.Exists){$canRestore=$false;$reason+=' Resolver primero la directiva de equipo o el error de consulta.'}
            }
            if($errors.Count -gt 0){$reason+=' '+($errors -join ' ')}
            $rows.Add([pscustomobject]@{Name=$p.Name;Family=$p.Family;PackageFullName=$p.PackageFullName;Type=$p.Type;Compatibility=$p.Compatibility;Classification=$classification;Configuration=$configuration;Scope=$scope;Method=$label;CanRequest=[bool]$canRequest;CanRestore=[bool]$canRestore;Reason=$reason;Requested=$request;WriteConfirmed=[bool]$confirmed;PolicyRecognized=$null;EffectiveVerified=$false;Installed=$p.Installed;Protected=$p.Protected})
        }
    }
    return @($rows.ToArray())
}
function Get-BPPPermissionView {
    $environment=Get-BPPEnvironment;$errors=New-Object 'Collections.Generic.List[string]'
    $packages=@();$user=[pscustomobject]@{Items=@()};$policy=[pscustomobject]@{Owned=@();MadeGlobal=$false};$state=$null;$states=@{}
    $backupsValid=$true
    try{$packages=@(Get-BPPPackages)}catch{$errors.Add('Inventario no disponible; se muestran los respaldos recuperables.')}
    try{$user=Get-BPUBackup}catch{$backupsValid=$false;$errors.Add('Respaldo HKCU invalido o inaccesible: '+$_.Exception.Message)}
    if($environment.Admin){try{$policy=Read-BPPBackup}catch{$backupsValid=$false;$errors.Add('Respaldo de equipo invalido o inaccesible: '+$_.Exception.Message)}}
    else{$errors.Add('Las restauraciones de equipo se consultan abriendo JUNO como administrador.')}
    try{$state=Get-JunoPolicyState}catch{$errors.Add('Configuracion de directiva desconocida: '+$_.Exception.Message)}
    foreach($r in $user.Items){try{$states[$r.Family]=Get-BPUState $r.Family}catch{$errors.Add('No se pudo consultar el permiso de '+$r.Family)}}
    $rows=@(New-BPPInventoryRows $environment $packages $user $policy $state $states $errors.ToArray())
    if(-not $backupsValid){foreach($r in $rows){$r.CanRequest=$false;$r.CanRestore=$false;$r.Classification='Configuracion desconocida'}}
    return [pscustomobject]@{Environment=$environment;Rows=$rows;Errors=@($errors.ToArray());BackupsValid=$backupsValid}
}
function Get-BPPSelectionActions($rows) {
    $selected=@($rows)
    return [pscustomobject]@{Request=($selected.Count -gt 0 -and @($selected|Where-Object{-not $_.CanRequest}).Count -eq 0);Restore=($selected.Count -gt 0 -and @($selected|Where-Object{-not $_.CanRestore}).Count -eq 0)}
}
function Confirm-BPPAction([string]$action,[int]$count) {
    $message=if($action -eq 'Request'){"¿Solicitar restriccion por directiva para $count app(s), en TODAS las cuentas? Puede afectar notificaciones y sincronizacion. Solo se comprobara la escritura del Registro; reconocimiento y eficacia no verificados."}else{"¿Restaurar los valores respaldados de $count entrada(s)? Se revalidaran originales, ambito y conflictos. Esto no demuestra el permiso efectivo de la aplicacion."}
    return ([Windows.Forms.MessageBox]::Show($message,'JUNO - confirmar','YesNo','Warning','Button2') -eq [Windows.Forms.DialogResult]::Yes)
}
function Invoke-BPPSelection([string]$action,$rows,[bool]$confirmed=$false) {
    Assert-JunoLease
    $selected=@($rows);$allowed=Get-BPPSelectionActions $selected
    if($action -cnotin @('Request','Restore')){throw 'Accion de permisos no permitida.'}
    if(-not $confirmed){return 'Operacion cancelada. No se aplicaron cambios.'}
    if(-not $allowed.$action){throw 'La seleccion contiene operaciones incompatibles o sin permisos. Actualiza la lista.'}
    if($action -eq 'Request'){return (Disable-BPPApps @($selected|ForEach-Object{$_.Family}|Select-Object -Unique))}
    $results=New-Object 'Collections.Generic.List[string]'
    try{
        foreach($scope in @('Policy','User')){
            $families=@($selected|Where-Object{$_.Scope -ceq $scope}|ForEach-Object{$_.Family}|Select-Object -Unique)
            if($families.Count -eq 0){continue}
            $result=if($scope -eq 'Policy'){Restore-BPPApps $families}else{Restore-BPUApps $families}
            $results.Add($result)
        }
    }catch{throw ('Restauracion parcial o fallida. '+($results -join ' ')+' '+$_.Exception.Message)}
    return ($results -join "`n")
}
function Open-BPPSettings([string]$family='') {
    if($family){Assert-JunoFamily $family;Start-Process -FilePath ('ms-settings:appsfeatures-app?'+[Uri]::EscapeDataString($family))}
    else{Start-Process -FilePath (Get-BgSettingsUri)}
}
