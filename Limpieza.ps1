# JUNO v0.5 - Limpieza bajo demanda y con seleccion explicita.
# Sin programador de tareas, sin limpieza de Descargas, sin editar registro.
# El analisis conserva una lista concreta de archivos; solo se intenta borrar esa lista.

$cleanupNative = @'
using System;
using System.Runtime.InteropServices;
public static class WRRecycleBin {
    [StructLayout(LayoutKind.Sequential)]
    public struct SHQUERYRBINFO {
        public UInt32 cbSize;
        public Int64 i64Size;
        public Int64 i64NumItems;
    }
    [DllImport("shell32.dll", EntryPoint="SHQueryRecycleBinW", CharSet=CharSet.Unicode)]
    public static extern int Query(string drive, ref SHQUERYRBINFO info);
    [DllImport("shell32.dll", EntryPoint="SHEmptyRecycleBinW", CharSet=CharSet.Unicode)]
    public static extern int Empty(IntPtr window, string drive, uint flags);
}
'@
Add-Type -TypeDefinition $cleanupNative

function Format-CleanBytes([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Get-RecycleBinEstimate {
    $info = New-Object WRRecycleBin+SHQUERYRBINFO
    $info.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][WRRecycleBin+SHQUERYRBINFO])
    # NULL = la papelera del usuario actual de todas las unidades.
    $code = [WRRecycleBin]::Query($null, [ref]$info)
    if ($code -ne 0) { return [pscustomobject]@{ Available=$false; Count=0; Bytes=0L; Error=("HRESULT 0x{0:X8}" -f ([uint32]($code -band 0xffffffffL))) } }
    return [pscustomobject]@{ Available=$true; Count=[long]$info.i64NumItems; Bytes=[long]$info.i64Size; Error='' }
}

function Test-CleanPath([string]$path, [string]$root) {
    # Evita seguir junctions, symlinks o puntos de montaje, aun si aparecieron
    # despues del analisis. La ruta ha de permanecer bajo la raiz original.
    if (-not $root -or -not $path) { return $false }
    $base = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $cursor = $full
    while ($cursor.Length -ge $base.Length) {
        if (-not ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor))) { return $false }
        $attributes = [IO.File]::GetAttributes($cursor)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($cursor.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        if (-not $cursor) { break }
    }
    return $false
}

function Scan-CleanFolder([string]$root, [int]$days, [string]$filenamePattern, [int]$limit) {
    $result = [pscustomobject]@{ Root=$root; Files=@(); Count=0; Bytes=0L; Skipped=0; Truncated=$false; Available=$false; Note='' }
    if (-not $root -or -not ([IO.Directory]::Exists($root))) { $result.Note='Carpeta no encontrada'; return $result }
    try {
        $rootAttr = [IO.File]::GetAttributes($root)
        if (($rootAttr -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $result.Note='Ruta redirigida: se omite por seguridad'; return $result
        }
    } catch { $result.Note='No se puede acceder a la carpeta'; return $result }
    $result.Available=$true
    $cutoff = [DateTime]::UtcNow.AddDays(-$days)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $inspected = 0
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($current)) {
                try {
                    $attr = [IO.File]::GetAttributes($path)
                    if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.Skipped++; continue }
                    if (($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                        if ($filenamePattern -eq '') { $stack.Push($path) }
                        continue
                    }
                    $inspected++
                    if ($inspected -gt $limit) { $result.Truncated=$true; break }
                    if ($filenamePattern -ne '' -and -not [IO.Path]::GetFileName($path).StartsWith('thumbcache_', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($filenamePattern -ne '' -and [IO.Path]::GetExtension($path) -ine '.db') { continue }
                    # Protege archivos del sistema y datos habituales que no son temporales.
                    if (($attr -band [IO.FileAttributes]::System) -ne 0) { $result.Skipped++; continue }
                    if ($filenamePattern -eq '') {
                        $ext = [IO.Path]::GetExtension($path)
                        if ($ext -match '^(?i:\.((bak|sql|sqlite|sqlite3|db|mdb|accdb|vhd|vhdx|pst|ost|sln|slnx|csproj|vbproj|ipynb|py|ps1|docx|xlsx|pdf)))$') { $result.Skipped++; continue }
                    }
                    $file = [System.IO.FileInfo]::new($path)
                    if ($file.LastWriteTimeUtc -ge $cutoff -or $file.CreationTimeUtc -ge $cutoff) { continue }
                    $candidate = [pscustomobject]@{
                        Path=$file.FullName; Length=[long]$file.Length;
                        LastWriteUtc=$file.LastWriteTimeUtc.Ticks; CreationUtc=$file.CreationTimeUtc.Ticks
                    }
                    $candidates.Add($candidate)
                    $result.Bytes += $candidate.Length
                } catch { $result.Skipped++ }
            }
        } catch { $result.Skipped++ }
        if ($result.Truncated) { break }
    }
    $result.Count=$candidates.Count
    $result.Files=$candidates.ToArray()
    if ($result.Truncated) { $result.Note="Analisis parcial (limite: $limit archivos); solo se limpiara lo mostrado" }
    elseif ($result.Skipped -gt 0) { $result.Note="$($result.Skipped) archivos o rutas omitidos" }
    else { $result.Note="Archivos con mas de $days dias" }
    return $result
}

function Invoke-CleanCandidates($result) {
    $removed=0; $bytes=0L; $skipped=0
    $now = [DateTime]::UtcNow
    foreach ($candidate in $result.Files) {
        try {
            if (-not (Test-CleanPath ([string]$candidate.Path) ([string]$result.Root))) { $skipped++; continue }
            $item = [System.IO.FileInfo]::new([string]$candidate.Path)
            # No borrar nada que haya cambiado desde el analisis.
            if ($item.Length -ne [long]$candidate.Length -or
                $item.LastWriteTimeUtc.Ticks -ne [long]$candidate.LastWriteUtc -or
                $item.CreationTimeUtc.Ticks -ne [long]$candidate.CreationUtc) { $skipped++; continue }
            # Mantener la antiguedad elegible. Revalidar antes de tocar el disco.
            if ($item.LastWriteTimeUtc -gt $now.AddDays(-2)) { $skipped++; continue }
            [IO.File]::Delete($item.FullName) # Los bloqueados o sin permisos se omiten.
            $removed++
            $bytes += [long]$candidate.Length
        } catch { $skipped++ }
    }
    return [pscustomobject]@{ Removed=$removed; Bytes=$bytes; Skipped=$skipped }
}

function Show-CleanupManager([System.Windows.Forms.Form]$parent) {
    $dialog = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dialog.Icon = $script:JunoIcon }
    $dialog.Text = 'JUNO | Limpieza inteligente'
    $dialog.ClientSize = New-Object System.Drawing.Size(840, 535)
    $dialog.MinimumSize = New-Object System.Drawing.Size(840, 535)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(22,26,34)
    $dialog.ForeColor = [System.Drawing.Color]::White
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $dialog.Controls.Add((New-Label '5. Limpieza inteligente' 22 15 750 36 19 $true $white))
    $dialog.Controls.Add((New-Label 'Primero analizar, despues elegir. Nada se elimina automaticamente.' 24 52 790 23 10 $false $muted))
    $dialog.Controls.Add((New-Label 'Solo temporales antiguos y cache de miniaturas. Papelera opcional e irreversible.' 24 78 790 23 10 $false $muted))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(22,114)
    $grid.Size = New-Object System.Drawing.Size(796,224)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeRowsMode = 'None'
    $grid.RowTemplate.Height = 42
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(32,38,49)
    $grid.GridColor = [System.Drawing.Color]::FromArgb(60,70,88)
    $grid.BorderStyle = 'None'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersHeight = 39
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(47,59,77)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(32,38,49)
    $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(48,78,111)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(38,45,57)
    $grid.EditMode = 'EditOnEnter'
    $colChoose = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colChoose.HeaderText='Elegir'; $colChoose.Width=72
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText='Ubicacion'; $colName.Width=260; $colName.ReadOnly=$true
    $colFiles = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colFiles.HeaderText='Archivos'; $colFiles.Width=88; $colFiles.ReadOnly=$true
    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText='Estimado'; $colSize.Width=115; $colSize.ReadOnly=$true
    $colNote = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colNote.HeaderText='Informacion'; $colNote.Width=255; $colNote.ReadOnly=$true
    foreach ($column in @($colChoose,$colName,$colFiles,$colSize,$colNote)) { [void]$grid.Columns.Add($column) }
    $dialog.Controls.Add($grid)

    $hint = New-Label 'Temporales: usuario >7 dias, Windows >14 dias. La Papelera elimina de TODAS las unidades.' 24 344 795 34 10 $false $muted
    $dialog.Controls.Add($hint)
    $btnAnalyze = New-Button 'Analizar' 22 391 181 39 $blue
    $btnRecommended = New-Button 'Seleccionar recomendados' 217 391 223 39 $gray
    $btnClean = New-Button 'Limpiar seleccionados' 454 391 189 39 $green
    $btnClose = New-Button 'Cerrar' 656 391 162 39 $gray
    foreach ($button in @($btnAnalyze,$btnRecommended,$btnClean,$btnClose)) { [void]$dialog.Controls.Add($button) }
    $statusClean = New-Label 'Listo para analizar.' 24 443 795 26 10 $false $white
    $dialog.Controls.Add($statusClean)
    $dialog.Controls.Add((New-Label 'No incluye Descargas, navegadores, proyectos, bases de datos ni limpieza de Windows Update.' 24 480 795 40 10 $false $muted))

    $script:CleanDialog=$dialog
    $script:CleanBtnAnalyze=$btnAnalyze
    $script:CleanBtnRecommended=$btnRecommended
    $script:CleanBtnClean=$btnClean
    $script:CleanGrid=$grid
    $script:CleanStatus=$statusClean
    $script:CleanResults=@{}
    $script:CleanBusy=$false
    $script:CleanAnalyze = {
        if ($script:CleanBusy) { return }
        $script:CleanBusy=$true
        $script:CleanBtnAnalyze.Enabled=$false
        $script:CleanBtnClean.Enabled=$false
        $script:CleanBtnRecommended.Enabled=$false
        $script:CleanDialog.UseWaitCursor=$true
        $script:CleanGrid.Rows.Clear()
        $script:CleanResults=@{}
        $script:CleanStatus.Text='Analizando carpetas autorizadas. Puede tardar unos segundos...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $specs = @(
                [pscustomobject]@{ Id='Usuario'; Name='Temporales del usuario'; Root=(Join-Path $env:LOCALAPPDATA 'Temp'); Days=7; Pattern='' },
                [pscustomobject]@{ Id='Windows'; Name='Temporales de Windows'; Root=(Join-Path $env:WINDIR 'Temp'); Days=14; Pattern='' },
                [pscustomobject]@{ Id='Miniaturas'; Name='Cache de miniaturas'; Root=(Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Days=7; Pattern='thumbcache_' }
            )
            $totalBytes=0L
            foreach ($spec in $specs) {
                $scan = Scan-CleanFolder $spec.Root $spec.Days $spec.Pattern 150000
                $script:CleanResults[$spec.Id]=$scan
                $note=$scan.Note
                $index=$script:CleanGrid.Rows.Add($false, $spec.Name, $scan.Count, (Format-CleanBytes $scan.Bytes), $note)
                $row=$script:CleanGrid.Rows[$index]
                $row.Tag=$spec.Id
                $row.Cells[0].ReadOnly=(-not $scan.Available -or $scan.Count -eq 0)
                $totalBytes += $scan.Bytes
            }
            try { $recycle = Get-RecycleBinEstimate }
            catch { $recycle = [pscustomobject]@{ Available=$false; Count=0; Bytes=0L; Error=$_.Exception.Message } }
            $script:CleanResults['Papelera']=$recycle
            $recycleNote=if ($recycle.Available) { 'IRREVERSIBLE | todas las unidades' } else { 'No se pudo medir' }
            $recycleSize = if ($recycle.Available) { Format-CleanBytes $recycle.Bytes } else { 'No disponible' }
            $index=$script:CleanGrid.Rows.Add($false, 'Papelera de reciclaje', $recycle.Count, $recycleSize, $recycleNote)
            $row=$script:CleanGrid.Rows[$index]
            $row.Tag='Papelera'
            $row.Cells[0].ReadOnly=(-not $recycle.Available -or $recycle.Count -eq 0)
            if ($recycle.Available) { $totalBytes += $recycle.Bytes }
            $script:CleanStatus.Text="Analisis terminado. Potencial estimado: $(Format-CleanBytes $totalBytes). Selecciona que queres limpiar."
        } catch {
            [System.Windows.Forms.MessageBox]::Show($script:CleanDialog, "Error durante el analisis: $($_.Exception.Message)", 'JUNO', 'OK', 'Warning') | Out-Null
            $script:CleanStatus.Text='Error de analisis; no se elimino ningun archivo.'
        } finally {
            $script:CleanBusy=$false
            $script:CleanDialog.UseWaitCursor=$false
            $script:CleanBtnAnalyze.Enabled=$true
            $script:CleanBtnClean.Enabled=$true
            $script:CleanBtnRecommended.Enabled=$true
        }
    }

    $btnAnalyze.Add_Click({ & $script:CleanAnalyze })
    $btnRecommended.Add_Click({
        if ($script:CleanBusy) { return }
        [void]$script:CleanGrid.EndEdit()
        foreach ($row in $script:CleanGrid.Rows) {
            $row.Cells[0].Value=($row.Tag -eq 'Usuario' -and -not $row.Cells[0].ReadOnly)
        }
        $script:CleanStatus.Text='Solo se marco Temporales del usuario. Verifica y pulsa Limpiar seleccionados.'
    })
    $btnClean.Add_Click({
        if ($script:CleanBusy) { return }
        [void]$script:CleanGrid.EndEdit()
        $chosen = @()
        foreach ($row in $script:CleanGrid.Rows) {
            if (-not $row.Cells[0].ReadOnly -and $row.Cells[0].Value -eq $true) { $chosen += $row.Tag }
        }
        if ($chosen.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($script:CleanDialog, 'Selecciona al menos una categoria luego de analizar.', 'JUNO') | Out-Null
            return
        }
        $sum=0L
        $names=@()
        foreach ($id in $chosen) {
            if ($id -eq 'Papelera') { $sum += [long]$script:CleanResults[$id].Bytes; $names += 'Papelera (TODAS las unidades)' }
            else { $sum += [long]$script:CleanResults[$id].Bytes; $names += $id }
        }
        $warning = if ($chosen -contains 'Papelera') { "`n`nATENCION: al vaciar la Papelera, sus archivos no pueden restaurarse desde alli." } else { '' }
        $confirm = "Categorias: $($names -join ', ')`nEstimado: $(Format-CleanBytes $sum)`n`nSe eliminaran permanentemente los archivos seleccionados que sigan intactos. No se puede deshacer desde este programa.$warning`n`nContinuar?"
        $reply = [System.Windows.Forms.MessageBox]::Show($script:CleanDialog, $confirm, 'Confirmar limpieza permanente', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($reply -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        # Segunda confirmacion independiente para la operacion mas destructiva.
        if ($chosen -contains 'Papelera') {
            $second = [System.Windows.Forms.MessageBox]::Show($script:CleanDialog,
                'ULTIMA CONFIRMACION: vaciar TODA la Papelera del usuario actual en TODAS las unidades? La eliminacion es permanente.',
                'Confirmar vaciado de Papelera', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Stop)
            if ($second -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $script:CleanBusy=$true
        $script:CleanDialog.UseWaitCursor=$true
        $script:CleanBtnAnalyze.Enabled=$false
        $script:CleanBtnClean.Enabled=$false
        $script:CleanBtnRecommended.Enabled=$false
        $script:CleanStatus.Text='Limpiando solo las categorias confirmadas...'
        [System.Windows.Forms.Application]::DoEvents()
        $removed=0; $skipped=0; $estimated=0L; $notes=New-Object 'System.Collections.Generic.List[string]'
        try {
            foreach ($id in $chosen) {
                if ($id -eq 'Papelera') {
                    $code=[WRRecycleBin]::Empty($script:CleanDialog.Handle, $null, [uint32]7)
                    if ($code -eq 0) {
                        $removed += [long]$script:CleanResults['Papelera'].Count
                        $estimated += [long]$script:CleanResults['Papelera'].Bytes
                        $notes.Add('Papelera vaciada (cantidad estimada al analizar).')
                    } else { $notes.Add('Papelera: Windows no pudo completarlo (HRESULT ' + $code + ').') }
                } else {
                    $result=Invoke-CleanCandidates $script:CleanResults[$id]
                    $removed += $result.Removed
                    $estimated += $result.Bytes
                    $skipped += $result.Skipped
                    $notes.Add("$id`: $($result.Removed) eliminados, $($result.Skipped) omitidos.")
                }
            }
            $script:CleanStatus.Text="Limpieza finalizada: $removed elementos; estimado $(Format-CleanBytes $estimated)."
            $report="Limpieza terminada.`nElementos eliminados o vaciados: $removed`nTamano estimado procesado: $(Format-CleanBytes $estimated)`nOmitidos: $skipped`n`n" + ($notes -join "`n") + "`n`nVolvé a analizar para actualizar los valores."
            [System.Windows.Forms.MessageBox]::Show($script:CleanDialog, $report, 'Resultado de limpieza', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($script:CleanDialog, "Limpieza incompleta: $($_.Exception.Message). Volvé a analizar.", 'JUNO', 'OK', 'Warning') | Out-Null
        } finally {
            $script:CleanResults=@{}
            $script:CleanGrid.Rows.Clear()
            $script:CleanBusy=$false
            $script:CleanDialog.UseWaitCursor=$false
            $script:CleanBtnAnalyze.Enabled=$true
            $script:CleanBtnClean.Enabled=$true
            $script:CleanBtnRecommended.Enabled=$true
            $script:CleanStatus.Text='Para continuar, pulsa Analizar otra vez.'
        }
    })
    $btnClose.Add_Click({ if (-not $script:CleanBusy) { $script:CleanDialog.Close() } })
    try { [void]$dialog.ShowDialog($parent) }
    finally {
        $script:CleanDialog=$null
        $script:CleanBtnAnalyze=$null
        $script:CleanBtnClean=$null
        $script:CleanBtnRecommended=$null
        $script:CleanGrid=$null
        $script:CleanStatus=$null
        $script:CleanResults=@{}
        $script:CleanAnalyze=$null
        $script:CleanBusy=$false
        $dialog.Dispose()
    }
}
