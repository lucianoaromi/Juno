#requires -Version 5.1
# Funciones compartidas por ambas interfaces. Importación sin lecturas ni cambios de Windows.
. (Join-Path $PSScriptRoot 'VisualInterop.ps1')

function Get-Backup {
    $backup=Read-JunoStore 'General' 'User' ([pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null;VisualEffects=$null;VisualRegistry=$null;TransparencyBackup=$null})
    foreach ($name in @('VisualRegistry','TransparencyBackup')) {
        if ($backup.PSObject.Properties.Name -notcontains $name) { Add-Member -InputObject $backup NoteProperty $name $null }
    }
    if ($backup.PSObject.Properties.Name -notcontains 'Journal') { Add-Member -InputObject $backup NoteProperty Journal ([pscustomobject]@{Version=1;Visual=$null;Transparency=$null}) }
    return $backup
}

function Save-Backup($backup) { Write-JunoStore 'General' $backup 'User' }

function Set-RegistryVisual([string]$subkey, [string]$name, $value, [string]$kind) {
    Assert-JunoLease
    $match=@(Get-JunoVisualTargets | Where-Object { $_[0] -ceq $subkey -and $_[1] -ceq $name -and $_[2] -ceq $kind })
    if ($match.Count -ne 1) { throw 'Destino visual no permitido.' }
    Assert-JunoVisualSnapshot ([pscustomobject]@{Exists=$true;Kind=$kind;Value=[string]$value}) -Transparency:($name -eq 'EnableTransparency')
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subkey)
    if ($null -eq $key) { throw "No se pudo abrir registro HKCU\$subkey" }
    try {
        switch ($kind) {
            'DWord' { $key.SetValue($name, [int]$value, [Microsoft.Win32.RegistryValueKind]::DWord) }
            'QWord' { $key.SetValue($name, [long]$value, [Microsoft.Win32.RegistryValueKind]::QWord) }
            'Binary' { $key.SetValue($name, [Convert]::FromBase64String([string]$value), [Microsoft.Win32.RegistryValueKind]::Binary) }
            'ExpandString' { $key.SetValue($name, [string]$value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            default { $key.SetValue($name, [string]$value, [Microsoft.Win32.RegistryValueKind]::String) }
        }
    } finally { $key.Close() }
}

function Get-TransparencySnapshot {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:TransparencyKey, $false)
    try {
        if ($null -eq $key -or -not ($key.GetValueNames() -contains 'EnableTransparency')) {
            return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
        }
        $kind = $key.GetValueKind('EnableTransparency').ToString()
        $raw = $key.GetValue('EnableTransparency', $null)
        return [pscustomobject]@{ Exists = $true; Kind = $kind; Value = [string]$raw }
    } finally { if ($null -ne $key) { $key.Close() } }
}

function Get-TransparencyState {
    $snapshot = Get-TransparencySnapshot
    if (-not $snapshot.Exists) { return $null }
    return ([int]$snapshot.Value -ne 0)
}

function Notify-TransparencyChange {
    # Algunas superficies se actualizan al recibir WM_SETTINGCHANGE;
    # otras pueden necesitar cerrar y volver a iniciar sesion.
    try {
        Initialize-JunoVisualInterop
        $response = [IntPtr]::Zero
        $sent = [WinVisualEffects]::SendMessageTimeout(
            [IntPtr]0xFFFF, [uint32]0x001A, [IntPtr]::Zero,
            'ImmersiveColorSet', [uint32]0x0002, [uint32]1500, [ref]$response)
        return ($sent -ne [IntPtr]::Zero)
    } catch { return $false }
}

function Set-Transparency([bool]$enabled) { Invoke-JunoTransparency $false $enabled }

function Restore-Transparency { Invoke-JunoTransparency $true }
