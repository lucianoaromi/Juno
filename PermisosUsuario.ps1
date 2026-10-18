# JUNO 0.7.2 - Permisos de segundo plano DEL USUARIO ACTUAL.
# Este metodo de Registro reproduce los indicadores usados en Windows 10.
# Windows 11 NO garantiza que estos DWORD equivalgan a la opcion 'Nunca'.
# SOLO modificar subclaves EXISTENTES de apps opcionales. No tocar HKLM.
$script:BPUPath = 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
$script:BPUBackupPath = Join-Path $script:AppFolder 'background-user.json'

function Get-BPUAccount {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
function Get-BPUGlobal {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:BPUPath, $false)
    try {
        if ($null -eq $key) { return $null }
        if ($key.GetValueNames() -notcontains 'GlobalUserDisabled') { return $null }
        if ($key.GetValueKind('GlobalUserDisabled') -ne [Microsoft.Win32.RegistryValueKind]::DWord) { return $null }
        return [int]$key.GetValue('GlobalUserDisabled')
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Get-BPUValue([Microsoft.Win32.RegistryKey]$key,[string]$name) {
    if ($key.GetValueNames() -notcontains $name) { return [pscustomobject]@{Exists=$false; Value=$null} }
    if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
        throw "El valor '$name' es de otro tipo. No se cambiara."
    }
    return [pscustomobject]@{Exists=$true; Value=[int]$key.GetValue($name)}
}
function Get-BPUState([string]$family) {
    # Los PFN se obtienen de Get-AppxPackage; no aceptar rutas arbitrarias.
    if ($family -notmatch '^[A-Za-z0-9._-]+$') { return [pscustomobject]@{Available=$false} }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$($script:BPUPath)\$family", $false)
    if ($null -eq $key) { return [pscustomobject]@{Available=$false} }
    try {
        $one = Get-BPUValue $key 'Disabled'
        $two = Get-BPUValue $key 'DisabledByUser'
        $isOff = ($one.Exists -and $one.Value -eq 1) -or ($two.Exists -and $two.Value -eq 1)
        return [pscustomobject]@{Available=$true; Disabled=$one; DisabledByUser=$two; IsOff=$isOff}
    } finally { $key.Dispose() }
}
function Get-BPUBackup {
    $sid = Get-BPUAccount
    if (-not (Test-Path -LiteralPath $script:BPUBackupPath)) {
        return [pscustomobject]@{Version=1; Sid=$sid; Items=@()}
    }
    $obj = Get-Content -LiteralPath $script:BPUBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $obj -or $obj.Version -ne 1 -or [string]$obj.Sid -ne $sid -or -not ($obj.PSObject.Properties.Name -contains 'Items')) {
        throw 'El respaldo de permisos no pertenece a este usuario o esta dañado. No se modificara nada.'
    }
    return $obj
}
function Save-BPUBackup($backup) {
    if (-not (Test-Path -LiteralPath $script:AppFolder)) {
        New-Item -Path $script:AppFolder -ItemType Directory -Force | Out-Null
    }
    $tmp = "$($script:BPUBackupPath).tmp"
    try {
        $backup | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:BPUBackupPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
function Test-BPULocalPolicy {
    $envInfo = Get-BPPEnvironment
    if ($envInfo.Domain) { throw 'Equipo gestionado o dominio desconocido: no se cambian permisos.' }
    $policy = Get-BPPPolicy
    if ($policy.HasGlobal -and $policy.Global -ne 0) {
        throw 'Ya existe una directiva de segundo plano que prevalece sobre ajustes de usuario.'
    }
    return $policy
}
function Test-BPUValueSnapshot($actual, $expected) {
    return ([bool]$actual.Exists -eq [bool]$expected.Exists -and
        (-not $actual.Exists -or [int]$actual.Value -eq [int]$expected.Value))
}
function Initialize-BPUTransaction($entry) {
    if ($entry.PSObject.Properties.Name -contains 'Transaction') {
        if ($null -eq $entry.Transaction -or $entry.Transaction.Version -ne 1 -or
            $entry.Transaction.Phase -notin @('Applying','Applied','Restoring')) {
            throw 'Registro de recuperacion de permisos incompatible; se conserva el respaldo.'
        }
        return
    }
    # Los respaldos v1 anteriores no distinguen una escritura parcial.
    # Para cada DWORD solo se admite el original o el destino conocido (1).
    $transaction = [pscustomobject]@{ Version=1; Phase='Applying' }
    foreach ($name in @('Disabled','DisabledByUser')) {
        $old = $entry.$name
        $value = [pscustomobject]@{
            Confirmed=[pscustomobject]@{ Exists=[bool]$old.Exists; Value=$old.Value }
            Pending=[pscustomobject]@{ Exists=$true; Value=1 }
        }
        Add-Member -InputObject $transaction -MemberType NoteProperty -Name $name -Value $value
    }
    Add-Member -InputObject $entry -MemberType NoteProperty -Name Transaction -Value $transaction
}
function Test-BPUApplyPending($entry) {
    if ($entry.PSObject.Properties.Name -notcontains 'Transaction') { return $true }
    return ($entry.Transaction.Phase -eq 'Applying')
}
function Sync-BPUTransaction($entry, $state) {
    if (-not $state.Available) { throw "Ya no existe la clave de $($entry.Family); se conserva el respaldo." }
    # Comprobar AMBOS valores antes de confirmar cualquiera o escribir.
    foreach ($name in @('Disabled','DisabledByUser')) {
        $step = $entry.Transaction.$name
        if (-not (Test-BPUValueSnapshot $state.$name $step.Confirmed) -and
            ($null -eq $step.Pending -or -not (Test-BPUValueSnapshot $state.$name $step.Pending))) {
            throw "$($entry.Family): $name cambio fuera de JUNO. No se sobrescribira."
        }
    }
    foreach ($name in @('Disabled','DisabledByUser')) {
        $step = $entry.Transaction.$name
        if ($null -ne $step.Pending -and (Test-BPUValueSnapshot $state.$name $step.Pending)) {
            $step.Confirmed = [pscustomobject]@{ Exists=[bool]$state.$name.Exists; Value=$state.$name.Value }
        }
        $step.Pending = $null
    }
}
function Open-BPUWriteKey([string]$family) {
    if ($family -notmatch '^[A-Za-z0-9._-]+$') { throw 'Identificador de paquete no valido.' }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$($script:BPUPath)\$family", $true)
}
function Set-BPURegistryValue([string]$family, [string]$name, $target) {
    if ($name -notin @('Disabled','DisabledByUser')) { throw 'Valor de permiso no permitido.' }
    $key = Open-BPUWriteKey $family
    if ($null -eq $key) { throw "No se puede abrir permiso de $family para escritura." }
    try {
        if ($target.Exists) {
            $key.SetValue($name, [int]$target.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        } else { $key.DeleteValue($name, $false) }
    } finally { $key.Dispose() }
}
function Write-BPUTransactionValue($backup, $entry, [string]$name, $target) {
    $state = Get-BPUState $entry.Family
    Sync-BPUTransaction $entry $state
    if (Test-BPUValueSnapshot $state.$name $target) { return }
    $step = $entry.Transaction.$name
    $step.Pending = [pscustomobject]@{ Exists=[bool]$target.Exists; Value=$target.Value }
    Save-BPUBackup $backup
    $before = Get-BPUState $entry.Family
    if (-not $before.Available) { throw 'La clave de permisos desaparecio antes de escribir.' }
    foreach ($field in @('Disabled','DisabledByUser')) {
        if (-not (Test-BPUValueSnapshot $before.$field $entry.Transaction.$field.Confirmed)) {
            throw "$($entry.Family): $field cambio antes de escribir. Se conserva la operacion pendiente."
        }
    }
    Set-BPURegistryValue $entry.Family $name $target
    $after = Get-BPUState $entry.Family
    if (-not $after.Available -or -not (Test-BPUValueSnapshot $after.$name $target)) {
        throw "No se pudo verificar $name de $($entry.Family). Se conserva la operacion pendiente."
    }
    $step.Confirmed = [pscustomobject]@{ Exists=[bool]$after.$name.Exists; Value=$after.$name.Value }
    $step.Pending = $null
    Save-BPUBackup $backup
}
function Disable-BPUApps([string[]]$families) {
    if ($families.Count -eq 0) { return 'No hay aplicaciones seleccionadas.' }
    $null = Test-BPULocalPolicy
    $apps = @(Get-BPPPackages | ForEach-Object {$_.Family})
    $backup = Get-BPUBackup
    $added = 0
    foreach ($family in @($families | Select-Object -Unique)) {
        if ($apps -notcontains $family) { throw "App no permitida: $family" }
        $state = Get-BPUState $family
        if (-not $state.Available) { throw "Sin permiso individual registrado por Windows: $family. Usa Ajustes." }
        $saved = @($backup.Items | Where-Object { $_.Family -eq $family } | Select-Object -First 1)
        if ($saved.Count -eq 0) {
            if ($state.IsOff) { continue } # No apropiarse de un bloqueo previo.
            $entry = [pscustomobject]@{Family=$family; Disabled=$state.Disabled; DisabledByUser=$state.DisabledByUser}
            $backup.Items = @($backup.Items) + @($entry)
            Initialize-BPUTransaction $entry
            # Registro nuevo: aun no se intento ninguna escritura.
            $entry.Transaction.Disabled.Pending = $null
            $entry.Transaction.DisabledByUser.Pending = $null
        } else { $entry = $saved[0]; Initialize-BPUTransaction $entry }
        Sync-BPUTransaction $entry $state
        if ($entry.Transaction.Phase -eq 'Restoring') { throw "$family tiene una restauracion pendiente; completala antes de bloquear." }
        $target = [pscustomobject]@{Exists=$true; Value=1}
        if ($entry.Transaction.Phase -eq 'Applied') { continue }
        $entry.Transaction.Phase = 'Applying'
        Save-BPUBackup $backup
        foreach ($name in @('Disabled','DisabledByUser')) {
            Write-BPUTransactionValue $backup $entry $name $target
        }
        $verify = Get-BPUState $family
        Sync-BPUTransaction $entry $verify
        if (-not $verify.Available -or -not $verify.Disabled.Exists -or $verify.Disabled.Value -ne 1 -or -not $verify.DisabledByUser.Exists -or $verify.DisabledByUser.Value -ne 1) {
            throw "No se pudo verificar la escritura de $family. El respaldo se conservo."
        }
        $entry.Transaction.Phase = 'Applied'
        Save-BPUBackup $backup
        $added++
    }
    if ($added -eq 0) { return 'No hubo cambios: los valores de bloqueo ya estaban registrados.' }
    return "Registro de usuario actualizado para $added app(s). Importante: Windows 11 puede ignorarlo; verifica en Ajustes si se muestra 'Nunca'."
}
function Restore-BPUApps([string[]]$families) {
    if ($families.Count -eq 0) { return 'No hay aplicaciones seleccionadas.' }
    $null = Test-BPULocalPolicy
    $backup = Get-BPUBackup
    $restored = 0
    foreach ($family in @($families | Select-Object -Unique)) {
        $saved = @($backup.Items | Where-Object { $_.Family -eq $family } | Select-Object -First 1)
        if ($saved.Count -eq 0) { continue }
        $entry = $saved[0]
        $state = Get-BPUState $family
        Initialize-BPUTransaction $entry
        Sync-BPUTransaction $entry $state
        $entry.Transaction.Phase = 'Restoring'
        Save-BPUBackup $backup
        foreach ($name in @('Disabled','DisabledByUser')) {
            Write-BPUTransactionValue $backup $entry $name $entry.$name
        }
        $actual = Get-BPUState $family
        Sync-BPUTransaction $entry $actual
        foreach ($name in @('Disabled','DisabledByUser')) {
            $expected = $entry.$name; $got = $actual.$name
            if ([bool]$expected.Exists -ne [bool]$got.Exists -or ([bool]$expected.Exists -and [int]$expected.Value -ne [int]$got.Value)) {
                throw "No se pudo verificar la restauracion de $family; se conservo su respaldo."
            }
        }
        $backup.Items = @($backup.Items | Where-Object { $_.Family -ne $family })
        Save-BPUBackup $backup
        $restored++
    }
    return "Valores originales restaurados: $restored aplicacion(es). Verifica en Ajustes el permiso real."
}
