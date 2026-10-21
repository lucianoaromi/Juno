# JUNO: interfaz clásica; motor compartido con la interfaz moderna.
. (Join-Path $PSScriptRoot 'StartupOperations.ps1')

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

    $lblStatus = New-Label 'Leyendo programas de inicio...' 22 422 963 28 10 $false $muted
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
    $btnRefresh.Add_Click({try {& $script:StartupRefresh}catch {$script:StartupStatus.Text='Error de lectura; lista incompleta: '+$_.Exception.Message}})
    $btnTaskmgr.Add_Click({try {Start-Process (Get-JunoSystemTool 'taskmgr.exe')}catch {$script:StartupStatus.Text=$_.Exception.Message}})
    $btnSettings.Add_Click({
        try { Start-Process 'ms-settings:startupapps' }
        catch { [System.Windows.Forms.MessageBox]::Show($script:StartupDialog, 'No se pudo abrir Configuracion de inicio.') | Out-Null }
    })
    $btnClose.Add_Click({ $script:StartupDialog.Close() })
    Initialize-JunoWindow $dialog $parent
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
