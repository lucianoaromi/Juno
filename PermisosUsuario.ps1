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
        if ($state.IsOff) { continue }
        if (@($backup.Items | Where-Object { $_.Family -eq $family }).Count -gt 0) { continue }
        # Respaldo completo de DWORD originales, tambien si estaban ausentes.
        $entry = [pscustomobject]@{Family=$family; Disabled=$state.Disabled; DisabledByUser=$state.DisabledByUser}
        $backup.Items = @($backup.Items) + @($entry)
        Save-BPUBackup $backup # primero respaldo, despues escritura
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$($script:BPUPath)\$family", $true)
        if ($null -eq $key) { throw "No se pudo abrir permiso de $family para escritura." }
        try {
            $key.SetValue('Disabled', [int]1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $key.SetValue('DisabledByUser', [int]1, [Microsoft.Win32.RegistryValueKind]::DWord)
        } finally { $key.Dispose() }
        $verify = Get-BPUState $family
        if (-not $verify.Available -or -not $verify.Disabled.Exists -or $verify.Disabled.Value -ne 1 -or -not $verify.DisabledByUser.Exists -or $verify.DisabledByUser.Value -ne 1) {
            throw "No se pudo verificar la escritura de $family. El respaldo se conservo."
        }
        $added++
    }
    if ($added -eq 0) { return 'No hubo cambios: las apps ya tenian indicadores de bloqueo o estan respaldadas.' }
    return "Registro de usuario actualizado para $added app(s). Importante: Windows 11 puede ignorarlo; verifica en Ajustes si se muestra 'Nunca'."
}
function Restore-BPUApps([string[]]$families) {
    if ($families.Count -eq 0) { return 'No hay aplicaciones seleccionadas.' }
    $null = Test-BPULocalPolicy
    $backup = Get-BPUBackup
    $restored = 0
    foreach ($family in @($families | Select-Object -Unique)) {
        $entry = @($backup.Items | Where-Object { $_.Family -eq $family } | Select-Object -First 1)
        if ($entry.Count -eq 0) { continue }
        $state = Get-BPUState $family
        if (-not $state.Available) { throw "Ya no existe la clave de $family; se conserva el respaldo para revisar." }
        # Si otra aplicacion cambio los DWORD despues, evitar pisarlos.
        if (-not $state.Disabled.Exists -or $state.Disabled.Value -ne 1 -or -not $state.DisabledByUser.Exists -or $state.DisabledByUser.Value -ne 1) {
            throw "$family ha sido modificado desde el bloqueo. No se sobreescribira; revisalo en Ajustes."
        }
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$($script:BPUPath)\$family", $true)
        if ($null -eq $key) { throw "No se puede restaurar $family." }
        try {
            foreach ($name in @('Disabled','DisabledByUser')) {
                $old = $entry.$name
                if ([bool]$old.Exists) {
                    $key.SetValue($name, [int]$old.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
                } else {
                    $key.DeleteValue($name, $false)
                }
            }
        } finally { $key.Dispose() }
        $actual = Get-BPUState $family
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
