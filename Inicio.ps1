# JUNO v0.4 - Administrador de aplicaciones de inicio clasico.
# Detecta entradas Run y carpetas Inicio del usuario/equipo.
# Solo manipula la clave StartupApproved de la entrada ELEGIDA, nunca elimina Run,
# archivos originales ni desactiva servicios o tareas del Programador.
# StartupApproved es un formato interno de Windows: comprobar en ambos SO.

$script:StartupBackupPath = Join-Path $script:AppFolder 'inicio-backup.json'
$script:StartupRootRun = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupRootApproval = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:StartupRegView = if ([Environment]::Is64BitOperatingSystem) { 'Registry64' } else { 'Default' }
$script:StartupIsAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $script:StartupIsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $script:StartupIsAdmin = $false }

function Open-StartupRegKey([string]$hive, [string]$view, [string]$path, [bool]$write, [bool]$create) {
    $regHive = [System.Enum]::Parse([Microsoft.Win32.RegistryHive], $hive)
    $regView = [System.Enum]::Parse([Microsoft.Win32.RegistryView], $view)
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey($regHive, $regView)
    try {
        if ($create) { return $root.CreateSubKey($path) }
        return $root.OpenSubKey($path, $write)
    } finally { $root.Close() }
}
function Read-StartupRegValue([string]$hive, [string]$view, [string]$path, [string]$name) {
    $key = Open-StartupRegKey $hive $view $path $false $false
    if ($null -eq $key) { return [pscustomobject]@{ Exists=$false; Kind=$null; Data=$null } }
    try {
        if ($key.GetValueNames() -notcontains $name) { return [pscustomobject]@{ Exists=$false; Kind=$null; Data=$null } }
        $kind = $key.GetValueKind($name).ToString()
        $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{ Exists=$true; Kind=$kind; Data=$data }
    } finally { $key.Close() }
}
function Get-StartupFlag($approved) {
    if (-not $approved.Exists) { return 'Activo' }
    if ($approved.Kind -ne 'Binary' -or $null -eq $approved.Data -or $approved.Data.Length -lt 1) { return 'Desconocido' }
    $flag = [int]$approved.Data[0]
    if ($flag -eq 2 -or $flag -eq 6) { return 'Activo' }
    if ($flag -eq 3 -or $flag -eq 7) { return 'Desactivado' }
    return 'Desconocido'
}
function Get-StartupHash([string]$value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
        return [Convert]::ToBase64String($sha.ComputeHash($bytes))
    } finally { $sha.Dispose() }
}
function Get-StartupSourceFingerprint($entry) {
    if ($entry.SourceType -eq 'Registro') {
        $src = Read-StartupRegValue $entry.SourceHive $entry.SourceView $entry.SourceKey $entry.SourceValue
        if (-not $src.Exists) { return $null }
        return (Get-StartupHash ("$($entry.Id)|$($src.Kind)|$($src.Data)"))
    }
    if (-not (Test-Path -LiteralPath $entry.SourceKey -PathType Leaf)) { return $null }
    $f = Get-Item -LiteralPath $entry.SourceKey -ErrorAction Stop
    return (Get-StartupHash ("$($entry.Id)|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"))
}
function Get-StartupPublisher([string]$command) {
    if (-not $command) { return 'Sin datos' }
    try {
        $text = [Environment]::ExpandEnvironmentVariables($command.Trim())
        $path = $null
        if ($text -match '^\s*"([^"]+\.exe)"') { $path = $Matches[1] }
        elseif ($text -match '^\s*(.+?\.exe)(?=\s|$)') { $path = $Matches[1] }
        elseif ($text -match '\.exe$') { $path = $text }
        if ($path -and [System.IO.File]::Exists($path)) {
            $company = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path).CompanyName
            if ($company) { return $company }
        }
    } catch { }
    return 'Sin datos'
}
function Get-StartupRecommendation([string]$name, [string]$command, [string]$publisher) {
    $search = "$name $command $publisher"
    if ($search -match '(?i)(defender|securityhealth|antivir|malwarebytes|kaspersky|eset|bitdefender|sophos|crowdstrike|sentinelone|firewall|vpn|wireguard|openvpn|realtek|synaptics|touchpad|fingerprint|biometric|logitech|logioptions|intel|nvidia|radeon|amd|backup|onedrive|dropbox|icloud|google\s?drive)') {
        return 'Mantener / revisar'
    }
    if ($search -match '(?i)(spotify|discord|steam|epicgameslauncher|epic games launcher|battle\.net|ubisoft connect|gog galaxy|riot client)') {
        return 'Opcional'
    }
    return 'Revisar'
}
function Get-StartupEntries {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $specs = @(
        @{ Hive='CurrentUser'; View='Default'; Scope='Usuario'; Src=$script:StartupRootRun; Approval='Run'; Label='Registro - usuario' },
        @{ Hive='LocalMachine'; View=$script:StartupRegView; Scope='Equipo'; Src=$script:StartupRootRun; Approval='Run'; Label='Registro - equipo' }
    )
    if ([Environment]::Is64BitOperatingSystem) {
        $specs += @{ Hive='LocalMachine'; View='Registry32'; Scope='Equipo'; Src=$script:StartupRootRun; Approval='Run32'; Label='Registro - 32 bits' }
    }
    foreach ($spec in $specs) {
        $key = $null
        try {
            $key = Open-StartupRegKey $spec.Hive $spec.View $spec.Src $false $false
            if ($null -eq $key) { continue }
            $names = @($key.GetValueNames() | Where-Object { $_ -ne '' })
            foreach ($name in $names) {
                try {
                    $raw = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($null -eq $raw) { continue }
                    $command = [string]$raw
                    $approvalKey = "$($script:StartupRootApproval)\$($spec.Approval)"
                    # Las claves StartupApproved se encuentran en la vista 64 bit del equipo.
                    $approvalView = if ($spec.Hive -eq 'CurrentUser') { 'Default' } else { $script:StartupRegView }
                    $approved = Read-StartupRegValue $spec.Hive $approvalView $approvalKey $name
                    $state = Get-StartupFlag $approved
                    $publisher = Get-StartupPublisher $command
                    $id = "$($spec.Hive)|$($spec.View)|$($spec.Src)|$name"
                    $item = [pscustomobject]@{
                        Id=$id; Name=$name; State=$state; Scope=$spec.Scope; Origin=$spec.Label;
                        Publisher=$publisher; Command=$command;
                        Recommendation=(Get-StartupRecommendation $name $command $publisher);
                        SourceType='Registro'; SourceHive=$spec.Hive; SourceView=$spec.View;
                        SourceKey=$spec.Src; SourceValue=$name;
                        ApprovalHive=$spec.Hive; ApprovalView=$approvalView; ApprovalKey=$approvalKey; ApprovalValue=$name;
                        Editable=($state -ne 'Desconocido' -and ($spec.Scope -eq 'Usuario' -or $script:StartupIsAdmin))
                    }
                    $items.Add($item)
                } catch { # Se omite una entrada ilegible sin interrumpir las demas.
                }
            }
        } catch { # HKLM podria no ser accesible por directivas.
        } finally { if ($null -ne $key) { $key.Close() } }
    }
    # No se eliminan archivos. Se usa el mismo mecanismo StartupApproved de Windows.
    $folders = @(
        @{ Path=[Environment]::GetFolderPath([Environment+SpecialFolder]::Startup); Scope='Usuario'; Label='Carpeta - usuario' },
        @{ Path=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup); Scope='Equipo'; Label='Carpeta - equipo' }
    )
    foreach ($folder in $folders) {
        try {
            if (-not (Test-Path -LiteralPath $folder.Path -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -File -ErrorAction Stop)) {
                if ($file.Name -ieq 'desktop.ini') { continue }
                $approvalHive = if ($folder.Scope -eq 'Usuario') { 'CurrentUser' } else { 'LocalMachine' }
                $approvalKey = "$($script:StartupRootApproval)\StartupFolder"
                $approved = Read-StartupRegValue $approvalHive $script:StartupRegView $approvalKey $file.Name
                $state = Get-StartupFlag $approved
                $id = "Archivo|$($file.FullName)"
                $command = $file.FullName
                $items.Add([pscustomobject]@{
                    Id=$id; Name=$file.BaseName; State=$state; Scope=$folder.Scope; Origin=$folder.Label;
                    Publisher='Sin datos'; Command=$command;
                    Recommendation=(Get-StartupRecommendation $file.Name $command '');
                    SourceType='Archivo'; SourceHive=''; SourceView='';
                    SourceKey=$file.FullName; SourceValue=$file.Name;
                    ApprovalHive=$approvalHive; ApprovalView=$script:StartupRegView; ApprovalKey=$approvalKey; ApprovalValue=$file.Name;
                    Editable=($state -ne 'Desconocido' -and ($folder.Scope -eq 'Usuario' -or $script:StartupIsAdmin))
                })
            }
        } catch { }
    }
    return $items.ToArray()
}
function Get-StartupBackup {
    $user=Read-JunoStore 'Startup' 'User' ([pscustomobject]@{Entries=@()})
    # Los registros HKLM historicos solo se muestran; escribir requiere importacion revisada.
    $machine=@()
    if (Test-JunoAdmin) {
        $saved=Read-JunoStore 'Startup' 'Machine' $null
        if ($null -ne $saved) { $machine=@($saved.Entries) }
        else { $machine=@($user.Entries | Where-Object {$_.ApprovalHive -eq 'LocalMachine'}) }
    }
    return [pscustomobject]@{Entries=@($user.Entries | Where-Object {$_.ApprovalHive -eq 'CurrentUser'})+$machine}
}
function Save-StartupBackup($backup) {
    Assert-JunoLease
    Assert-JunoStartupData $backup 'Any'
    $machine=[pscustomobject]@{Entries=@($backup.Entries | Where-Object {$_.ApprovalHive -eq 'LocalMachine'})}
    if (Test-JunoAdmin) {
        Import-JunoMachineLegacy 'Startup'
        Write-JunoStore 'Startup' $machine 'Machine'
    } elseif ($machine.Entries.Count -gt 0) { throw 'No hay permisos para guardar cambios de inicio del equipo.' }
    Write-JunoStore 'Startup' ([pscustomobject]@{Entries=@($backup.Entries | Where-Object {$_.ApprovalHive -eq 'CurrentUser'})}) 'User'
}
function Get-StartupApprovalSnapshot($value) {
    if ($value.Exists -and $value.Kind -ne 'Binary') { throw 'Valor de control de inicio no binario.' }
    $data = if ($value.Exists) { [Convert]::ToBase64String([byte[]]$value.Data) } else { $null }
    return [pscustomobject]@{ Exists=[bool]$value.Exists; Data=$data }
}
function Test-StartupApprovalSnapshot($actual, $expected) {
    return ([bool]$actual.Exists -eq [bool]$expected.Exists -and
        (-not $actual.Exists -or [string]$actual.Data -ceq [string]$expected.Data))
}
function Initialize-StartupTransaction($record) {
    if ($record.PSObject.Properties.Name -contains 'Transaction') {
        if ($null -eq $record.Transaction -or $record.Transaction.Version -ne 1) {
            throw 'Registro de recuperacion de inicio incompatible; se conserva el respaldo.'
        }
        return
    }
    # En v0.8 LastWrittenData era una INTENCION, no una confirmacion.
    $pending = if ($record.LastWrittenData) {
        [pscustomobject]@{ Exists=$true; Data=[string]$record.LastWrittenData; Action='Apply' }
    } else { $null }
    $transaction = [pscustomobject]@{
        Version=1
        Confirmed=[pscustomobject]@{ Exists=[bool]$record.OriginalExists; Data=$record.OriginalData }
        Pending=$pending
    }
    Add-Member -InputObject $record -MemberType NoteProperty -Name Transaction -Value $transaction
    $record.LastWrittenData = $null
}
function Sync-StartupTransaction($record, $actual) {
    $transaction = $record.Transaction
    if ($null -ne $transaction.Pending -and (Test-StartupApprovalSnapshot $actual $transaction.Pending)) {
        $pending = $transaction.Pending
        $transaction.Confirmed = [pscustomobject]@{ Exists=[bool]$actual.Exists; Data=$actual.Data }
        $record.LastWrittenData = if ($pending.Action -eq 'Apply') { $actual.Data } else { $null }
    } elseif (-not (Test-StartupApprovalSnapshot $actual $transaction.Confirmed)) {
        throw 'La configuracion fue modificada fuera de JUNO. No se sobrescribio.'
    }
    # Si sigue el estado confirmado, la escritura pendiente no se aplico.
    $transaction.Pending = $null
}
function Write-StartupTransaction($backup, $record, $target, [string]$action) {
    Assert-JunoLease
    Assert-JunoStartupTarget $record
    $transaction = $record.Transaction
    $transaction.Pending = [pscustomobject]@{ Exists=[bool]$target.Exists; Data=$target.Data; Action=$action }
    Save-StartupBackup $backup
    # Releer despues de guardar la intencion y antes de modificar Windows.
    $actual = Get-StartupApprovalSnapshot (Read-StartupRegValue $record.ApprovalHive $record.ApprovalView $record.ApprovalKey $record.ApprovalValue)
    if (-not (Test-StartupApprovalSnapshot $actual $transaction.Confirmed)) {
        throw 'La configuracion de inicio cambio antes de escribir. Se conserva la operacion pendiente.'
    }
    if ((Get-StartupSourceFingerprint $record) -cne $record.Fingerprint) {
        throw 'La entrada original de inicio cambio antes de escribir. Se conserva la operacion pendiente.'
    }
    $key = Open-StartupRegKey $record.ApprovalHive $record.ApprovalView $record.ApprovalKey $true ($action -eq 'Apply')
    if ($null -eq $key) { throw 'No se puede abrir el control de inicio de Windows.' }
    try {
        if ($target.Exists) {
            $bytes = [Convert]::FromBase64String([string]$target.Data)
            $key.SetValue([string]$record.ApprovalValue, [byte[]]$bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
        } else {
            $key.DeleteValue([string]$record.ApprovalValue, $false)
        }
    } finally { $key.Close() }
    $check = Get-StartupApprovalSnapshot (Read-StartupRegValue $record.ApprovalHive $record.ApprovalView $record.ApprovalKey $record.ApprovalValue)
    if (-not (Test-StartupApprovalSnapshot $check $target)) {
        throw 'No se pudo verificar la escritura de inicio. Se conserva la operacion pendiente.'
    }
    $transaction.Confirmed = [pscustomobject]@{ Exists=[bool]$check.Exists; Data=$check.Data }
    $transaction.Pending = $null
    $record.LastWrittenData = if ($action -eq 'Apply') { $check.Data } else { $null }
    Save-StartupBackup $backup
}
function Set-StartupState($entry, [bool]$enable) {
    Assert-JunoLease
    Assert-JunoStartupTarget $entry
    if ($entry.ApprovalHive -eq 'LocalMachine') { Import-JunoMachineLegacy 'Startup' }
    if (-not $entry.Editable) { throw "No se puede modificar: $($entry.Name)." }
    $currentFingerprint = Get-StartupSourceFingerprint $entry
    if (-not $currentFingerprint) { throw "La entrada $($entry.Name) ya no existe." }
    $desiredState = if ($enable) { 'Activo' } else { 'Desactivado' }
    $originalApproved = Read-StartupRegValue $entry.ApprovalHive $entry.ApprovalView $entry.ApprovalKey $entry.ApprovalValue
    $previousState = Get-StartupFlag $originalApproved
    if ($previousState -eq 'Desconocido') { throw "$($entry.Name): tiene un estado no reconocido. Usa el Administrador de tareas." }
    if ($originalApproved.Exists -and $originalApproved.Kind -ne 'Binary') { throw "$($entry.Name): valor de control no binario." }

    $backup = Get-StartupBackup
    $saved = @($backup.Entries | Where-Object { $_.Id -ceq $entry.Id } | Select-Object -First 1)
    if ($saved.Count -eq 0) {
        if ($previousState -eq $desiredState) { return "$($entry.Name): ya estaba $desiredState." }
        $originalBytes = if ($originalApproved.Exists) { [Convert]::ToBase64String([byte[]]$originalApproved.Data) } else { $null }
        $record = [pscustomobject]@{
            Id=$entry.Id; Name=$entry.Name; ApprovalHive=$entry.ApprovalHive;
            ApprovalView=$entry.ApprovalView; ApprovalKey=$entry.ApprovalKey; ApprovalValue=$entry.ApprovalValue;
            SourceType=$entry.SourceType; SourceHive=$entry.SourceHive; SourceView=$entry.SourceView;
            SourceKey=$entry.SourceKey; SourceValue=$entry.SourceValue; Fingerprint=$currentFingerprint;
            OriginalExists=[bool]$originalApproved.Exists; OriginalData=$originalBytes; LastWrittenData=$null
        }
        $backup.Entries = @($backup.Entries) + @($record)
    } else {
        $record = $saved[0]
        if ($record.Fingerprint -cne $currentFingerprint) {
            throw "$($entry.Name): cambio el ejecutable desde la copia inicial. No se modifico."
        }
    }
    Initialize-StartupTransaction $record
    Sync-StartupTransaction $record (Get-StartupApprovalSnapshot $originalApproved)
    if ($previousState -eq $desiredState) {
        Save-StartupBackup $backup
        return "$($entry.Name): ya estaba $desiredState. Registro de recuperacion verificado."
    }
    $bytes = New-Object byte[] 12
    if ($enable) { $bytes[0] = 2 } else { $bytes[0] = 3 }
    if (-not $enable) {
        $timestampBytes = [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())
        [Array]::Copy($timestampBytes, 0, $bytes, 4, 8)
    }
    $target = [pscustomobject]@{ Exists=$true; Data=[Convert]::ToBase64String($bytes) }
    Write-StartupTransaction $backup $record $target 'Apply'
    return "$($entry.Name): $desiredState."
}
function Restore-StartupState {
    Assert-JunoLease
    if (Test-JunoAdmin) { Import-JunoMachineLegacy 'Startup' }
    $backup = Get-StartupBackup
    $entries = @($backup.Entries)
    if ($entries.Count -eq 0) { return 'No hay cambios de inicio guardados.' }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $remaining = New-Object 'System.Collections.Generic.List[object]'
    $count = 0
    foreach ($record in $entries) {
        try {
            $source = [pscustomobject]@{
                Id=$record.Id; SourceType=$record.SourceType; SourceHive=$record.SourceHive;
                SourceView=$record.SourceView; SourceKey=$record.SourceKey; SourceValue=$record.SourceValue
            }
            if ((Get-StartupSourceFingerprint $source) -cne $record.Fingerprint) {
                throw 'La entrada original cambio o ya no existe.'
            }
            $current = Read-StartupRegValue $record.ApprovalHive $record.ApprovalView $record.ApprovalKey $record.ApprovalValue
            Initialize-StartupTransaction $record
            $actual = Get-StartupApprovalSnapshot $current
            Sync-StartupTransaction $record $actual
            $original = [pscustomobject]@{ Exists=[bool]$record.OriginalExists; Data=$record.OriginalData }
            if (-not (Test-StartupApprovalSnapshot $actual $original)) {
                Write-StartupTransaction $backup $record $original 'Restore'
            }
            $count++
        } catch {
            $remaining.Add($record)
            $errors.Add("$($record.Name): $($_.Exception.Message)")
        }
    }
    $backup.Entries = @($remaining.ToArray())
    Save-StartupBackup $backup
    $text = "Restauradas: $count de $($entries.Count)."
    if ($errors.Count -gt 0) { $text += "`nNo restauradas (copia conservada):`n" + ($errors -join "`n") }
    return $text
}

function Show-StartupManager([System.Windows.Forms.Form]$parent) {
    $dialog = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dialog.Icon = $script:JunoIcon }
    $dialog.Text = 'JUNO v0.8 | Administrar programas de inicio'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(1010, 617)
    $dialog.MinimumSize = New-Object System.Drawing.Size(1010, 617)
    $dialog.FormBorderStyle = 'FixedSingle'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(22, 26, 34)
    $dialog.ForeColor = [System.Drawing.Color]::White
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:StartupDialog = $dialog
    $dialog.Controls.Add((New-Label '4. Programas de inicio' 18 10 975 34 18 $true $white))
    $dialog.Controls.Add((New-Label 'Elegí cuáles iniciar con Windows. Nada se cambia sin tu confirmación.' 20 47 970 26 10 $false $muted))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(18, 86)
    $grid.Size = New-Object System.Drawing.Size(974, 328)
    $grid.Anchor = 'Top,Left,Right'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(30,35,45)
    $grid.GridColor = [System.Drawing.Color]::FromArgb(65,72,86)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(47,59,77)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersHeight = 38
    $grid.RowTemplate.Height = 31
    $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(31,38,49)
    $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(47,85,121)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(38,45,57)
    $checkCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $checkCol.HeaderText = 'Elegir'
    $checkCol.Width = 67
    $grid.Columns.Add($checkCol) | Out-Null
    foreach ($field in @(
        @('Aplicación',215), @('Estado',112), @('Origen',168), @('Fabricante',190), @('Sugerencia',170)
    )) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = [string]$field[0]
        $col.Width = [int]$field[1]
        $col.ReadOnly = $true
        $col.SortMode = 'NotSortable'
        $grid.Columns.Add($col) | Out-Null
    }
    $dialog.Controls.Add($grid)
    $script:StartupGrid = $grid

    $lblStatus = New-Label 'Leyendo programas de inicio...' 22 422 963 37 10 $false $muted
    $dialog.Controls.Add($lblStatus)
    $script:StartupStatus = $lblStatus
    $adminNote = if ($script:StartupIsAdmin) { 'Privilegios de administrador: sí.' } else { 'Sin administrador: entradas del equipo solo lectura; podés gestionarlas desde el Administrador de tareas.' }
    $dialog.Controls.Add((New-Label $adminNote 22 453 965 25 9 $false $muted))

    $btnRecommend = New-Button 'Seleccionar opcionales' 18 483 232 38 $gray
    $btnDisable = New-Button 'Desactivar seleccionados' 258 483 237 38 $blue
    $btnEnable = New-Button 'Activar seleccionados' 503 483 229 38 $green
    $btnRestoreStartup = New-Button 'Restaurar cambios' 740 483 252 38 $gray
    $btnRefresh = New-Button 'Actualizar lista' 18 535 231 38 $gray
    $btnTaskmgr = New-Button 'Administrador de tareas' 258 535 237 38 $gray
    $btnSettings = New-Button 'Inicio de Windows' 503 535 229 38 $gray
    $btnClose = New-Button 'Cerrar' 740 535 252 38 $gray
    foreach ($button in @($btnRecommend, $btnDisable, $btnEnable, $btnRestoreStartup, $btnRefresh, $btnTaskmgr, $btnSettings, $btnClose)) {
        $dialog.Controls.Add($button)
    }

    # Estado en el ámbito script para que todos los eventos reutilicen los mismos controles.
    $script:StartupRefresh = {
        $script:StartupGrid.Rows.Clear()
        $entries = @(Get-StartupEntries | Sort-Object Name, Scope)
        foreach ($entry in $entries) {
            $rowId = $script:StartupGrid.Rows.Add()
            $row = $script:StartupGrid.Rows[$rowId]
            $row.Tag = $entry
            $row.Cells[0].Value = $false
            $row.Cells[0].ReadOnly = -not [bool]$entry.Editable
            $row.Cells[1].Value = $entry.Name
            $row.Cells[2].Value = $entry.State
            $row.Cells[3].Value = $entry.Origin
            $row.Cells[4].Value = $entry.Publisher
            $row.Cells[5].Value = $entry.Recommendation
            $row.Cells[1].ToolTipText = $entry.Command
            if (-not $entry.Editable) {
                $row.Cells[0].ToolTipText = 'Requiere administrador o no se reconoce el estado.'
            }
        }
        $countActive = @($entries | Where-Object { $_.State -eq 'Activo' }).Count
        $script:StartupStatus.Text = "Detectados: $($entries.Count) | Activos: $countActive | Solo se incluyen ubicaciones clasicas de inicio."
    }
    $script:StartupApply = {
        param([bool]$enable)
        [void]$script:StartupGrid.EndEdit()
        $selected = @()
        foreach ($row in $script:StartupGrid.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells[0].Value -eq $true -and $row.Tag.Editable) { $selected += $row.Tag }
        }
        if ($selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, 'Primero marcá los programas que quieras modificar.', 'JUNO') | Out-Null
            return
        }
        $verb = if ($enable) { 'activar' } else { 'desactivar' }
        $names = (($selected | Select-Object -First 12 | ForEach-Object { $_.Name }) -join "`n- ")
        $more = if ($selected.Count -gt 12) { "`n... y otros $($selected.Count - 12)." } else { '' }
        $ask = "¿Confirmás $verb $($selected.Count) programa(s) de inicio?`n`n- $names$more`n`nNo se desinstala nada. El cambio surte efecto en el proximo inicio de sesion."
        $answer = [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, $ask, 'Confirmar cambios de inicio',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $count = 0
        $errors = New-Object 'System.Collections.Generic.List[string]'
        foreach ($entry in $selected) {
            try { [void](Set-StartupState $entry $enable); $count++ }
            catch { $errors.Add("$($entry.Name): $($_.Exception.Message)") }
        }
        & $script:StartupRefresh
        $report = "Cambios procesados: $count de $($selected.Count)."
        if ($errors.Count -gt 0) { $report += "`n`nSin confirmacion completa; revisar estado y respaldo:`n" + ($errors -join "`n") }
        [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, $report, 'JUNO',
            [System.Windows.Forms.MessageBoxButtons]::OK, $(if($errors.Count -gt 0){[System.Windows.Forms.MessageBoxIcon]::Warning}else{[System.Windows.Forms.MessageBoxIcon]::Information})) | Out-Null
    }
    $btnRecommend.Add_Click({
        [void]$script:StartupGrid.EndEdit()
        $marked = 0
        foreach ($row in $script:StartupGrid.Rows) {
            $entry = $row.Tag
            $select = ($entry.Editable -and $entry.State -eq 'Activo' -and $entry.Recommendation -eq 'Opcional')
            $row.Cells[0].Value = [bool]$select
            if ($select) { $marked++ }
        }
        $script:StartupStatus.Text = "Seleccionados como opcionales: $marked. Revisá la lista y confirmá si estás de acuerdo."
    })
    $btnDisable.Add_Click({ & $script:StartupApply $false })
    $btnEnable.Add_Click({ & $script:StartupApply $true })
    $btnRestoreStartup.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show($script:StartupDialog,
            '¿Restaurar los estados de inicio guardados por JUNO? No cambia energía ni efectos visuales.',
            'Restaurar inicio', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            $report = Restore-StartupState
            & $script:StartupRefresh
            [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, $report, 'JUNO') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, $_.Exception.Message, 'Error al restaurar') | Out-Null
        }
    })
    $btnRefresh.Add_Click({ & $script:StartupRefresh })
    $btnTaskmgr.Add_Click({ Start-Process 'taskmgr.exe' })
    $btnSettings.Add_Click({
        try { Start-Process 'ms-settings:startupapps' }
        catch { [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, 'No se pudo abrir Configuracion de inicio.') | Out-Null }
    })
    $btnClose.Add_Click({ $script:StartupDialog.Close() })
    try {
        & $script:StartupRefresh
        [void]$dialog.ShowDialog($parent)
    } finally {
        $script:StartupGrid = $null
        $script:StartupDialog = $null
        $script:StartupStatus = $null
        $dialog.Dispose()
    }
}
