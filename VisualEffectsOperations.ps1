#requires -Version 5.1
# Fronteras visuales compartidas. Importar no consulta ni cambia Windows.
. (Join-Path $PSScriptRoot 'VisualInterop.ps1')

# Constantes oficiales de SystemParametersInfo (Windows API).
# El fondo y los ajustes de accesibilidad no se modifican.
$script:EffectCodes = [ordered]@{
    UIEffects            = @(0x103E, 0x103F)
    ClientAreaAnimation  = @(0x1042, 0x1043)
    MenuAnimation        = @(0x1002, 0x1003)
    ComboBoxAnimation    = @(0x1004, 0x1005)
    ListSmoothScrolling  = @(0x1006, 0x1007)
    MenuFade             = @(0x1012, 0x1013)
    SelectionFade        = @(0x1014, 0x1015)
    ToolTipAnimation     = @(0x1016, 0x1017)
    ToolTipFade          = @(0x1018, 0x1019)
    CursorShadow         = @(0x101A, 0x101B)
    DropShadow           = @(0x1024, 0x1025)
}


# SPI_GET...BOOL recibe un puntero; SPI_SET...BOOL recibe el BOOL por valor.
# El error de la v0.1 era pasar ref int tambien al SET: se interpretaba
# una direccion de memoria (no nula) como TRUE, dejando efectos ACTIVADOS.
function Get-EffectValue([int]$action) {
    $value = [int]0
    $success = [WinVisualEffects]::SystemParametersInfoBool([uint32]$action, 0, [ref]$value, 0)
    if (-not $success) { return $null }
    return [bool]($value -ne 0)
}
function Set-EffectValue([int]$action, [bool]$enabled) {
    $value = if ($enabled) { [IntPtr]::new(1) } else { [IntPtr]::Zero }
    return [WinVisualEffects]::SystemParametersInfoSetBool([uint32]$action, 0, $value, 3)
}
function Set-UiParamSwitch([int]$action, [bool]$enabled) {
    $value = if ($enabled) { [uint32]1 } else { [uint32]0 }
    return [WinVisualEffects]::SystemParametersInfoSetBool([uint32]$action, $value, [IntPtr]::Zero, 3)
}
function Get-MinimizeAnimation {
    $info = New-Object WinVisualEffects+ANIMATIONINFO
    $info.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type][WinVisualEffects+ANIMATIONINFO])
    $ok = [WinVisualEffects]::SystemParametersInfoAnimation([uint32]0x0048, $info.cbSize, [ref]$info, [uint32]0)
    if (-not $ok) { return $null }
    return [bool]($info.iMinAnimate -ne 0)
}
function Set-MinimizeAnimation([bool]$enabled) {
    $info = New-Object WinVisualEffects+ANIMATIONINFO
    $info.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type][WinVisualEffects+ANIMATIONINFO])
    $info.iMinAnimate = [int][bool]$enabled
    return [WinVisualEffects]::SystemParametersInfoAnimation([uint32]0x0049, $info.cbSize, [ref]$info, [uint32]3)
}
function Get-CurrentEffects {
    $values = [ordered]@{}
    foreach ($name in $script:EffectCodes.Keys) {
        $val = Get-EffectValue $script:EffectCodes[$name][0]
        if ($null -ne $val) { $values[$name] = [bool]$val }
    }
    $minAnim = Get-MinimizeAnimation
    if ($null -ne $minAnim) { $values['MinimizeAnimation'] = [bool]$minAnim }
    $font = Get-EffectValue 0x004A
    if ($null -ne $font) { $values['FontSmoothing'] = [bool]$font }
    $drag = Get-EffectValue 0x0026
    if ($null -ne $drag) { $values['DragFullWindows'] = [bool]$drag }
    return $values
}
# Valores que aparecen en las opciones de Rendimiento y que SPI no cubre.
$script:VisualRegItems = @(
    @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name='VisualFXSetting' },
    @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarAnimations' },
    @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='IconsOnly' },
    @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ListviewAlphaSelect' },
    @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ListviewShadow' },
    @{ Key='Software\Microsoft\Windows\DWM'; Name='EnableAeroPeek' },
    @{ Key='Control Panel\Desktop'; Name='DragFullWindows' },
    @{ Key='Control Panel\Desktop'; Name='FontSmoothing' },
    @{ Key='Control Panel\Desktop'; Name='UserPreferencesMask' },
    @{ Key='Control Panel\Desktop\WindowMetrics'; Name='MinAnimate' }
)
function Get-VisualRegistrySnapshot {
    $snapshot = @()
    foreach ($item in $script:VisualRegItems) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey([string]$item.Key, $false)
        try {
            $exists = $false
            $kind = $null
            $value = $null
            if ($null -ne $key -and ($key.GetValueNames() -contains $item.Name)) {
                $exists = $true
                $kind = $key.GetValueKind([string]$item.Name).ToString()
                $raw = $key.GetValue([string]$item.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($kind -eq 'Binary') { $value = [Convert]::ToBase64String([byte[]]$raw) }
                elseif ($kind -eq 'DWord' -or $kind -eq 'QWord') { $value = [string]$raw }
                else { $value = [string]$raw }
            }
            $snapshot += [pscustomobject]@{ Key=$item.Key; Name=$item.Name; Exists=$exists; Kind=$kind; Value=$value }
        } finally { if ($null -ne $key) { $key.Close() } }
    }
    return ,$snapshot
}

function Restore-VisualRegistry($snapshots) {
    Assert-JunoLease
    Assert-JunoVisualRegistry $snapshots
    foreach ($snap in $snapshots) {
        if ([bool]$snap.Exists) {
            Set-RegistryVisual ([string]$snap.Key) ([string]$snap.Name) $snap.Value ([string]$snap.Kind)
        } else {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey([string]$snap.Key, $true)
            try { if ($null -ne $key) { $key.DeleteValue([string]$snap.Name, $false) } }
            finally { if ($null -ne $key) { $key.Close() } }
        }
    }
}
function Apply-VisualEffects([bool]$keepFont) { Invoke-JunoVisual $false $keepFont }
function Restore-VisualEffects { Invoke-JunoVisual $true }
