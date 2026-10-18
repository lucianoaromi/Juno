# JUNO v0.6.2 - Diagnostico y mantenimiento de almacenamiento.
# Requiere Windows 10/11, PowerShell 5.1 y cmdlets de Storage cuando esten disponibles.
# IMPORTANTE: ninguna tarea se inicia automaticamente. Nunca fuerza desfragmentacion de SSD.

$script:DiskTrimBackupPath = Join-Path $script:AppFolder 'trim-backup.json'
$script:DiskDialog = $null
$script:DiskGrid = $null
$script:DiskDetails = $null
$script:DiskStatus = $null
$script:DiskTrimLabel = $null
$script:DiskTaskLabel = $null
$script:DiskOptimizeButton = $null
$script:DiskEnableTrimButton = $null
$script:DiskRestoreTrimButton = $null
$script:DiskProcess = $null
$script:DiskOutputTask = $null
$script:DiskErrorTask = $null
$script:DiskTimer = $null
$script:DiskLog = $null
$script:DiskErrLog = $null
$script:DiskTrimStatus = $null
$script:DiskIsAdmin = $false

function Test-DiskIsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {$principal = New-Object Security.Principal.WindowsPrincipal($identity);return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
        finally {$identity.Dispose()}
    } catch { return $false }
}
function Format-DiskBytes([double]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:N1} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    return ('{0:N0} B' -f $bytes)
}
function Get-DiskReliability($disk) {
    if ($null -eq $disk -or -not (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Temperature=$null; Wear=$null; Hours=$null; Uncorrected=$null }
    }
    try {
        $data = Get-StorageReliabilityCounter -Disk $disk -ErrorAction Stop
        if ($null -eq $data) { throw 'No hay datos SMART disponibles.' }
        return [pscustomobject]@{
            Temperature=$data.Temperature
            Wear=$data.Wear
            Hours=$data.PowerOnHours
            Uncorrected=$data.ReadErrorsUncorrected
        }
    } catch {
        return [pscustomobject]@{ Temperature=$null; Wear=$null; Hours=$null; Uncorrected=$null }
    }
}
function Get-DiskMedium($disk, $physicalDisks) {
    # Los numeros de Get-Disk y Get-PhysicalDisk no siempre coinciden.
    # Solo asociar por serial o nombre UNICO, nunca por posicion en el listado.
    if ($null -eq $disk) { return 'No detectado' }
    $candidates = @()
    $serial = [string]$disk.SerialNumber
    if (-not [string]::IsNullOrWhiteSpace($serial)) {
        $candidates = @($physicalDisks | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.SerialNumber) -and
            ([string]$_.SerialNumber).Trim() -eq $serial.Trim()
        })
    }
    if ($candidates.Count -ne 1) {
        $candidates = @($physicalDisks | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.FriendlyName) -and
            ([string]$_.FriendlyName).Trim() -eq ([string]$disk.FriendlyName).Trim()
        })
    }
    if ($candidates.Count -ne 1) { return 'No detectado' }
    switch ([string]$candidates[0].MediaType) {
        'SSD' { return 'SSD' }
        'HDD' { return 'HDD' }
        'SCM' { return 'SCM' }
        default { return 'No detectado' }
    }
}
function Get-DiskVolumes {
    $disks = @()
    $physical = @()
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $physical = @() }
    }
    $logical = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
        Where-Object { $_.DeviceID -match '^[A-Z]:$' } | Sort-Object DeviceID)
    foreach ($volume in $logical) {
        $letter = [string]$volume.DeviceID.Substring(0,1).ToUpperInvariant()
        $disk = $null
        $diskNumber = $null
        $model = 'No disponible'
        $bus = 'Desconocido'
        $health = 'Sin datos'
        $medium = 'No detectado'
        try {
            $parts = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
            if ($parts.Count -eq 1) {
                $diskNumber = [int]$parts[0].DiskNumber
                $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
                if ($disk) {
                    if ($disk.FriendlyName) { $model = [string]$disk.FriendlyName }
                    if ($disk.BusType) { $bus = [string]$disk.BusType }
                    if ($disk.HealthStatus) { $health = [string]$disk.HealthStatus }
                    $medium = Get-DiskMedium $disk $physical
                }
            }
        } catch { # Pueden faltar permisos o tratarse de una unidad virtual.
        }
        # Los contadores se consultan SOLO para la unidad seleccionada, no al listar.
        $disks += [pscustomobject]@{
            Letter=$letter; Label=[string]$volume.VolumeName;
            FileSystem=[string]$volume.FileSystem;
            Size=[double]$volume.Size; Free=[double]$volume.FreeSpace;
            DiskNumber=$diskNumber; Model=$model; Bus=$bus;
            Media=$medium; Health=$health
        }
    }
    return $disks
}
function Get-DiskTrimState {
    # Configuracion GLOBAL de Windows: NO indica que el SSD soporte fisicamente TRIM.
    try {
        $fsutil = Get-JunoSystemTool 'fsutil.exe'
        $output = (& $fsutil behavior query DisableDeleteNotify 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar fsutil.' }
        $m = [regex]::Match($output, '(?im)^\s*NTFS\s+DisableDeleteNotify\s*=\s*([01])\b')
        if (-not $m.Success) { return [pscustomobject]@{ State=$null; Text='TRIM NTFS: no se pudo interpretar (ver fsutil)' } }
        $state = [int]$m.Groups[1].Value
        $message = if ($state -eq 0) { 'TRIM NTFS: permitido en Windows (0)' } else { 'TRIM NTFS: deshabilitado en Windows (1)' }
        return [pscustomobject]@{ State=$state; Text=$message }
    } catch {
        return [pscustomobject]@{ State=$null; Text='TRIM NTFS: no se pudo consultar (permisos o compatibilidad)' }
    }
}
function Get-DiskScheduleState {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return 'Mantenimiento programado: sin datos.'
    }
    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        $enabled = if ([string]$task.State -eq 'Disabled') { 'Deshabilitado' } else { "Estado: $($task.State)" }
        $history = ''
        try {
            $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
            if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
                $history = (' | Ultima ejecucion de tarea: {0:dd/MM/yyyy HH:mm}' -f $info.LastRunTime)
            }
        } catch { }
        return "Mantenimiento programado: $enabled$history"
    } catch { return 'Mantenimiento programado: no disponible (consultar Windows).' }
}
function Get-DiskSelectedVolume {
    if ($null -eq $script:DiskGrid -or $script:DiskGrid.SelectedRows.Count -lt 1) { return $null }
    return $script:DiskGrid.SelectedRows[0].Tag
}
function Update-DiskDetails {
    if ($null -eq $script:DiskDialog) { return }
    $item = Get-DiskSelectedVolume
    $script:DiskOptimizeButton.Enabled = ($null -ne $item -and $item.Health -in @('Healthy','Sin datos') -and $script:DiskIsAdmin -and $null -eq $script:DiskProcess)
    $backupExists = $false
    if ($script:DiskIsAdmin) {
        $backupExists = (Test-Path -LiteralPath $script:DiskTrimBackupPath) -or (Test-Path -LiteralPath (Get-JunoStorePath 'Trim' 'Machine'))
    }
    $script:DiskRestoreTrimButton.Enabled = ($script:DiskIsAdmin -and $backupExists -and $null -eq $script:DiskProcess)
    $script:DiskEnableTrimButton.Enabled = ($null -ne $item -and $item.Media -eq 'SSD' -and
        $item.FileSystem -eq 'NTFS' -and $null -ne $script:DiskTrimStatus -and
        $script:DiskTrimStatus.State -eq 1 -and
        $script:DiskIsAdmin -and $null -eq $script:DiskProcess)
    if ($null -eq $item) {
        $script:DiskDetails.Text='Selecciona una unidad para ver su diagnostico.'
        return
    }
    $text = @(
        "Unidad: $($item.Letter):  $($item.Label)",
        "Capacidad: $(Format-DiskBytes $item.Size)   |   Libre: $(Format-DiskBytes $item.Free)",
        "Sistema de archivos: $($item.FileSystem)",
        "Medio detectado: $($item.Media)   |   Bus: $($item.Bus)",
        "Modelo: $($item.Model)",
        "Estado del disco informado por Windows: $($item.Health)"
    )
    if ($null -ne $item.DiskNumber) {
        try {
            $rawDisk = Get-Disk -Number $item.DiskNumber -ErrorAction Stop
            $rel = Get-DiskReliability $rawDisk
            if ($null -ne $rel.Temperature -and [int]$rel.Temperature -gt 0) {
                $text += "Temperatura reportada: $($rel.Temperature) C"
            }
            if ($null -ne $rel.Wear) { $text += "Desgaste reportado por controlador: $($rel.Wear) (sin interpretar)" }
            if ($null -ne $rel.Uncorrected -and [int64]$rel.Uncorrected -gt 0) {
                $text += "ATENCION: errores de lectura no corregidos: $($rel.Uncorrected)"
            }
        } catch { }
    }
    $text += ''
    $text += 'Estado correcto no garantiza salud SMART ni reemplaza un respaldo.'
    $text += 'Optimizar utiliza defrag /O: Windows elige el metodo segun la unidad.'
    $script:DiskDetails.Text = ($text -join [Environment]::NewLine)
}
function Refresh-DiskManager {
    if ($null -eq $script:DiskDialog) { return }
    $script:DiskGrid.Rows.Clear()
    $script:DiskTrimStatus = Get-DiskTrimState
    $volumes = @(Get-DiskVolumes)
    foreach ($item in $volumes) {
        $label = if ($item.Label) { $item.Label } else { '(sin etiqueta)' }
        $idx = $script:DiskGrid.Rows.Add("$($item.Letter):", $label, $item.Media,
             (Format-DiskBytes $item.Size), (Format-DiskBytes $item.Free), $item.Health)
        $script:DiskGrid.Rows[$idx].Tag = $item
    }
    $script:DiskTrimLabel.Text = $script:DiskTrimStatus.Text + ' (es un ajuste global, no una prueba del SSD)'
    $script:DiskTaskLabel.Text = Get-DiskScheduleState
    if ($script:DiskGrid.Rows.Count -gt 0) {
        $script:DiskGrid.Rows[0].Selected = $true
        $script:DiskGrid.CurrentCell = $script:DiskGrid.Rows[0].Cells[0]
    }
    Update-DiskDetails
    $script:DiskStatus.Text = 'Diagnostico terminado. No se realizo ningun cambio.'
}
function Enable-DiskTrim {
    Assert-JunoLease
    $item=Get-DiskSelectedVolume
    if (-not $item -or $item.Media -ne 'SSD' -or $item.FileSystem -ne 'NTFS') { throw 'Selecciona un SSD NTFS identificado para esta operacion.' }
    if (-not (Test-JunoAdmin)) { throw 'Ejecuta JUNO como administrador.' }
    $confirm=[System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
        'Esto permite notificaciones TRIM/UNMAP de NTFS para todo el sistema. Comprueba la compatibilidad del SSD y controlador. ¿Continuar?',
        'Confirmar cambio global','YesNo','Warning','Button2')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $message=Invoke-JunoTrim $false
    Refresh-DiskManager
    [void][System.Windows.Forms.MessageBox]::Show($script:DiskDialog,$message,'JUNO','OK','Information')
}
function Restore-DiskTrim {
    Assert-JunoLease
    if (-not (Test-JunoAdmin)) { throw 'Ejecuta JUNO como administrador.' }
    $confirm=[System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
        '¿Restaurar el valor anterior? Puede deshabilitar TRIM NTFS para todo el sistema. Se comprobara el respaldo antes de aplicar cambios.',
        'Revertir TRIM del sistema','YesNo','Warning','Button2')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $message=Invoke-JunoTrim $true
    Refresh-DiskManager
    [void][System.Windows.Forms.MessageBox]::Show($script:DiskDialog,$message,'JUNO','OK','Information')
}
function Start-DiskOptimize {
    $item = Get-DiskSelectedVolume
    if (-not $item) { throw 'Selecciona una unidad.' }
    if (-not $script:DiskIsAdmin) { throw 'Ejecuta JUNO como administrador para optimizar.' }
    if ($null -ne $script:DiskProcess) { throw 'Ya se esta ejecutando una optimizacion.' }
    # Solo letras de unidades locales, no puntos de montaje, rutas ni comandos arbitrarios.
    if ($item.Letter -cnotmatch '^[A-Z]$') { throw 'Letra de unidad no valida.' }
    if ($item.Health -notin @('Healthy', 'Sin datos')) {
        throw 'Windows informa un estado de salud no saludable. Hace falta diagnosticarlo y respaldar datos antes de optimizar.'
    }
    $exe = Get-JunoSystemTool 'defrag.exe'
    $confirm = [System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
        "¿Optimizar $($item.Letter):? Windows elegira automaticamente la operacion adecuada para el medio mediante defrag /O. Puede tardar y consumir recursos. No es necesario hacerlo si el mantenimiento programado funciona.",
        'Confirmar mantenimiento manual', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $dir = Join-Path $script:AppFolder 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $script:DiskLog = Join-Path $dir "defrag-$($item.Letter)-$id.txt"
    $script:DiskErrLog = Join-Path $dir "defrag-$($item.Letter)-$id-error.txt"
    # Start-Process -PassThru puede perder el codigo de salida en PowerShell 5.1.
    # Mantener un objeto .NET Process propio garantiza acceso a ExitCode al terminar.
    # Leer AMBOS flujos en paralelo evita el bloqueo cuando defrag escribe mucha salida.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exe
    # La letra ya fue validada; no se interpola ninguna ruta suministrada por el usuario.
    $startInfo.Arguments = "$($item.Letter): /O /U /V"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # defrag.exe puede escribir en la pagina de codigos OEM del sistema.
    $oemPage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding($oemPage)
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding($oemPage)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Windows no inicio defrag.exe.' }
        $script:DiskProcess = $process
        $script:DiskOutputTask = $process.StandardOutput.ReadToEndAsync()
        $script:DiskErrorTask = $process.StandardError.ReadToEndAsync()
    } catch {
        # Si alcanzo a iniciarse, retenerlo y esperar a que termine antes de cerrar.
        if ($null -ne $script:DiskProcess) {
            $script:DiskTimer.Start()
        } else {
            $process.Dispose()
        }
        throw
    }
    $script:DiskStatus.Text = "Optimizando $($item.Letter): con defrag /O... espera a que finalice."
    Update-DiskDetails
    $script:DiskTimer.Start()
}
function Get-DiskOptimizeLogResult {
    # defrag.exe usa a menudo la pagina de codigos OEM al redirigir su salida.
    # Leerla y convertirla a UTF-8 con BOM evita acentos ilegibles en Bloc de notas.
    $result = [pscustomobject]@{ Success=$false; Message='' }
    if (-not (Test-Path -LiteralPath $script:DiskLog)) { return $result }
    try {
        $raw = [System.IO.File]::ReadAllBytes($script:DiskLog)
        if ($raw.Length -eq 0) { return $result }
        if ($raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191) {
            $encoding = [System.Text.UTF8Encoding]::new($true)
        } elseif ($raw.Length -ge 2 -and $raw[0] -eq 255 -and $raw[1] -eq 254) {
            $encoding = [System.Text.Encoding]::Unicode
        } else {
            # Si los bytes ya son UTF-8 valido, respetarlos; sino usar OEM de Windows.
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            try { [void]$encoding.GetString($raw) }
            catch {
                $encoding = [System.Text.Encoding]::GetEncoding(
                    [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
            }
        }
        $contents = $encoding.GetString($raw)
        # Solo respaldar la conversion cuando la lectura fue exitosa.
        [System.IO.File]::WriteAllText($script:DiskLog, $contents, ([System.Text.UTF8Encoding]::new($true)))
        $result.Success = [regex]::IsMatch($contents,
            '(?im)(?:La operaci.n se complet. correctamente|The operation completed successfully)')
        $result.Message = $contents
    } catch { # El resultado de la operacion no debe depender de poder reescribir el registro.
        $result.Message = "No se pudo leer el registro: $($_.Exception.Message)"
    }
    return $result
}
function Stop-DiskOptimizeIfFinished {
    if ($null -eq $script:DiskProcess) { return }
    if (-not $script:DiskProcess.HasExited) { return }
    $script:DiskTimer.Stop()
    # El proceso se creo con System.Diagnostics.Process (no Start-Process), de modo
    # que ExitCode se lee del mismo objeto .NET al que esperamos con WaitForExit.
    $code = $null
    $stdOut = ''
    $stdErr = ''
    $captureProblems = @()
    try {
        $script:DiskProcess.WaitForExit()
        $code = [int]$script:DiskProcess.ExitCode
    } catch {
        $captureProblems += "Codigo de salida: $($_.Exception.Message)"
    }
    try {
        if ($null -ne $script:DiskOutputTask) {
            $stdOut = [string]$script:DiskOutputTask.GetAwaiter().GetResult()
        }
    } catch {
        $captureProblems += "Salida estandar: $($_.Exception.Message)"
    }
    try {
        if ($null -ne $script:DiskErrorTask) {
            $stdErr = [string]$script:DiskErrorTask.GetAwaiter().GetResult()
        }
    } catch {
        $captureProblems += "Salida de errores: $($_.Exception.Message)"
    }
    $script:DiskProcess.Dispose()
    $script:DiskProcess = $null
    $script:DiskOutputTask = $null
    $script:DiskErrorTask = $null
    # Los registros se escriben en UTF-8 para que Bloc de notas lea los acentos.
    $utf8 = [System.Text.UTF8Encoding]::new($true)
    try {
        [System.IO.File]::WriteAllText($script:DiskLog, $stdOut, $utf8)
        [System.IO.File]::WriteAllText($script:DiskErrLog, $stdErr, $utf8)
    } catch {
        $captureProblems += "No se pudieron guardar todos los registros: $($_.Exception.Message)"
    }
    $logResult = Get-DiskOptimizeLogResult
    if ($captureProblems.Count -gt 0) {
        try {
            [System.IO.File]::AppendAllText($script:DiskErrLog,
                ([Environment]::NewLine + ($captureProblems -join [Environment]::NewLine)), $utf8)
        } catch { }
    }
    Update-DiskDetails
    if ($null -ne $code -and $code -eq 0) {
        $script:DiskStatus.Text = 'Optimizacion finalizada. defrag.exe devolvio codigo 0.'
        [System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
            "Optimizacion finalizada: defrag.exe devolvio codigo de salida 0.`n`nRegistro: $($script:DiskLog)",
            'Mantenimiento finalizado', 'OK', 'Information') | Out-Null
    } elseif ($null -eq $code -and $logResult.Success) {
        # No informar un error inexistente cuando el propio defrag confirma exito.
        $script:DiskStatus.Text = 'Windows confirmo la optimizacion en el registro. Codigo no disponible.'
        [System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
            "La salida de Windows confirma que la operacion se completo correctamente.`n`nNo se pudo obtener el codigo de salida, pero el registro confirma el exito.`n`nRegistro: $($script:DiskLog)",
            'Mantenimiento finalizado', 'OK', 'Information') | Out-Null
    } else {
        $description = if ($null -eq $code) { 'codigo no disponible' } else { "codigo $code" }
        $script:DiskStatus.Text = "No se pudo confirmar el resultado ($description). Revisa los registros."
        [System.Windows.Forms.MessageBox]::Show($script:DiskDialog,
            "No se pudo confirmar una optimizacion exitosa ($description).`n`nRegistro: $($script:DiskLog)`nErrores: $($script:DiskErrLog)",
            'Revisar mantenimiento', 'OK', 'Warning') | Out-Null
    }
}
function Show-DiskManager([System.Windows.Forms.Form]$parent) {
    if ($null -ne $script:DiskDialog) { return }
    $script:DiskIsAdmin = Test-DiskIsAdmin
    $dlg = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dlg.Icon = $script:JunoIcon }
    $script:DiskDialog = $dlg
    $dlg.Text = 'JUNO | Diagnostico y mantenimiento de discos'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(795, 670)
    $dlg.MinimumSize = New-Object System.Drawing.Size(795, 670)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(22, 26, 34)
    $dlg.ForeColor = [System.Drawing.Color]::White
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $white = [System.Drawing.Color]::FromArgb(238,240,244)
    $muted = [System.Drawing.Color]::FromArgb(170,180,198)
    $blue = [System.Drawing.Color]::FromArgb(51,101,173)
    $green = [System.Drawing.Color]::FromArgb(38,135,96)
    $gray = [System.Drawing.Color]::FromArgb(67,76,91)

    $dlg.Controls.Add((New-Label '7. Almacenamiento SSD / HDD' 22 14 725 32 17 $true $white))
    $dlg.Controls.Add((New-Label 'Diagnostico primero. No optimiza unidades, ni modifica TRIM, sin tu confirmacion.' 22 48 740 27 10 $false $muted))
    $panel = New-Panel 20 79 754 466
    $dlg.Controls.Add($panel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $script:DiskGrid = $grid
    $grid.Location = New-Object System.Drawing.Point(14, 14)
    $grid.Size = New-Object System.Drawing.Size(725, 160)
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(26,32,42)
    $grid.ForeColor = [System.Drawing.Color]::FromArgb(24,29,37)
    $grid.RowHeadersVisible = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ColumnHeadersHeight = 31
    [void]$grid.Columns.Add('Unidad','Unidad')
    [void]$grid.Columns.Add('Etiqueta','Etiqueta')
    [void]$grid.Columns.Add('Tipo','Medio')
    [void]$grid.Columns.Add('Capacidad','Capacidad')
    [void]$grid.Columns.Add('Libre','Libre')
    [void]$grid.Columns.Add('Estado','Salud*')
    $grid.Columns['Unidad'].FillWeight = 48
    $grid.Columns['Etiqueta'].FillWeight = 125
    $grid.Columns['Tipo'].FillWeight = 70
    $grid.Columns['Capacidad'].FillWeight = 88
    $grid.Columns['Libre'].FillWeight = 88
    $grid.Columns['Estado'].FillWeight = 110
    $panel.Controls.Add($grid)

    $details = New-Object System.Windows.Forms.TextBox
    $script:DiskDetails = $details
    $details.Location = New-Object System.Drawing.Point(14, 183)
    $details.Size = New-Object System.Drawing.Size(725, 195)
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = 'Vertical'
    $details.BackColor = [System.Drawing.Color]::FromArgb(26,32,42)
    $details.ForeColor = $white
    $details.BorderStyle = 'FixedSingle'
    $details.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $panel.Controls.Add($details)

    $trimText = New-Label 'TRIM NTFS: consultando...' 14 387 725 22 10 $false $muted
    $script:DiskTrimLabel = $trimText
    $panel.Controls.Add($trimText)
    $taskText = New-Label 'Mantenimiento programado: consultando...' 14 414 725 22 10 $false $muted
    $script:DiskTaskLabel = $taskText
    $panel.Controls.Add($taskText)
    $panel.Controls.Add((New-Label '* Estado informado por Windows; NO constituye una prueba SMART completa.' 14 439 725 20 9 $false $muted))

    $btnRefresh = New-Button 'Actualizar diagnostico' 20 558 220 37 $blue
    $btnOptimize = New-Button 'Optimizar unidad (/O)' 255 558 253 37 $green
    $script:DiskOptimizeButton = $btnOptimize
    $btnOfficial = New-Button 'Abrir optimizador Windows' 522 558 252 37 $gray
    $dlg.Controls.Add($btnRefresh); $dlg.Controls.Add($btnOptimize); $dlg.Controls.Add($btnOfficial)

    $btnEnableTrim = New-Button 'Habilitar TRIM NTFS' 20 605 220 35 $blue
    $script:DiskEnableTrimButton = $btnEnableTrim
    $btnRestoreTrim = New-Button 'Restaurar TRIM anterior' 255 605 253 35 $gray
    $script:DiskRestoreTrimButton = $btnRestoreTrim
    $btnClose = New-Button 'Cerrar' 522 605 252 35 $gray
    $dlg.Controls.Add($btnEnableTrim); $dlg.Controls.Add($btnRestoreTrim); $dlg.Controls.Add($btnClose)

    $status = New-Label 'Estado: iniciando diagnostico...' 23 645 745 24 9 $false $muted
    $script:DiskStatus = $status
    $dlg.Controls.Add($status)

    $timer = New-Object System.Windows.Forms.Timer
    $script:DiskTimer = $timer
    $timer.Interval = 750
    $timer.Add_Tick({
        try { Stop-DiskOptimizeIfFinished }
        catch { $script:DiskStatus.Text="No se pudo leer el resultado: $($_.Exception.Message)" }
    })
    $grid.Add_SelectionChanged({ Update-DiskDetails })
    $btnRefresh.Add_Click({
        try { Refresh-DiskManager }
        catch { [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, "Error de diagnostico: $($_.Exception.Message)", 'JUNO', 'OK', 'Warning') | Out-Null }
    })
    $btnOptimize.Add_Click({
        try { Start-DiskOptimize }
        catch { [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, "No se inicio: $($_.Exception.Message)", 'JUNO', 'OK', 'Warning') | Out-Null }
    })
    $btnOfficial.Add_Click({
        try { Start-Process (Get-JunoSystemTool 'dfrgui.exe') }
        catch { [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, $_.Exception.Message, 'JUNO') | Out-Null }
    })
    $btnEnableTrim.Add_Click({
        try { Enable-DiskTrim }
        catch { [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, $_.Exception.Message, 'JUNO', 'OK', 'Warning') | Out-Null }
    })
    $btnRestoreTrim.Add_Click({
        try { Restore-DiskTrim }
        catch { [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, $_.Exception.Message, 'JUNO', 'OK', 'Warning') | Out-Null }
    })
    $btnClose.Add_Click({ if ($null -eq $script:DiskProcess) { $script:DiskDialog.Close() } })
    $dlg.Add_FormClosing({
        param($sender,$e)
        if ($null -ne $script:DiskProcess) {
            $e.Cancel=$true
            [System.Windows.Forms.MessageBox]::Show($script:DiskDialog, 'Espera a que termine la optimizacion antes de cerrar esta ventana.', 'JUNO') | Out-Null
        }
    })
    Initialize-JunoWindow $dlg $parent
    try {
        Refresh-DiskManager
        if (-not $script:DiskIsAdmin) {
            $script:DiskStatus.Text='Solo consulta. Para optimizar o cambiar TRIM, abre JUNO como administrador.'
        }
        [void]$dlg.ShowDialog($parent)
    } finally {
        $timer.Stop(); $timer.Dispose()
        $script:DiskTimer=$null
        $script:DiskGrid=$null
        $script:DiskDetails=$null
        $script:DiskStatus=$null
        $script:DiskTrimLabel=$null
        $script:DiskTaskLabel=$null
        $script:DiskOptimizeButton=$null
        $script:DiskEnableTrimButton=$null
        $script:DiskRestoreTrimButton=$null
        $script:DiskTrimStatus=$null
        $script:DiskDialog=$null
        $dlg.Dispose()
    }
}
