# JUNO 0.8 - Optimizador modular para Windows 10/11
# PowerShell 5.1 (integrado en Windows). No instala servicios ni programas.
# Los cambios se aplican solo al pulsar los botones.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    [System.Windows.Forms.MessageBox]::Show('Ejecuta el archivo Abrir-Juno.cmd (inicia PowerShell en modo STA).', 'JUNO') | Out-Null
    exit 1
}

. (Join-Path $PSScriptRoot 'BackupStore.ps1')
. (Join-Path $PSScriptRoot 'RecoveryOperations.ps1')
. (Join-Path $PSScriptRoot 'PowerOperations.ps1')
. (Join-Path $PSScriptRoot 'TransparencyOperations.ps1')
. (Join-Path $PSScriptRoot 'VisualEffectsOperations.ps1')
. (Join-Path $PSScriptRoot 'BackgroundInventory.ps1')
. (Join-Path $PSScriptRoot 'UiSupport.ps1')
try { Enter-JunoLease }
catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'JUNO - recurso ocupado o inaccesible', 'OK', 'Warning')
    exit 1
}
try {
if ($script:JunoLease.Abandoned) {
    [void][System.Windows.Forms.MessageBox]::Show('La instancia anterior termino sin liberar el bloqueo. JUNO validara los respaldos antes de cualquier cambio; revisa las operaciones pendientes.', 'JUNO - sesion interrumpida', 'OK', 'Warning')
}
Initialize-JunoVisualInterop

$script:AppFolder = Join-Path $env:LOCALAPPDATA 'WinRendimiento'
$script:BackupPath = Join-Path $script:AppFolder 'backup.json'
$script:TransparencyKey = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# Transparencia y acceso al respaldo compartidos en TransparencyOperations.ps1.

# Modulo separado: no modifica las funciones anteriores.
. (Join-Path $PSScriptRoot 'Inicio.ps1')
. (Join-Path $PSScriptRoot 'Limpieza.ps1')
. (Join-Path $PSScriptRoot 'Discos.ps1')
. (Join-Path $PSScriptRoot 'SegundoPlano.ps1')
. (Join-Path $PSScriptRoot 'PermisosUsuario.ps1')
. (Join-Path $PSScriptRoot 'PermisosSegundoPlano.ps1')

# ----------------------- INTERFAZ GRAFICA -----------------------
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
# Icono cargado desde el mismo directorio (no depende de ruta absoluta).
$script:JunoIcon = $null
$script:JunoImage = $null
try {
    $iconPath = Join-Path $PSScriptRoot 'Juno.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $script:JunoIcon = New-Object System.Drawing.Icon -ArgumentList $iconPath
        $form.Icon = $script:JunoIcon
        $form.ShowIcon = $true
    }
} catch { } # La aplicación puede abrirse aun si no se carga el icono.
$form.Text = 'JUNO 0.8 | Optimizador de Windows'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(730, 690)
$form.MinimumSize = New-Object System.Drawing.Size(730, 690)
$form.MaximizeBox = $false
$form.FormBorderStyle = 'FixedSingle'
$form.BackColor = [System.Drawing.Color]::FromArgb(22, 26, 34)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [int]$size, [bool]$bold, [System.Drawing.Color]$color) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Location = New-Object System.Drawing.Point($x, $y)
    $label.Size = New-Object System.Drawing.Size($w, $h)
    $label.ForeColor = $color
    $style = [System.Drawing.FontStyle]::Regular
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
    return $label
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [System.Drawing.Color]$color) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.Location = New-Object System.Drawing.Point($x, $y)
    $button.Size = New-Object System.Drawing.Size($w, $h)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $color
    $button.ForeColor = [System.Drawing.Color]::White
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    return $button
}
function New-Panel([int]$x,[int]$y,[int]$w,[int]$h) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($x,$y)
    $panel.Size = New-Object System.Drawing.Size($w,$h)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(32,38,49)
    return $panel
}
$white = [System.Drawing.Color]::FromArgb(238, 240, 244)
$muted = [System.Drawing.Color]::FromArgb(170,180,198)
$green = [System.Drawing.Color]::FromArgb(38, 135, 96)
$blue = [System.Drawing.Color]::FromArgb(51, 101, 173)
$gray = [System.Drawing.Color]::FromArgb(67, 76, 91)

# Miniatura del icono en la cabecera; no altera los paneles existentes.
try {
    $imagePath = Join-Path $PSScriptRoot 'Juno-icono.png'
    if (Test-Path -LiteralPath $imagePath) {
        $script:JunoImage = [System.Drawing.Image]::FromFile($imagePath)
        $junoPicture = New-Object System.Windows.Forms.PictureBox
        $junoPicture.Location = New-Object System.Drawing.Point(26, 17)
        $junoPicture.Size = New-Object System.Drawing.Size(49, 49)
        $junoPicture.SizeMode = 'Zoom'
        $junoPicture.Image = $script:JunoImage
        $form.Controls.Add($junoPicture)
    }
} catch { }
$form.Controls.Add((New-Label 'JUNO' 88 12 550 39 22 $true $white))
$form.Controls.Add((New-Label 'Ajustes controlados. Desplaza para ver las siete secciones.' 88 52 615 24 10 $false $muted))

$scrollHost = New-Object System.Windows.Forms.Panel
$scrollHost.Location = New-Object System.Drawing.Point(0, 79)
$scrollHost.Size = New-Object System.Drawing.Size(730, 545)
$scrollHost.AutoScroll = $true
$form.Controls.Add($scrollHost)

# Cuatro modulos con la misma estructura: panel, titulo, detalle y botones.
# Se conserva la altura compacta para pantallas con resolucion vertical reducida.
$panelPower = New-Panel 22 6 666 116
$panelPower.Controls.Add((New-Label '1. Plan de energia' 17 7 600 28 15 $true $white))
$panelPower.Controls.Add((New-Label 'Requiere administrador. Modern Standby puede limitar los planes disponibles.' 17 37 620 25 10 $false $muted))
$btnPower = New-Button 'Activar Alto rendimiento' 17 70 282 36 $green
try {$btnPower.Enabled=Test-JunoAdmin} catch {$btnPower.Enabled=$false}
$btnPlans = New-Button 'Ver planes de energia' 317 70 330 36 $gray
$panelPower.Controls.Add($btnPower)
$panelPower.Controls.Add($btnPlans)
$scrollHost.Controls.Add($panelPower)

$panelVisual = New-Panel 22 132 666 162
$panelVisual.Controls.Add((New-Label '2. Efectos visuales' 17 7 600 28 15 $true $white))
$panelVisual.Controls.Add((New-Label 'Desactiva animaciones y efectos. Guarda la configuracion anterior.' 17 36 630 25 10 $false $muted))
$btnVisual = New-Button 'Maximo rendimiento (todo OFF)' 17 68 302 35 $blue
$btnVisualFont = New-Button 'Rendimiento + letras nitidas' 334 68 313 35 $green
$btnVisualCheck = New-Button 'Ver efectos en Windows (comprobar)' 17 115 630 35 $gray
$panelVisual.Controls.Add($btnVisual)
$panelVisual.Controls.Add($btnVisualFont)
$panelVisual.Controls.Add($btnVisualCheck)
$scrollHost.Controls.Add($panelVisual)

$panelTransparency = New-Panel 22 304 666 119
$panelTransparency.Controls.Add((New-Label '3. Transparencia de Windows' 17 7 630 27 15 $true $white))
$lblTransparency = New-Label 'Estado de transparencia: consultando...' 17 36 630 24 10 $false $muted
$panelTransparency.Controls.Add($lblTransparency)
$btnTransOff = New-Button 'Quitar transparencia' 17 74 242 35 $blue
$btnTransOn = New-Button 'Activar transparencia' 273 74 225 35 $green
$btnTransCheck = New-Button 'Ver ajuste' 512 74 135 35 $gray
$panelTransparency.Controls.Add($btnTransOff)
$panelTransparency.Controls.Add($btnTransOn)
$panelTransparency.Controls.Add($btnTransCheck)
$scrollHost.Controls.Add($panelTransparency)

# Tarjeta 4: solo gestiona programas de inicio.
# La restauracion de ajustes generales se muestra al FINAL, fuera de los modulos.
$panelTools = New-Panel 22 433 666 113
$panelTools.Controls.Add((New-Label '4. Programas de inicio' 17 7 630 28 15 $true $white))
$panelTools.Controls.Add((New-Label 'Elige que aplicaciones se inician con Windows.' 17 36 630 25 10 $false $muted))
$btnStartup = New-Button 'Administrar programas de inicio' 17 70 630 35 $blue
$panelTools.Controls.Add($btnStartup)
$scrollHost.Controls.Add($panelTools)

# Tarjeta 5: dos tareas DIFERENTES: permisos persistentes y procesos activos.
$panelBackground = New-Panel 22 556 666 163
$panelBackground.Controls.Add((New-Label '5. Aplicaciones en segundo plano' 17 7 630 28 15 $true $white))
$panelBackground.Controls.Add((New-Label 'Configura permisos futuros o revisa procesos activos. Son funciones diferentes.' 17 36 630 25 10 $false $muted))
$btnPermissions = New-Button 'Revisar permisos de segundo plano' 17 70 630 36 $green
$btnBackground = New-Button 'Ver procesos activos (RAM / CPU)' 17 115 630 36 $blue
$panelBackground.Controls.Add($btnPermissions)
$panelBackground.Controls.Add($btnBackground)
$scrollHost.Controls.Add($panelBackground)

# Tarjeta 6: solo abre el analizador, sin borrar nada al iniciar.
$panelCleanup = New-Panel 22 729 666 120
$panelCleanup.Controls.Add((New-Label '6. Limpieza inteligente' 17 7 630 28 15 $true $white))
$panelCleanup.Controls.Add((New-Label 'Consulta temporales y revisa la limpieza en Windows. JUNO no borra archivos.' 17 36 630 25 10 $false $muted))
$btnCleanup = New-Button 'Analizar temporales y revisar en Windows' 17 70 630 36 $blue
$panelCleanup.Controls.Add($btnCleanup)
$scrollHost.Controls.Add($panelCleanup)
# Tarjeta 7: diagnostico de almacenamiento (no aplica cambios al abrir).
$panelDisks = New-Panel 22 859 666 120
$panelDisks.Controls.Add((New-Label '7. Almacenamiento SSD / HDD' 17 7 630 28 15 $true $white))
$panelDisks.Controls.Add((New-Label 'Consulta salud, TRIM y mantenimiento. Optimiza solo si lo confirmas.' 17 36 630 25 10 $false $muted))
$btnDisks = New-Button 'Diagnostico y optimizacion de discos' 17 70 630 36 $blue
$panelDisks.Controls.Add($btnDisks)
$scrollHost.Controls.Add($panelDisks)
# Restauracion global de ajustes BASICOS: al final y fuera de las tarjetas numeradas.
# No afecta a los respaldos independientes de inicio, segundo plano o TRIM.
$panelRestore = New-Panel 22 989 666 145
$panelRestore.Controls.Add((New-Label 'Restauracion de ajustes generales' 17 7 630 28 15 $true $white))
$panelRestore.Controls.Add((New-Label 'Revierte solo energia, efectos visuales y transparencia guardados.' 17 36 630 24 10 $false $muted))
$panelRestore.Controls.Add((New-Label 'Inicio, segundo plano y TRIM se restauran por separado. La limpieza no se deshace.' 17 62 630 24 9 $false $muted))
$btnRestore = New-Button 'Restaurar energia, efectos y transparencia' 17 95 630 36 $gray
$panelRestore.Controls.Add($btnRestore)
$scrollHost.Controls.Add($panelRestore)
$scrollHost.AutoScrollMinSize = New-Object System.Drawing.Size(0, 1150)

$status = New-Label 'Estado: listo. Ningun cambio se aplica automaticamente.' 26 632 665 24 10 $false $white
$form.Controls.Add($status)
$form.Controls.Add((New-Label 'Respaldos: usuario en LocalAppData; equipo protegido en ProgramData. Consulta LEEME.' 26 660 680 20 9 $false $muted))

function Update-TransparencyLabel {
    try {
        $value = Get-TransparencyState
        $state = if ($null -eq $value) { 'Sin valor explicito' }
                 elseif ($value) { 'Activada' } else { 'Desactivada' }
        $lblTransparency.Text = "Estado de transparencia: $state"
    } catch {
        $lblTransparency.Text = 'Estado de transparencia: no se pudo consultar'
    }
}
Update-TransparencyLabel

function Show-Result([string]$message,[bool]$isError) {
    $status.Text = "Estado: $message"
    $status.ForeColor = if ($isError) { [System.Drawing.Color]::FromArgb(255,170,165) } else { [System.Drawing.Color]::FromArgb(157,231,190) }
    $icon = if ($isError) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [System.Windows.Forms.MessageBox]::Show($form, $message, 'JUNO', [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
}
$btnPower.Add_Click({
    try { Show-Result (Enable-HighPerformance) $false }
    catch { Show-Result ("Operacion de energia pendiente o fallida: $($_.Exception.Message)`n`nRevisa el plan activo antes de reintentar. Modern Standby puede limitar los planes disponibles.") $true }
})
$btnPlans.Add_Click({try {Start-Process (Get-JunoSystemTool 'control.exe') -ArgumentList 'powercfg.cpl'}catch {Show-Result $_.Exception.Message $true}})
$btnVisual.Add_Click({
    try { Show-Result (Apply-VisualEffects $false) $false }
    catch { Show-Result ("Ajuste visual pendiente o fallido: $($_.Exception.Message)") $true }
})
$btnVisualFont.Add_Click({
    try { Show-Result (Apply-VisualEffects $true) $false }
    catch { Show-Result ("Ajuste visual pendiente o fallido: $($_.Exception.Message)") $true }
})
$btnVisualCheck.Add_Click({try {Start-Process (Get-JunoSystemTool 'SystemPropertiesPerformance.exe')}catch {Show-Result $_.Exception.Message $true}})
$btnTransOff.Add_Click({
    try { Show-Result (Set-Transparency $false) $false }
    catch { Show-Result ("Transparencia pendiente o fallida: $($_.Exception.Message)") $true }
    finally { Update-TransparencyLabel }
})
$btnTransOn.Add_Click({
    try { Show-Result (Set-Transparency $true) $false }
    catch { Show-Result ("Transparencia pendiente o fallida: $($_.Exception.Message)") $true }
    finally { Update-TransparencyLabel }
})
$btnTransCheck.Add_Click({
    try { Start-Process 'ms-settings:colors' }
    catch { Show-Result "No se pudo abrir Configuracion: $($_.Exception.Message)" $true }
})
$btnStartup.Add_Click({
    try { Show-StartupManager $form }
    catch { Show-Result ("Error al abrir administrador de inicio: $($_.Exception.Message)") $true }
})
$btnCleanup.Add_Click({
    try { Show-CleanupManager $form }
    catch { Show-Result ("Error al abrir limpieza: $($_.Exception.Message)") $true }
})
$btnDisks.Add_Click({
    try { Show-DiskManager $form }
    catch { Show-Result ("Error al abrir diagnostico de discos: $($_.Exception.Message)") $true }
})
$btnPermissions.Add_Click({
    try { Show-BackgroundPermissions $form }
    catch { Show-Result ("Error al abrir permisos en segundo plano: $($_.Exception.Message)") $true }
})
$btnBackground.Add_Click({
    try { Show-BackgroundManager $form }
    catch { Show-Result ("Error al abrir segundo plano: $($_.Exception.Message)") $true }
})
$btnRestore.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show($form,
        "¿Restaurar las configuraciones guardadas de energia, efectos visuales y transparencia?`n`nNo modifica el inicio, los permisos en segundo plano ni TRIM. La limpieza de archivos no es reversible.",
        'Confirmar restauracion',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $results = @()
    $hadErrors = $false
    try { $results += (Restore-VisualEffects) }
    catch { $hadErrors = $true; $results += "Efectos: $($_.Exception.Message)" }
    try { $results += (Restore-Transparency) }
    catch { $hadErrors = $true; $results += "Transparencia: $($_.Exception.Message)" }
    try { $results += (Restore-PowerPlan) }
    catch { $hadErrors = $true; $results += "Energia: $($_.Exception.Message)" }
    Update-TransparencyLabel
    if($hadErrors){$results=@('Restauracion parcial o pendiente. Revisa cada resultado y conserva los respaldos.')+$results}
    Show-Result ($results -join "`n") $hadErrors
})
Initialize-JunoWindow $form
try { [void][System.Windows.Forms.Application]::Run($form) }
finally {
    $form.Dispose()
    if ($null -ne $script:JunoImage) { $script:JunoImage.Dispose() }
    if ($null -ne $script:JunoIcon) { $script:JunoIcon.Dispose() }
}

} finally { Exit-JunoLease }
