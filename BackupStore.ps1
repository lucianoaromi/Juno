# JUNO: persistencia compartida. Al importar este archivo no se consulta ni cambia Windows.
# Los destinos pertenecen al codigo; los JSON solo aportan valores validados.
function Get-JunoIdentity {
    $view=if([Environment]::Is64BitOperatingSystem){[Microsoft.Win32.RegistryView]::Registry64}else{[Microsoft.Win32.RegistryView]::Default}
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try {
        $key = $root.OpenSubKey('SOFTWARE\Microsoft\Cryptography', $false)
        try { $machine = $key.GetValue('MachineGuid', $null) } finally { if ($key) { $key.Dispose() } }
    } finally { $root.Dispose() }
    Assert-JunoGuid $machine
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { return [pscustomobject]@{ Sid=$identity.User.Value; Machine=$machine } } finally { $identity.Dispose() }
}
function Test-JunoAdmin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $p = New-Object Security.Principal.WindowsPrincipal($identity)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}
function Stop-JunoBackupValidation([string]$code,[string]$message) {
    $failure=[IO.InvalidDataException]::new($message)
    $failure.Data['JunoBackupCode']=$code
    throw $failure
}
function Get-JunoBackupFailureCode([Exception]$failure) {
    # RuntimeException/MethodInvocationException pueden envolver el error original.
    for($depth=0;$null -ne $failure -and $depth -lt 32;$depth++) {
        if($failure.Data.Contains('JunoBackupCode')) { return [string]$failure.Data['JunoBackupCode'] }
        $failure=$failure.InnerException
    }
    return $null
}
function Get-JunoBackupFailureText([string]$code) {
    # Mensajes seguros para la vista: nunca interpolar SID, MachineGuid, JSON o rutas.
    switch -CaseSensitive ($code) {
        'UserMismatch' { return 'La identidad del respaldo no coincide con la de esta ejecución. Comprueba la cuenta y el entorno aislado. No se cambia el SID ni se omite la validación.' }
        'MachineMismatch' { return 'El respaldo corresponde a otro equipo. No se permite usarlo para modificar o restaurar este equipo.' }
        'ScopeMismatch' { return 'El ámbito del respaldo no coincide con la operación de usuario o equipo. No se permite trasladarlo entre ámbitos.' }
        'KindMismatch' { return 'El respaldo corresponde a otro módulo. No se utilizará en esta operación.' }
        'FormatMismatch' { return 'El formato de respaldo no es compatible. Se conserva el archivo.' }
        'UnverifiableLegacy' { return 'El respaldo histórico general no permite verificar usuario y equipo. Los cambios y la restauración quedan bloqueados; requiere recuperación supervisada.' }
        default { return 'No se pudo validar o leer el respaldo. Se conserva el archivo; requiere revisión antes de modificar o restaurar.' }
    }
}
function Enter-JunoLease([string]$name = 'Global\JUNO.0.8.State') {
    if (Get-Variable JunoLease -Scope Script -ErrorAction SilentlyContinue) {
        if ($null -ne $script:JunoLease) { throw 'JUNO ya posee un bloqueo; no se permite adquirirlo recursivamente.' }
    }
    $acl = New-Object Security.AccessControl.MutexSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = if ($sid -eq 'S-1-5-32-545') { 'Synchronize,Modify,ReadPermissions' } else { 'FullControl' }
        $acl.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.MutexRights]$rights, 'Allow'))
    }
    $mutex = $null; $owned = $false; $abandoned = $false
    try {
        $created = $false
        # OpenExisting solicita solo los derechos necesarios, tambien entre elevacion y usuario normal.
        try { $mutex = [Threading.Mutex]::OpenExisting($name, [Security.AccessControl.MutexRights]'Synchronize,Modify,ReadPermissions') }
        catch [Threading.WaitHandleCannotBeOpenedException] {
            $mutex = [Threading.Mutex]::new($false, $name, [ref]$created, $acl)
        }
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true; $abandoned = $true }
        if (-not $owned) { throw 'Recurso ocupado: otra instancia de JUNO esta abierta. Cierrala antes de continuar.' }
        $script:JunoLease = [pscustomobject]@{ Mutex=$mutex; Thread=[Threading.Thread]::CurrentThread.ManagedThreadId; Abandoned=$abandoned }
    } catch {
        if ($owned) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw
    }
}
function Assert-JunoLease {
    if (-not (Get-Variable JunoLease -Scope Script -ErrorAction SilentlyContinue) -or
        $null -eq $script:JunoLease -or $script:JunoLease.Thread -ne [Threading.Thread]::CurrentThread.ManagedThreadId) {
        throw 'Operacion rechazada: JUNO no posee el bloqueo exclusivo de configuracion.'
    }
}
function Exit-JunoLease {
    if ((Get-Variable JunoLease -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:JunoLease) {
        try { $script:JunoLease.Mutex.ReleaseMutex() } finally { $script:JunoLease.Mutex.Dispose(); $script:JunoLease = $null }
    }
}
function Assert-JunoObject($value, [string[]]$required, [string[]]$optional = @()) {
    # Hashtable antes de serializar; PSCustomObject al leer. No admitir arrays ni escalares.
    if ($value -is [System.Collections.IDictionary]) { $names = @($value.Keys) }
    elseif ($null -ne $value -and $value.GetType() -eq [Management.Automation.PSCustomObject]) { $names = @($value.PSObject.Properties.Name) }
    else { throw 'Respaldo invalido: se esperaba un objeto.' }
    foreach ($name in $required) { if ($names -cnotcontains $name) { throw "Respaldo incompleto: falta $name." } }
    foreach ($name in $names) { if (($required + $optional) -cnotcontains $name) { throw "Respaldo invalido: propiedad no admitida ($name)." } }
}
function Assert-JunoString($value, [int]$max = 16383, [switch]$Empty) {
    if ($value -isnot [string] -or $value.Length -gt $max -or $value.IndexOf([char]0) -ge 0 -or
        (-not $Empty -and $value.Length -eq 0)) { throw 'Respaldo invalido: texto ausente o fuera de limites.' }
}
function Assert-JunoBool($value) { if ($value -isnot [bool]) { throw 'Respaldo invalido: se esperaba true/false.' } }
function Assert-JunoInt($value, [long]$min = [int]::MinValue, [long]$max = [int]::MaxValue) {
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $min -or $value -gt $max) {
        throw 'Respaldo invalido: entero fuera de limites o tipo incorrecto.'
    }
}
function Assert-JunoGuid($value) {
    Assert-JunoString $value 36
    if ($value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'Respaldo invalido: GUID no valido.' }
}
function Assert-JunoArray($value, [int]$max = 4096) {
    if ($value -isnot [array] -or $value.Count -gt $max) { throw 'Respaldo invalido: se esperaba una lista acotada.' }
}
function Assert-JunoBase64($value, [int]$min, [int]$max) {
    Assert-JunoString $value ($max * 2 + 4)
    try { $bytes = [Convert]::FromBase64String($value) } catch { throw 'Respaldo invalido: binario no valido.' }
    if ($bytes.Length -lt $min -or $bytes.Length -gt $max -or [Convert]::ToBase64String($bytes) -cne $value) {
        throw 'Respaldo invalido: longitud o codificacion binaria no admitida.'
    }
}
function Assert-JunoFamily($value) {
    Assert-JunoString $value 255
    if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*_[A-Za-z0-9]+$') { throw 'Respaldo invalido: identificador de paquete no permitido.' }
}
function Assert-JunoFamilies($values) {
    Assert-JunoArray $values
    $seen = @{}
    foreach ($value in $values) { Assert-JunoFamily $value; if ($seen.ContainsKey($value)) { throw 'Respaldo invalido: paquete duplicado.' }; $seen[$value] = $true }
}
function Assert-JunoValueSnapshot($snap, [string]$kind) {
    $field = if ($kind -eq 'Binary') { 'Data' } else { 'Value' }
    Assert-JunoObject $snap @('Exists',$field)
    Assert-JunoBool $snap.Exists
    if (-not $snap.Exists) { if ($null -ne $snap.$field) { throw 'Respaldo invalido: ausencia con datos.' }; return }
    switch ($kind) {
        'Binary' {
            Assert-JunoBase64 $snap.Data 12 12
            if ([Convert]::FromBase64String($snap.Data)[0] -notin @(2,3,6,7)) { throw 'Estado binario de inicio no reconocido.' }
        }
        'Deny' { Assert-JunoFamilies $snap.Value }
        'Global' { Assert-JunoInt $snap.Value 0 2 }
        default { Assert-JunoInt $snap.Value }
    }
}
function Get-JunoStartupFolder([string]$hive) {
    $folder = if ($hive -eq 'CurrentUser') { 'Startup' } else { 'CommonStartup' }
    return [Environment]::GetFolderPath([Environment+SpecialFolder]$folder)
}
function Assert-JunoStartupTarget($record) {
    foreach ($name in @('Id','Name','ApprovalHive','ApprovalView','ApprovalKey','ApprovalValue','SourceType','SourceHive','SourceView','SourceKey','SourceValue')) {
        Assert-JunoString $record.$name 16383 -Empty:($name -in @('SourceHive','SourceView'))
    }
    if ($record.ApprovalHive -cnotin @('CurrentUser','LocalMachine')) { throw 'Destino de inicio no permitido: hive.' }
    $nativeView = if ([Environment]::Is64BitOperatingSystem) { 'Registry64' } else { 'Default' }
    $root = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    if ($record.SourceType -ceq 'Registro') {
        $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
        if ($record.SourceHive -cne $record.ApprovalHive -or $record.SourceKey -cne $run -or
            $record.SourceValue -cne $record.ApprovalValue) { throw 'Destino de inicio no permitido: origen Run.' }
        $suffix = 'Run'; $view = if ($record.SourceHive -eq 'CurrentUser') { 'Default' } else { $nativeView }
        if ($record.SourceHive -eq 'LocalMachine' -and [Environment]::Is64BitOperatingSystem -and $record.SourceView -ceq 'Registry32') { $suffix = 'Run32' }
        elseif ($record.SourceView -cne $view) { throw 'Destino de inicio no permitido: vista del origen.' }
        if ($record.ApprovalKey -cne "$root\$suffix" -or $record.ApprovalView -cne $view -or
            $record.Id -cne "$($record.SourceHive)|$($record.SourceView)|$run|$($record.SourceValue)") { throw 'Destino de inicio no permitido: clave, vista o identificador.' }
    } elseif ($record.SourceType -ceq 'Archivo') {
        $folder = Get-JunoStartupFolder $record.ApprovalHive
        if ([string]::IsNullOrEmpty($folder) -or $record.SourceHive -cne '' -or $record.SourceView -cne '' -or
            $record.ApprovalKey -cne "$root\StartupFolder" -or $record.ApprovalView -cne $nativeView -or
            $record.SourceValue.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $record.SourceKey -cne (Join-Path $folder $record.SourceValue) -or $record.SourceValue -cne $record.ApprovalValue -or
            $record.Id -cne "Archivo|$($record.SourceKey)") { throw 'Destino de inicio no permitido: carpeta, archivo o vista.' }
    } else { throw 'Destino de inicio no permitido: tipo de origen.' }
}
function Assert-JunoStartupData($data, [string]$scope = 'Any') {
    Assert-JunoObject $data @('Entries'); Assert-JunoArray $data.Entries
    $ids = @{}; $targets = @{}
    foreach ($r in $data.Entries) {
        Assert-JunoObject $r @('Id','Name','ApprovalHive','ApprovalView','ApprovalKey','ApprovalValue','SourceType','SourceHive','SourceView','SourceKey','SourceValue','Fingerprint','OriginalExists','OriginalData','LastWrittenData') @('Transaction')
        Assert-JunoStartupTarget $r
        if (($scope -eq 'User' -and $r.ApprovalHive -ne 'CurrentUser') -or ($scope -eq 'Machine' -and $r.ApprovalHive -ne 'LocalMachine')) { throw 'Respaldo de inicio de otro ambito.' }
        Assert-JunoBase64 $r.Fingerprint 32 32
        Assert-JunoValueSnapshot ([pscustomobject]@{Exists=$r.OriginalExists;Data=$r.OriginalData}) 'Binary'
        if ($null -ne $r.LastWrittenData) { Assert-JunoValueSnapshot ([pscustomobject]@{Exists=$true;Data=$r.LastWrittenData}) 'Binary' }
        $target = "$($r.ApprovalHive)|$($r.ApprovalView)|$($r.ApprovalKey)|$($r.ApprovalValue)"
        if ($ids.ContainsKey($r.Id) -or $targets.ContainsKey($target)) { throw 'Respaldo invalido: inicio duplicado.' }; $ids[$r.Id]=$true; $targets[$target]=$true
        if ($r.PSObject.Properties.Name -contains 'Transaction') {
            $t = $r.Transaction; Assert-JunoObject $t @('Version','Confirmed','Pending'); Assert-JunoInt $t.Version 1 1
            Assert-JunoValueSnapshot $t.Confirmed 'Binary'
            if ($null -ne $t.Pending) {
                Assert-JunoObject $t.Pending @('Exists','Data','Action')
                if ($t.Pending.Action -cnotin @('Apply','Restore')) { throw 'Accion de inicio incompatible.' }
                Assert-JunoValueSnapshot ([pscustomobject]@{Exists=$t.Pending.Exists;Data=$t.Pending.Data}) 'Binary'
            }
        }
    }
}
function Get-JunoVisualTargets {
    return @(
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects','VisualFXSetting','DWord'),
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','TaskbarAnimations','DWord'),
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','IconsOnly','DWord'),
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','ListviewAlphaSelect','DWord'),
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','ListviewShadow','DWord'),
        @('Software\Microsoft\Windows\DWM','EnableAeroPeek','DWord'),
        @('Control Panel\Desktop','DragFullWindows','String'), @('Control Panel\Desktop','FontSmoothing','String'),
        @('Control Panel\Desktop','UserPreferencesMask','Binary'), @('Control Panel\Desktop\WindowMetrics','MinAnimate','String'),
        @('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize','EnableTransparency','DWord')
    )
}
function Assert-JunoVisualSnapshot($snap, [switch]$Transparency) {
    Assert-JunoObject $snap @('Exists','Kind','Value')
    Assert-JunoBool $snap.Exists
    if (-not $snap.Exists) {
        if ($null -ne $snap.Kind -or $null -ne $snap.Value) { throw 'Respaldo visual invalido: ausencia con datos.' }; return
    }
    Assert-JunoString $snap.Value 1024 -Empty
    if ($Transparency) { if ($snap.Kind -cne 'DWord') { throw 'Tipo de transparencia no permitido.' } }
    switch -CaseSensitive ($snap.Kind) {
        'DWord' { $n=0; if (-not [int]::TryParse($snap.Value,[ref]$n)) { throw 'DWORD visual invalido.' } }
        'String' { }
        'Binary' { Assert-JunoBase64 $snap.Value 8 8 }
        default { throw 'Tipo de Registro visual no permitido.' }
    }
}
function Assert-JunoVisualRegistry($snaps) {
    Assert-JunoArray $snaps 10; $seen=@{}
    $allowed = @(Get-JunoVisualTargets | Where-Object { $_[1] -cne 'EnableTransparency' })
    foreach ($s in $snaps) {
        Assert-JunoObject $s @('Key','Name','Exists','Kind','Value')
        $match = @($allowed | Where-Object { $_[0] -ceq $s.Key -and $_[1] -ceq $s.Name })
        if ($match.Count -ne 1 -or $seen.ContainsKey("$($s.Key)|$($s.Name)")) { throw 'Destino de restauracion visual no permitido o duplicado.' }
        $seen["$($s.Key)|$($s.Name)"]=$true
        Assert-JunoVisualSnapshot ([pscustomobject]@{Exists=$s.Exists;Kind=$s.Kind;Value=$s.Value})
        if ($s.Exists -and $s.Kind -cne $match[0][2]) { throw 'Tipo del destino visual no permitido.' }
    }
}
function Assert-JunoEffects($effects) {
    $names = @('UIEffects','ClientAreaAnimation','MenuAnimation','ComboBoxAnimation','ListSmoothScrolling','MenuFade','SelectionFade','ToolTipAnimation','ToolTipFade','CursorShadow','DropShadow','MinimizeAnimation','FontSmoothing','DragFullWindows')
    Assert-JunoObject $effects @() $names
    if ($effects -is [Collections.IDictionary]) { foreach ($n in $effects.Keys) { Assert-JunoBool $effects[$n] } }
    else { foreach ($p in $effects.PSObject.Properties) { Assert-JunoBool $p.Value } }
}
function Assert-JunoVisualState($state) {
    Assert-JunoObject $state @('Effects','Registry'); Assert-JunoEffects $state.Effects; Assert-JunoVisualRegistry $state.Registry
}
function Assert-JunoBackupData([string]$kind, $data, [string]$scope = 'User') {
    switch -CaseSensitive ($kind) {
        'Startup' { Assert-JunoStartupData $data $scope }
        'BPU' {
            Assert-JunoObject $data @('Version','Sid','Items'); Assert-JunoInt $data.Version 1 1
            if ($data.Sid -cne (Get-JunoIdentity).Sid) { throw 'El respaldo de permisos pertenece a otro usuario.' }
            Assert-JunoArray $data.Items; $seen=@{}
            foreach ($r in $data.Items) {
                Assert-JunoObject $r @('Family','Disabled','DisabledByUser') @('Transaction'); Assert-JunoFamily $r.Family
                if ($seen.ContainsKey($r.Family)) { throw 'Permiso duplicado.' }; $seen[$r.Family]=$true
                foreach ($n in @('Disabled','DisabledByUser')) { Assert-JunoValueSnapshot $r.$n 'DWord' }
                if ($r.PSObject.Properties.Name -contains 'Transaction') {
                    $t=$r.Transaction; Assert-JunoObject $t @('Version','Phase','Disabled','DisabledByUser'); Assert-JunoInt $t.Version 1 1
                    if ($t.Phase -cnotin @('Applying','Applied','Restoring')) { throw 'Fase de permisos incompatible.' }
                    foreach ($n in @('Disabled','DisabledByUser')) {
                        Assert-JunoObject $t.$n @('Confirmed','Pending'); Assert-JunoValueSnapshot $t.$n.Confirmed 'DWord'
                        if ($null -ne $t.$n.Pending) { Assert-JunoValueSnapshot $t.$n.Pending 'DWord' }
                    }
                }
            }
        }
        'Policy' {
            Assert-JunoObject $data @('Owned','MadeGlobal') @('Transaction'); Assert-JunoFamilies $data.Owned; Assert-JunoBool $data.MadeGlobal
            if ($data.PSObject.Properties.Name -contains 'Transaction') {
                $t=$data.Transaction; Assert-JunoObject $t @('Version','Phase','Original','Confirmed','Pending','Guard'); Assert-JunoInt $t.Version 1 1
                if ($t.Phase -cnotin @('Applying','Applied','Restoring','Restored')) { throw 'Fase de directiva incompatible.' }
                foreach ($n in @('Original','Confirmed')) {
                    Assert-JunoObject $t.$n @('Deny','Global')
                    Assert-JunoValueSnapshot $t.$n.Deny 'Deny'; Assert-JunoValueSnapshot $t.$n.Global 'Global'
                }
                Assert-JunoObject $t.Guard @('Allow','UserControl'); Assert-JunoValueSnapshot $t.Guard.Allow 'Deny'; Assert-JunoValueSnapshot $t.Guard.UserControl 'Deny'
                if ($null -ne $t.Pending) {
                    Assert-JunoObject $t.Pending @('Field','Target')
                    if ($t.Pending.Field -cnotin @('Deny','Global')) { throw 'Destino de directiva incompatible.' }
                    Assert-JunoValueSnapshot $t.Pending.Target $t.Pending.Field
                }
            }
        }
        'Trim' {
            Assert-JunoObject $data @('Original','Date','Action') @('Transaction'); Assert-JunoInt $data.Original 1 1
            Assert-JunoString $data.Date 64; $d=[DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse($data.Date,[ref]$d) -or $data.Action -cne 'NTFS DisableDeleteNotify') { throw 'Respaldo de TRIM incompatible.' }
            if ($data.PSObject.Properties.Name -contains 'Transaction') {
                $t=$data.Transaction; Assert-JunoObject $t @('Version','Confirmed','Pending','Phase'); Assert-JunoInt $t.Version 1 1
                Assert-JunoInt $t.Confirmed 0 1; if ($null -ne $t.Pending) { Assert-JunoInt $t.Pending 0 1 }
                if ($t.Phase -cnotin @('Applying','Applied','Restoring','Restored')) { throw 'Fase de TRIM incompatible.' }
                if (($t.Phase -eq 'Applied' -and $t.Confirmed -ne 0) -or ($t.Phase -eq 'Restored' -and $t.Confirmed -ne 1) -or
                    ($t.Phase -in @('Applied','Restored') -and $null -ne $t.Pending)) { throw 'Diario de TRIM contradictorio.' }
            }
        }
        'Power' {
            Assert-JunoObject $data @('PowerScheme','CreatedPowerScheme') @('Transaction')
            foreach ($n in @('PowerScheme','CreatedPowerScheme')) { if ($null -ne $data.$n) { Assert-JunoGuid $data.$n } }
            if ($data.PSObject.Properties.Name -contains 'Transaction') {
                $t=$data.Transaction; Assert-JunoObject $t @('Version','Confirmed','Pending','Phase'); Assert-JunoInt $t.Version 1 1; Assert-JunoGuid $t.Confirmed
                if ($null -ne $t.Pending) { Assert-JunoGuid $t.Pending }
                if ($t.Phase -cnotin @('Applying','Applied','Restoring','Restored')) { throw 'Fase de energia incompatible.' }
                if (($t.Phase -eq 'Restored' -and $null -ne $data.PowerScheme) -or ($t.Phase -ne 'Restored' -and $null -eq $data.PowerScheme) -or
                    ($t.Phase -in @('Applied','Restored') -and $null -ne $t.Pending)) { throw 'Diario de energia contradictorio o sin original.' }
            }
        }
        'General' {
            Assert-JunoObject $data @('PowerScheme','CreatedPowerScheme','VisualEffects') @('VisualRegistry','TransparencyBackup','Journal')
            foreach ($n in @('PowerScheme','CreatedPowerScheme')) { if ($null -ne $data.$n) { Assert-JunoGuid $data.$n } }
            if ($null -ne $data.VisualEffects) { Assert-JunoEffects $data.VisualEffects }
            if ($data.PSObject.Properties.Name -contains 'VisualRegistry' -and $null -ne $data.VisualRegistry) { Assert-JunoVisualRegistry $data.VisualRegistry }
            if ($data.PSObject.Properties.Name -contains 'TransparencyBackup' -and $null -ne $data.TransparencyBackup) { Assert-JunoVisualSnapshot $data.TransparencyBackup -Transparency }
            if ($data.PSObject.Properties.Name -contains 'Journal') {
                Assert-JunoObject $data.Journal @('Version','Visual','Transparency'); Assert-JunoInt $data.Journal.Version 1 1
                foreach ($n in @('Visual','Transparency')) {
                    $t=$data.Journal.$n; if ($null -eq $t) { continue }
                    if (($n -eq 'Visual' -and $null -eq $data.VisualEffects -and $null -eq $data.VisualRegistry) -or
                        ($n -eq 'Transparency' -and $null -eq $data.TransparencyBackup)) { throw 'Diario sin el respaldo original; no se capturara el estado actual como reemplazo.' }
                    Assert-JunoObject $t @('Confirmed','Pending','Phase')
                    if ($t.Phase -cnotin @('Applying','Applied','Partial','Restoring')) { throw 'Fase visual incompatible.' }
                    if ($n -eq 'Visual') { Assert-JunoVisualState $t.Confirmed; Assert-JunoBool $t.Pending }
                    else {
                        Assert-JunoVisualSnapshot $t.Confirmed -Transparency
                        if ($null -ne $t.Pending) { Assert-JunoVisualSnapshot $t.Pending -Transparency }
                    }
                }
            }
        }
        default { throw 'Tipo de respaldo no permitido.' }
    }
}

function Assert-JunoLocalPath([string]$path) {
    if ($path -notmatch '^[A-Za-z]:\\' -or $path.Substring(2).Contains(':') -or $path -match '(^|\\)\.\.?($|\\)' -or $path.Contains('/')) { throw 'Ruta de respaldo no local o no canonica.' }
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($path)).DriveType -ne [IO.DriveType]::Fixed) { throw 'Los respaldos requieren una unidad local fija; no se permiten unidades de red ni extraibles.' }
    $walk = $path
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            if ((Get-Item -LiteralPath $walk -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Ruta de respaldo con enlace o punto de reanalisis; no se utilizara.' }
        }
        $parent = [IO.Path]::GetDirectoryName($walk)
        if ($parent -eq $walk) { break }; $walk=$parent
    }
}
function Get-JunoMachineFolder { return (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'JUNO-Backups') }
function New-JunoMachineSecurity([switch]$Directory) {
    $acl=if($Directory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $identity=[Security.Principal.SecurityIdentifier]::new($sid)
        $rule=if($Directory){[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')}
              else{[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','Allow')}
        $acl.AddAccessRule($rule)
    }
    return $acl
}
function Assert-JunoMachineParents([string]$path) {
    $trusted=@('S-1-5-18','S-1-5-32-544',([Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value))
    $walk=[IO.Path]::GetDirectoryName($path)
    $mask=[Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    while($walk){
        Assert-JunoLocalPath $walk
        $acl=Get-Acl -LiteralPath $walk -ErrorAction Stop
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Almacen de equipo rechazado: un antecesor tiene propietario no confiable.'}
        foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin $trusted -and
                -not($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and ($ace.FileSystemRights -band $mask)){
                throw 'Almacen de equipo rechazado: un antecesor permite reemplazar su contenido sin autorizacion administrativa.'
            }
        }
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
}
function Assert-JunoMachineAcl([string]$path) {
    Assert-JunoLocalPath $path
    if (-not (Test-Path -LiteralPath $path)) { return }
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $trusted = @('S-1-5-18','S-1-5-32-544')
    if ($owner -notin $trusted) { throw 'Respaldo de equipo rechazado: propietario no administrativo.' }
    # No basta con ocultarlo: ningun SID ajeno puede escribir, borrar, cambiar DACL o adquirir propiedad.
    $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin $trusted -and ($ace.FileSystemRights -band $writeMask)) {
            throw 'Respaldo de equipo rechazado: permisos de escritura no administrativos.'
        }
    }
    Assert-JunoMachineParents $path
}
function Initialize-JunoMachineFolder {
    Assert-JunoLease
    if (-not (Test-JunoAdmin)) { throw 'Se necesitan permisos de administrador para respaldos de equipo.' }
    $folder=Get-JunoMachineFolder; Assert-JunoLocalPath $folder
    Assert-JunoMachineParents $folder
    if (-not (Test-Path -LiteralPath $folder)) {
        $acl=New-JunoMachineSecurity -Directory
        ([IO.DirectoryInfo]::new($folder)).Create($acl)
    }
    Assert-JunoMachineAcl $folder
}
function Get-JunoStorePath([string]$kind, [string]$scope='User') {
    $files=@{General='backup.json';Startup='inicio-backup.json';BPU='background-user.json';Policy='background-policy.json';Trim='trim-backup.json';Power='power-backup.json'}
    if (-not $files.ContainsKey($kind) -or $scope -cnotin @('User','Machine')) { throw 'Almacen no permitido.' }
    $folder = if ($scope -eq 'Machine') { Get-JunoMachineFolder } else { $script:AppFolder }
    return (Join-Path $folder $files[$kind])
}
function ConvertFrom-JunoJson([string]$json) {
    if ($json.Length -gt 2097152) { throw 'Respaldo demasiado grande.' }
    # ConvertFrom-Json 5.1 puede ocultar claves duplicadas: rechazarlas antes, incluso con escapes.
    $lexemes=[regex]::Matches($json,'"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\],:]')
    $stack=New-Object Collections.Stack; $end=0
    for ($i=0;$i -lt $lexemes.Count;$i++) {
        $m=$lexemes[$i]
        if ($json.Substring($end,$m.Index-$end) -notmatch '^\s*$') { throw 'JSON invalido.' }; $end=$m.Index+$m.Length
        if ($m.Value -eq '{') { $stack.Push(@{}) }
        elseif ($m.Value -eq '[') { $stack.Push('array') }
        elseif ($m.Value -in @('}',']')) { if ($stack.Count -eq 0) { throw 'JSON incompleto.' }; [void]$stack.Pop() }
        elseif ($m.Value.StartsWith('"') -and $i+1 -lt $lexemes.Count -and $lexemes[$i+1].Value -eq ':' -and $stack.Count -gt 0) {
            $obj=$stack.Peek()
            if ($obj -is [hashtable]) {
                $key=ConvertFrom-Json -InputObject ('['+$m.Value+']') -ErrorAction Stop
                if ($obj.ContainsKey([string]$key)) { throw 'JSON rechazado: propiedad duplicada.' }; $obj[[string]$key]=$true
            }
        }
        if ($stack.Count -gt 32) { throw 'JSON demasiado anidado.' }
    }
    if ($stack.Count -ne 0 -or $json.Substring($end) -notmatch '^\s*$') { throw 'JSON incompleto o invalido.' }
    try { return ,(ConvertFrom-Json -InputObject $json -ErrorAction Stop) } catch { throw 'Respaldo invalido: no se pudo interpretar el JSON. Se conserva el archivo.' }
}
function Read-JunoBytes([string]$path) {
    Assert-JunoLocalPath $path
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 2097152) { throw 'Respaldo demasiado grande.' }
        $bytes=New-Object byte[] ([int]$stream.Length); $offset=0
        while ($offset -lt $bytes.Length) { $n=$stream.Read($bytes,$offset,$bytes.Length-$offset); if ($n -eq 0) { throw 'Lectura incompleta.' }; $offset+=$n }
        return ,$bytes
    } finally { $stream.Dispose() }
}
function ConvertFrom-JunoBytes([byte[]]$bytes) {
    $utf8=[Text.UTF8Encoding]::new($false,$true)
    return (ConvertFrom-JunoJson ($utf8.GetString($bytes).TrimStart([char]0xfeff)))
}
function Get-JunoHash([byte[]]$bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}
function Read-JunoDocument([string]$path,[string]$kind,[string]$scope,[switch]$Legacy) {
    if ($scope -eq 'Machine' -and -not $Legacy) { Assert-JunoMachineAcl (Get-JunoMachineFolder); Assert-JunoMachineAcl $path }
    $obj=ConvertFrom-JunoBytes (Read-JunoBytes $path)
    if ($null -ne $obj -and $obj.PSObject.Properties.Name -contains 'Format') {
        Assert-JunoObject $obj @('Format','Version','Kind','Scope','Sid','Machine','Revision','Data')
        Assert-JunoInt $obj.Version 1 1; Assert-JunoGuid $obj.Revision
        $id=Get-JunoIdentity
        if ($obj.Format -cne 'JUNO.Backup') { Stop-JunoBackupValidation 'FormatMismatch' 'Formato de respaldo incompatible.' }
        if ($obj.Kind -cne $kind) { Stop-JunoBackupValidation 'KindMismatch' 'Respaldo de otro modulo.' }
        if ($obj.Scope -cne $scope -or ($scope -eq 'Machine' -and $null -ne $obj.Sid)) { Stop-JunoBackupValidation 'ScopeMismatch' 'Respaldo de otro ambito.' }
        if ($obj.Machine -ine $id.Machine) { Stop-JunoBackupValidation 'MachineMismatch' 'Respaldo de otro equipo.' }
        if ($scope -eq 'User' -and $obj.Sid -cne $id.Sid) { Stop-JunoBackupValidation 'UserMismatch' 'La identidad del respaldo no coincide con la de esta ejecucion.' }
        $data=$obj.Data
    } else {
        # General antiguo no contiene SID ni equipo. -Legacy no acredita su procedencia.
        if ($kind -eq 'General') { Stop-JunoBackupValidation 'UnverifiableLegacy' 'Respaldo general historico sin identidad verificable; requiere recuperacion supervisada.' }
        if ($scope -eq 'Machine' -and -not $Legacy) { throw 'Respaldo de equipo sin identidad; requiere importacion explicita.' }
        $data=$obj
    }
    $validationScope=if ($Legacy -and $kind -eq 'Startup') { 'Any' } else { $scope }
    Assert-JunoBackupData $kind $data $validationScope
    return $data
}
function Read-JunoStore([string]$kind,[string]$scope='User',$default) {
    Assert-JunoLease
    $path=Get-JunoStorePath $kind $scope
    if (-not (Test-Path -LiteralPath $path)) {
        if (@(Get-JunoRecoveryCandidates $path).Count -gt 0) { throw "Respaldo principal ausente; hay copias recuperables en $path.previous.*. No se asumira un estado vacio." }
        return $default
    }
    try { return (Read-JunoDocument $path $kind $scope -Legacy:($scope -eq 'User' -and $kind -eq 'Startup')) }
    catch {
        $code=Get-JunoBackupFailureCode $_.Exception
        if($null -eq $code){$code='InvalidBackup'}
        # Conservar el diagnóstico al envolverlo, sin publicar datos del archivo.
        Stop-JunoBackupValidation $code ((Get-JunoBackupFailureText $code)+' No se reemplazo; revisar copias previous e history.')
    }
}
function Get-JunoRecoveryCandidates([string]$path) {
    $folder=[IO.Path]::GetDirectoryName($path)
    Assert-JunoLocalPath $folder
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop | Where-Object {
        $_.Name.StartsWith(([IO.Path]::GetFileName($path)+'.previous.'),[StringComparison]::Ordinal) -or
        $_.Name.StartsWith(([IO.Path]::GetFileName($path)+'.history.'),[StringComparison]::Ordinal)
    } | Sort-Object LastWriteTimeUtc -Descending)
}
function Write-JunoNewFile([string]$path,[byte[]]$bytes,[switch]$Machine) {
    Assert-JunoLocalPath $path
    # Heredar DACL no basta: un propietario usuario podria cambiarla con su token no elevado.
    # Asignar propietario Administradores y DACL protegida en la misma creacion del archivo.
    if($Machine){
        $stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,
            [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,(New-JunoMachineSecurity))
    } else {
        $stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    }
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ((Get-JunoHash (Read-JunoBytes $path)) -cne (Get-JunoHash $bytes)) { throw 'No se pudo verificar la copia escrita.' }
}
function Copy-JunoHistory([string]$source,[string]$destination,[switch]$Machine) {
    # CreateNew, nunca se pisa una copia; verificacion byte a byte por SHA-256.
    $bytes=Read-JunoBytes $source
    Write-JunoNewFile $destination $bytes -Machine:$Machine
    return $destination
}
function Replace-JunoFile([string]$temp,[string]$path,[string]$previous) {
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,$previous,$false) }
    else { [IO.File]::Move($temp,$path) }
}
function Write-JunoStore([string]$kind,$data,[string]$scope='User') {
    Assert-JunoLease
    # Roundtrip antes de validar para que el contrato sea el JSON que realmente se va a guardar.
    $data=ConvertFrom-JunoJson ($data | ConvertTo-Json -Depth 24 -Compress)
    Assert-JunoBackupData $kind $data $scope
    if ($scope -eq 'Machine') { Initialize-JunoMachineFolder }
    $path=Get-JunoStorePath $kind $scope; $folder=[IO.Path]::GetDirectoryName($path)
    Assert-JunoLocalPath $path
    if (-not (Test-Path -LiteralPath $folder)) { [void][IO.Directory]::CreateDirectory($folder) }
    if ($scope -eq 'Machine') { Assert-JunoMachineAcl $folder; Assert-JunoMachineAcl $path }
    if (Test-Path -LiteralPath $path) {
        # No reparar silenciosamente un principal corrupto con datos en memoria.
        [void](Read-JunoDocument $path $kind $scope -Legacy:($scope -eq 'User' -and $kind -eq 'Startup'))
        $old=ConvertFrom-JunoBytes (Read-JunoBytes $path)
        if ($old.PSObject.Properties.Name -notcontains 'Format') {
            [void](Copy-JunoHistory $path ($path+'.history.'+[Guid]::NewGuid().ToString('N')+'.json'))
        }
    } elseif (@(Get-JunoRecoveryCandidates $path).Count -gt 0) { throw 'Principal ausente con copias anteriores: requiere recuperacion explicita.' }
    $id=Get-JunoIdentity
    $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind=$kind;Scope=$scope;Sid=$(if($scope -eq 'User'){$id.Sid}else{$null});Machine=$id.Machine;Revision=[Guid]::NewGuid().ToString();Data=$data}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($doc | ConvertTo-Json -Depth 24))
    $temp=$path+'.pending.'+[Guid]::NewGuid().ToString('N')+'.json'
    $previous=$path+'.previous.'+[Guid]::NewGuid().ToString('N')+'.json'
    # Ante error no se borra ni el principal ni las evidencias temporales.
    Write-JunoNewFile $temp $bytes -Machine:($scope -eq 'Machine')
    [void](Read-JunoDocument $temp $kind $scope)
    Replace-JunoFile $temp $path $previous
    [void](Read-JunoDocument $path $kind $scope)
}
function Restore-JunoStoreCopy([string]$kind,[string]$copy,[string]$scope='User') {
    Assert-JunoLease
    $path=Get-JunoStorePath $kind $scope
    $candidates=@(Get-JunoRecoveryCandidates $path | Where-Object { $_.FullName -ceq $copy })
    if ($candidates.Count -ne 1) { throw 'Solo se permite recuperar una copia previous/history del mismo almacen.' }
    if ($scope -eq 'Machine') { Initialize-JunoMachineFolder }
    $temp=$path+'.recovery.'+[Guid]::NewGuid().ToString('N')+'.json'
    $raw=ConvertFrom-JunoBytes (Read-JunoBytes $copy)
    if ($scope -eq 'Machine' -and ($raw.PSObject.Properties.Name -notcontains 'Format' -or $raw.Scope -ceq 'User')) {
        # Una importacion puede interrumpirse despues de guardar la evidencia historica.
        # Esa evidencia no se convierte silenciosamente en autoridad de equipo.
        Assert-JunoMachineAcl $copy
        $legacyKind=if($kind -eq 'Power'){'General'}else{$kind}
        $data=Read-JunoDocument $copy $legacyKind 'User' -Legacy
        if($kind -eq 'Power'){$data=[pscustomobject]@{PowerScheme=$data.PowerScheme;CreatedPowerScheme=$data.CreatedPowerScheme}}
        if($kind -eq 'Startup'){$data=[pscustomobject]@{Entries=@($data.Entries|Where-Object{$_.ApprovalHive -eq 'LocalMachine'})}}
        Assert-JunoBackupData $kind $data 'Machine'
        $hash=Get-JunoHash (Read-JunoBytes $copy)
        Confirm-JunoReview ("Recuperar evidencia historica de equipo exige revisar autor, equipo y originales. Archivo: $copy`nSHA-256: $hash`nDatos:`n"+($data|ConvertTo-Json -Depth 18)+"`n¿Autorizar esta importacion? No se aplicaran ajustes de Windows.")
        if((Get-JunoHash (Read-JunoBytes $copy)) -cne $hash){throw 'La copia cambio durante la revision.'}
        $id=Get-JunoIdentity
        $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind=$kind;Scope='Machine';Sid=$null;Machine=$id.Machine;Revision=[Guid]::NewGuid().ToString();Data=$data}
        Write-JunoNewFile $temp ([Text.UTF8Encoding]::new($false).GetBytes(($doc|ConvertTo-Json -Depth 24))) -Machine
    } else {
        [void](Read-JunoDocument $copy $kind $scope -Legacy:($scope -eq 'User'))
        [void](Copy-JunoHistory $copy $temp -Machine:($scope -eq 'Machine'))
    }
    # Conservar incluso un principal invalido, sin convertirlo en una copia valida.
    $rejected=$path+'.rejected.'+[Guid]::NewGuid().ToString('N')+'.json'
    Replace-JunoFile $temp $path $rejected
    [void](Read-JunoDocument $path $kind $scope -Legacy:($scope -eq 'User'))
    return 'Copia recuperada y validada. El estado actual de Windows aun debe conciliarse; no se aplicaron ajustes.'
}
function Confirm-JunoReview([string]$message) {
    # Un MessageBox puede recortar un respaldo grande. La revision debe ser desplazable,
    # de solo lectura y con Cancelar como opcion predeterminada, tambien al pulsar Enter.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form
    try {
        $dialog.Text='JUNO - revisar recuperacion'
        $dialog.ClientSize=New-Object Drawing.Size(860,600)
        $dialog.MinimumSize=New-Object Drawing.Size(760,500)
        $dialog.StartPosition='CenterScreen'
        $dialog.BackColor=[Drawing.Color]::FromArgb(30,31,34)
        $dialog.ForeColor=[Drawing.Color]::White
        $dialog.Padding=New-Object Windows.Forms.Padding(10)
        $text=New-Object Windows.Forms.TextBox
        $text.Multiline=$true;$text.ReadOnly=$true;$text.WordWrap=$false;$text.ScrollBars='Both';$text.Dock='Fill'
        $text.BackColor=$dialog.BackColor;$text.ForeColor=$dialog.ForeColor
        $text.Text=$message;$text.SelectionStart=0;$text.SelectionLength=0
        $buttons=New-Object Windows.Forms.FlowLayoutPanel
        $buttons.Dock='Bottom';$buttons.Height=46;$buttons.FlowDirection='RightToLeft'
        $cancel=New-Object Windows.Forms.Button
        $cancel.Text='Cancelar';$cancel.Width=120;$cancel.Height=32;$cancel.DialogResult='No'
        $accept=New-Object Windows.Forms.Button
        $accept.Text='Autorizar';$accept.Width=120;$accept.Height=32;$accept.DialogResult='Yes'
        $buttons.Controls.Add($cancel);$buttons.Controls.Add($accept)
        $dialog.Controls.Add($text);$dialog.Controls.Add($buttons)
        $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel;$dialog.ActiveControl=$cancel
        $result=$dialog.ShowDialog()
    } finally { $dialog.Dispose() }
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'Operacion pendiente: revision cancelada. Se conservan los respaldos.' }
}
function Get-JunoMachineLegacy([string]$kind) {
    $legacyKind=if($kind -eq 'Power'){'General'}else{$kind}
    $path=Get-JunoStorePath $legacyKind 'User'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $data=Read-JunoDocument $path $legacyKind 'User' -Legacy
    if ($kind -eq 'Startup') {
        $data=[pscustomobject]@{Entries=@($data.Entries | Where-Object {$_.ApprovalHive -eq 'LocalMachine'})}
        if ($data.Entries.Count -eq 0) {
            # Una escritura de usuario normal pudo separar HKCU y archivar el JSON mixto.
            # Conservar el acceso a HKLM historico hasta importarlo expresamente como administrador.
            foreach ($copy in @(Get-JunoRecoveryCandidates $path | Where-Object {$_.Name -like '*.history.*'})) {
                $old=Read-JunoDocument $copy.FullName 'Startup' 'User' -Legacy
                $records=@($old.Entries | Where-Object {$_.ApprovalHive -eq 'LocalMachine'})
                if ($records.Count -gt 0) { $path=$copy.FullName; $data=[pscustomobject]@{Entries=$records}; break }
            }
            if ($data.Entries.Count -eq 0) { return $null }
        }
    } elseif ($kind -eq 'Power') {
        if ($null -eq $data.PowerScheme) { return $null }
        $data=[pscustomobject]@{PowerScheme=$data.PowerScheme;CreatedPowerScheme=$data.CreatedPowerScheme}
    }
    Assert-JunoBackupData $kind $data 'Machine'
    return [pscustomobject]@{Path=$path;Data=$data}
}
function Import-JunoMachineLegacy([string]$kind) {
    Assert-JunoLease
    if (-not (Test-JunoAdmin)) { throw 'El respaldo de equipo requiere JUNO como administrador.' }
    $path=Get-JunoStorePath $kind 'Machine'
    if (Test-Path -LiteralPath $path) { [void](Read-JunoStore $kind 'Machine' $null); return }
    if (@(Get-JunoRecoveryCandidates $path).Count -gt 0) { throw 'Falta el respaldo de equipo principal; recuperar una copia antes de continuar.' }
    $legacy=Get-JunoMachineLegacy $kind
    if ($null -eq $legacy) { return }
    $bytes=Read-JunoBytes $legacy.Path; $hash=Get-JunoHash $bytes
    $dest = switch ($kind) {
        'Startup' {'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved (solo entradas enumeradas)'}
        'Policy' {'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy: lista Deny y DWORD general'}
        'Trim' {'Configuracion NTFS DisableDeleteNotify del equipo'}
        'Power' {'Plan de energia activo del equipo (no se eliminaran planes)'}
    }
    Confirm-JunoReview ("El respaldo historico de equipo estaba en una carpeta modificable por el usuario y no acredita autor ni equipo. Comprueba que procede de este equipo y que los valores originales son correctos. Importarlo autoriza su uso en la operacion solicitada.`n`nArchivo: $($legacy.Path)`nDestino permitido: $dest`nSHA-256: $hash`nDatos:`n"+($legacy.Data|ConvertTo-Json -Depth 16)+"`n`n¿Importar esta copia al almacen protegido? No se cambiara Windows durante la importacion.")
    if ((Get-JunoHash (Read-JunoBytes $legacy.Path)) -cne $hash) { throw 'El respaldo historico cambio durante la revision. No se importo.' }
    Initialize-JunoMachineFolder
    [void](Copy-JunoHistory $legacy.Path ($path+'.history.'+[Guid]::NewGuid().ToString('N')+'.json') -Machine)
    # La copia history recien creada es evidencia de importacion, no un principal perdido.
    # Crear mediante el mismo protocolo, sin permitir que una copia anterior se ignore.
    $id=Get-JunoIdentity
    $doc=[pscustomobject]@{Format='JUNO.Backup';Version=1;Kind=$kind;Scope='Machine';Sid=$null;Machine=$id.Machine;Revision=[Guid]::NewGuid().ToString();Data=$legacy.Data}
    $temp=$path+'.pending.'+[Guid]::NewGuid().ToString('N')+'.json'
    Write-JunoNewFile $temp ([Text.UTF8Encoding]::new($false).GetBytes(($doc|ConvertTo-Json -Depth 24))) -Machine
    [void](Read-JunoDocument $temp $kind 'Machine')
    [IO.File]::Move($temp,$path)
    [void](Read-JunoStore $kind 'Machine' $null)
}
function Copy-JunoObject($value) {
    if ($null -eq $value) { return $null }
    # Reconstruir las listas evita serializar propiedades ETS de wrappers de arrays en PS 5.1.
    if ($value -is [array]) {
        $list=New-Object 'Collections.Generic.List[object]'
        foreach ($item in $value) { $list.Add((Copy-JunoObject $item)) }
        return ,($list.ToArray())
    }
    if ($value.GetType() -eq [Management.Automation.PSCustomObject]) {
        $copy=[pscustomobject]@{}
        foreach ($p in $value.PSObject.Properties) { Add-Member -InputObject $copy NoteProperty $p.Name (Copy-JunoObject $p.Value) }
        return $copy
    }
    return ,(ConvertFrom-JunoJson (ConvertTo-Json -InputObject $value -Depth 24 -Compress))
}
function Test-JunoEqual($a,$b) {
    if ($null -eq $a -or $null -eq $b) { return ($null -eq $a -and $null -eq $b) }
    if ($a -is [array] -or $b -is [array]) {
        if ($a -isnot [array] -or $b -isnot [array] -or $a.Count -ne $b.Count) { return $false }
        for ($i=0;$i -lt $a.Count;$i++) { if (-not (Test-JunoEqual $a[$i] $b[$i])) { return $false } }
        return $true
    }
    if ($a.GetType() -eq [Management.Automation.PSCustomObject] -or $b.GetType() -eq [Management.Automation.PSCustomObject]) {
        if ($a.GetType() -ne [Management.Automation.PSCustomObject] -or $b.GetType() -ne [Management.Automation.PSCustomObject]) { return $false }
        $ap=@($a.PSObject.Properties); $bp=@($b.PSObject.Properties)
        if ($ap.Count -ne $bp.Count) { return $false }
        foreach ($p in $ap) {
            $match=@($bp | Where-Object {$_.Name -ceq $p.Name})
            if ($match.Count -ne 1 -or -not (Test-JunoEqual $p.Value $match[0].Value)) { return $false }
        }
        return $true
    }
    if (($a -is [int] -or $a -is [long]) -and ($b -is [int] -or $b -is [long])) { return ([long]$a -eq [long]$b) }
    return ($a.GetType() -eq $b.GetType() -and $a -ceq $b)
}
