# JUNO v0.7 - Analisis y control manual de procesos de usuario.
# NO desactiva servicios, permisos, tareas ni procesos de Windows.
# No se ejecutan acciones al abrir este modulo; cada cierre exige confirmacion.

# Lista muy acotada: solo estos ejecutables pueden finalizarse a la fuerza
# desde esta interfaz. El usuario debe seleccionar un PID y confirmar.
$script:BgOptionalNames = @(
    'discord', 'spotify', 'steam', 'epicgameslauncher', 'goggalaxy',
    'battle.net', 'ubisoftconnect', 'telegram', 'slack'
)
# Herramientas y procesos criticos que JUNO nunca cierra.
# La lista no sustituye el resto de las comprobaciones de seguridad.
$script:BgProtectedNames = @(
    'system','idle','registry','smss','csrss','wininit','winlogon',
    'services','lsass','lsm','svchost','dwm','explorer','sihost',
    'taskhostw','taskhost','conhost','audiodg','fontdrvhost','ctfmon',
    'dllhost','runtimebroker','searchhost','searchapp','searchindexer',
    'startmenuexperiencehost','shellexperiencehost','applicationframehost',
    'securityhealthsystray','msmpeng','mssense','nissrv','spoolsv',
    'systemsettings','taskmgr','powershell','pwsh','cmd','windowsterminal',
    'openconsole','devenv','code','codium','msbuild','dotnet','sqlservr',
    'mysqld','postgres','docker','com.docker.backend','vboxheadless',
    'virtualboxvm','vmware-vmx','java','node','python','pythonw',
    'arduino-ide','arduino-cli','git','git-bash','git-remote-https',
    'obs64','obs32','backup','onedrive','dropbox','googledrivesync',
    'filecoauth','everything'
)

function Test-BgAllowedPath([string]$exePath, [string]$procName) {
    if ([string]::IsNullOrWhiteSpace($exePath)) { return $false }
    if ($script:BgProtectedNames -contains $procName.ToLowerInvariant()) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($exePath)) { return $false }
    $windowsDir = [System.IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\') + '\'
    # Ningun ejecutable bajo la carpeta Windows, aunque figure en sesion de usuario.
    if ($exePath.StartsWith($windowsDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $true
}

function Get-BgFreeMemoryMB {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $info = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
        return [math]::Round(([double]$info.AvailablePhysicalMemory / 1MB), 0)
    } catch { return $null }
}

function Get-BgProcesses {
    # Una muestra corta evita presentar el tiempo de CPU acumulado como uso actual.
    $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $previousCpuMs = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($p.SessionId -eq $session) {
                $previousCpuMs[[string]$p.Id] = [double]$p.TotalProcessorTime.TotalMilliseconds
            }
        } catch { } finally { $p.Dispose() }
    }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 800
    $timer.Stop()
    $elapsedMs = [math]::Max(1.0, $timer.Elapsed.TotalMilliseconds)
    $cpuCount = [math]::Max(1, [Environment]::ProcessorCount)
    $result = New-Object 'System.Collections.Generic.List[object]'

    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($p.HasExited -or $p.SessionId -ne $session) { continue }
            $name = [string]$p.ProcessName
            $path = [string]$p.MainModule.FileName
            if (-not (Test-BgAllowedPath $path $name)) { continue }
            # Si no podemos verificar inicio/ruta, no se ofrece el proceso.
            $startTicks = [long]$p.StartTime.ToUniversalTime().Ticks
            $isOptional = ($script:BgOptionalNames -contains $name.ToLowerInvariant())
            $hasWindow = ($p.MainWindowHandle -ne [IntPtr]::Zero)
            $oldCpu = $previousCpuMs[[string]$p.Id]
            $cpuPct = 0.0
            if ($null -ne $oldCpu) {
                $deltaMs = [math]::Max(0, ([double]$p.TotalProcessorTime.TotalMilliseconds - [double]$oldCpu))
                $cpuPct = [math]::Min(100.0, (100.0 * $deltaMs / ($elapsedMs * $cpuCount)))
            }
            $result.Add([pscustomobject]@{
                Pid=[int]$p.Id; Name=$name; Path=$path; StartTicks=$startTicks;
                RamMB=[math]::Round(([double]$p.WorkingSet64 / 1MB), 1);
                CpuPct=[math]::Round($cpuPct, 1); HasWindow=[bool]$hasWindow;
                Optional=[bool]$isOptional;
                Suggestion=$(if ($isOptional) { 'Opcional: revisar' } else { 'Revisar antes de cerrar' })
            })
        } catch { # Procesos protegidos o que terminaron mientras se analizaban.
        } finally { $p.Dispose() }
    }
    return @($result.ToArray() | Sort-Object RamMB -Descending)
}

function Get-BgVerifiedProcess($entry) {
    # Revalidacion inmediata: nunca actuar sobre un PID reutilizado o un ejecutable distinto.
    $p = [System.Diagnostics.Process]::GetProcessById([int]$entry.Pid)
    try {
        $realPath = [string]$p.MainModule.FileName
        $realName = [string]$p.ProcessName
        $valid = -not $p.HasExited -and
            $p.SessionId -eq [System.Diagnostics.Process]::GetCurrentProcess().SessionId -and
            [long]$p.StartTime.ToUniversalTime().Ticks -eq [long]$entry.StartTicks -and
            [string]::Equals($realName, [string]$entry.Name, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($realPath, [string]$entry.Path, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-BgAllowedPath $realPath $realName)
        if (-not $valid) { throw 'El proceso cambio, termino o no es seguro para gestionar. Actualiza la lista.' }
        return $p
    } catch {
        $p.Dispose()
        throw
    }
}

function Get-BgSettingsUri {
    # CurrentBuildNumber diferencia Windows 11 (22000+) de Windows 10.
    # En ambos casos la pantalla administra solo aplicaciones compatibles.
    try {
        $build = [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
        if ($build -ge 22000) { return 'ms-settings:appsfeatures' }
    } catch { }
    return 'ms-settings:privacy-backgroundapps'
}

function Show-BackgroundManager([System.Windows.Forms.Form]$parent) {
    $dialog = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dialog.Icon = $script:JunoIcon }
    $dialog.Text = 'JUNO v0.8 | Procesos activos'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(1008, 660)
    $dialog.MinimumSize = New-Object System.Drawing.Size(1008, 660)
    $dialog.FormBorderStyle = 'FixedSingle'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(22,26,34)
    $dialog.ForeColor = [System.Drawing.Color]::White
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:BgDialog = $dialog

    $dialog.Controls.Add((New-Label '7. Procesos y aplicaciones en segundo plano' 20 12 968 32 18 $true $white))
    $dialog.Controls.Add((New-Label 'Mide RAM y CPU. Cerrar ahora NO impide que una app vuelva a iniciarse.' 22 48 964 23 10 $false $muted))
    $dialog.Controls.Add((New-Label 'Una app sin ventana no necesariamente esta consumiendo recursos en segundo plano.' 22 72 964 23 9 $false $muted))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 112)
    $grid.Size = New-Object System.Drawing.Size(968, 337)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.ReadOnly = $true
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(30,35,45)
    $grid.GridColor = [System.Drawing.Color]::FromArgb(65,72,86)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(47,59,77)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersHeight = 36
    $grid.RowTemplate.Height = 29
    $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(31,38,49)
    $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(47,85,121)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(38,45,57)
    foreach ($info in @(
        @('Proceso',185),@('PID',75),@('RAM (MB)',105),
        @('CPU (%)',100),@('Ventana',100),@('Recomendacion',350)
    )) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText = [string]$info[0]
        $column.Width = [int]$info[1]
        $column.SortMode = 'NotSortable'
        $grid.Columns.Add($column) | Out-Null
    }
    $dialog.Controls.Add($grid)
    $script:BgGrid = $grid

    $detail = New-Label 'Selecciona un proceso para ver su ruta.' 22 456 965 26 9 $false $muted
    $detail.AutoEllipsis = $true
    $dialog.Controls.Add($detail)
    $script:BgDetail = $detail
    $status = New-Label 'Preparando analisis de procesos...' 22 487 965 26 10 $false $muted
    $dialog.Controls.Add($status)
    $script:BgStatus = $status
    $dialog.Controls.Add((New-Label 'RAM = memoria de trabajo (puede incluir paginas compartidas). CPU = muestra aproximada de 0,8 s.' 22 514 965 22 9 $false $muted))

    $btnRefresh = New-Button 'Actualizar mediciones' 20 546 302 38 $gray
    $btnCloseSafe = New-Button 'Solicitar cierre normal' 340 546 310 38 $blue
    $btnForce = New-Button 'Finalizar opcional (riesgo)' 668 546 320 38 $gray
    $btnSettings = New-Button 'Configurar permisos' 20 599 235 37 $gray
    $btnStartup = New-Button 'Programas de inicio' 267 599 234 37 $gray
    $btnTaskManager = New-Button 'Administrador de tareas' 513 599 234 37 $gray
    $btnExit = New-Button 'Cerrar' 759 599 229 37 $gray
    foreach ($button in @($btnRefresh,$btnCloseSafe,$btnForce,$btnSettings,$btnStartup,$btnTaskManager,$btnExit)) {
        $dialog.Controls.Add($button)
    }

    # Los controles se guardan en script como los demas modulos WinForms.
    $script:BgRefresh = {
        $script:BgGrid.Rows.Clear()
        $script:BgDetail.Text = 'Selecciona un proceso para ver su ruta.'
        $script:BgStatus.Text = 'Analizando procesos y tomando una muestra de CPU...'
        $script:BgDialog.Refresh()
        $all = @(Get-BgProcesses)
        foreach ($entry in $all) {
            $rowIndex = $script:BgGrid.Rows.Add()
            $row = $script:BgGrid.Rows[$rowIndex]
            $row.Tag = $entry
            $row.Cells[0].Value = $entry.Name
            $row.Cells[1].Value = $entry.Pid
            $row.Cells[2].Value = ('{0:N1}' -f $entry.RamMB)
            $row.Cells[3].Value = ('{0:N1}' -f $entry.CpuPct)
            $row.Cells[4].Value = $(if ($entry.HasWindow) { 'Si' } else { 'No' })
            $row.Cells[5].Value = $entry.Suggestion
            $row.Cells[0].ToolTipText = $entry.Path
        }
        $free = Get-BgFreeMemoryMB
        $freeText = if ($null -ne $free) { (' | RAM disponible: {0:N0} MB' -f $free) } else { '' }
        $script:BgStatus.Text = "Procesos mostrados: $($all.Count) | Solo esta sesion y rutas accesibles$freeText"
        $script:BgGrid.ClearSelection()
    }

    $script:BgGrid.Add_SelectionChanged({
        if ($script:BgGrid.SelectedRows.Count -eq 1) {
            $entry = $script:BgGrid.SelectedRows[0].Tag
            if ($null -ne $entry) {
                $script:BgDetail.Text = "PID $($entry.Pid) | Ruta: $($entry.Path)"
            }
        }
    })

    $script:BgGetSelected = {
        if ($script:BgGrid.SelectedRows.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,
                'Selecciona UNA fila y revisa el nombre y su ruta antes de continuar.',
                'JUNO') | Out-Null
            return $null
        }
        return $script:BgGrid.SelectedRows[0].Tag
    }

    $btnCloseSafe.Add_Click({
        $entry = & $script:BgGetSelected
        if ($null -eq $entry) { return }
        if (-not $entry.HasWindow) {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,
                'Este proceso no tenia ventana principal. No es posible pedirle un cierre normal. Solo los ejecutables opcionales admitidos pueden finalizarse desde este modulo.',
                'Sin ventana principal') | Out-Null
            return
        }
        $ask = "Solicitar cierre normal de $($entry.Name) (PID $($entry.Pid))?`n`nGuarda antes cualquier trabajo abierto. La aplicacion puede pedir confirmacion o rechazar el cierre. No se forzara."
        if ([System.Windows.Forms.MessageBox]::Show($script:BgDialog,$ask,'Confirmar cierre',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $memBefore = Get-BgFreeMemoryMB
        $proc = $null
        try {
            $proc = Get-BgVerifiedProcess $entry
            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) { throw 'La ventana ya no esta disponible. Actualiza la lista.' }
            $requested = $proc.CloseMainWindow()
            if (-not $requested) { throw 'La aplicacion no acepto la solicitud de cierre.' }
            $finished = $proc.WaitForExit(1300)
            $message = if ($finished) { "Cerrado: $($entry.Name) (PID $($entry.Pid))." }
                       else { 'Solicitud enviada. La aplicacion podria seguir abierta o estar esperando tu confirmacion.' }
            $memAfter = Get-BgFreeMemoryMB
            if ($null -ne $memBefore -and $null -ne $memAfter) {
                $message += ("`n`nRAM disponible: {0:N0} MB antes / {1:N0} MB despues. Puede fluctuar por otros procesos." -f $memBefore, $memAfter)
            }
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,$message,'Cierre normal') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,$_.Exception.Message,'No se pudo cerrar',
                [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
            & $script:BgRefresh
        }
    })

    $btnForce.Add_Click({
        $entry = & $script:BgGetSelected
        if ($null -eq $entry) { return }
        if (-not $entry.Optional -or $script:BgOptionalNames -notcontains ([string]$entry.Name).ToLowerInvariant()) {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,
                'Por seguridad, esta opcion solo permite finalizar un PID de las aplicaciones opcionales reconocidas. Para otros procesos, utiliza el cierre normal o el Administrador de tareas.',
                'Accion bloqueada') | Out-Null
            return
        }
        $ask = "Finalizar A LA FUERZA $($entry.Name) (PID $($entry.Pid))?`n`nPodrias perder datos sin guardar y detener descargas o sincronizaciones. No se desactiva su inicio futuro ni se puede deshacer esta finalizacion."
        if ([System.Windows.Forms.MessageBox]::Show($script:BgDialog,$ask,'Confirmar finalizacion forzada',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $memBefore = Get-BgFreeMemoryMB
        $proc = $null
        try {
            $proc = Get-BgVerifiedProcess $entry
            if ($script:BgOptionalNames -notcontains $proc.ProcessName.ToLowerInvariant()) {
                throw 'La aplicacion ya no esta en la lista opcional.'
            }
            $proc.Kill()
            $finished = $proc.WaitForExit(1500)
            $message = if ($finished) { "Proceso finalizado: $($entry.Name) (PID $($entry.Pid)). Puede reiniciarse por su cuenta." }
                       else { 'Se solicito finalizar, pero no se pudo confirmar que el proceso termino.' }
            $memAfter = Get-BgFreeMemoryMB
            if ($null -ne $memBefore -and $null -ne $memAfter) {
                $message += ("`n`nRAM disponible: {0:N0} MB antes / {1:N0} MB despues. Puede fluctuar por otros procesos." -f $memBefore, $memAfter)
            }
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,$message,'Finalizacion') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,$_.Exception.Message,'No se pudo finalizar',
                [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
            & $script:BgRefresh
        }
    })

    $btnRefresh.Add_Click({
        try { & $script:BgRefresh }
        catch { $script:BgStatus.Text = "Error de lectura: $($_.Exception.Message)" }
    })
    $btnSettings.Add_Click({
        try { Show-BackgroundPermissions $script:BgDialog }
        catch {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,
                "No se pudo abrir Configuracion: $($_.Exception.Message)", 'JUNO') | Out-Null
        }
    })
    $btnStartup.Add_Click({
        try { Show-StartupManager $script:BgDialog }
        catch {
            [System.Windows.Forms.MessageBox]::Show($script:BgDialog,
                "No se pudo abrir el administrador de inicio: $($_.Exception.Message)", 'JUNO') | Out-Null
        }
    })
    $btnTaskManager.Add_Click({ Start-Process 'taskmgr.exe' })
    $btnExit.Add_Click({ $script:BgDialog.Close() })

    try {
        & $script:BgRefresh
        [void]$dialog.ShowDialog($parent)
    } finally {
        $script:BgGrid = $null
        $script:BgDialog = $null
        $script:BgDetail = $null
        $script:BgStatus = $null
        $script:BgRefresh = $null
        $script:BgGetSelected = $null
        $dialog.Dispose()
    }
}
