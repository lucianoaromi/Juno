# JUNO v0.7.2 - Permisos persistentes de actividad en segundo plano.
# El manifiesto debe identificar UWP/AppContainer: MSIX no implica UWP.
# Utiliza la directiva oficial LetAppsRunInBackground_ForceDenyTheseApps
# (1703+, ediciones documentadas, todas las cuentas). Lectura del Registro no prueba eficacia.

$script:BPPPolicyPath = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:BPPDenyName = 'LetAppsRunInBackground_ForceDenyTheseApps'
$script:BPPAllowName = 'LetAppsRunInBackground_ForceAllowTheseApps'
$script:BPPGlobalName = 'LetAppsRunInBackground'
$script:BPPBackupPath = Join-Path $script:AppFolder 'background-policy.json'

function Test-BPPAdmin { return (Test-JunoAdmin) }
function Get-BPPEnvironment { return (Get-BPPEnvironmentInfo) }
function Read-BPPBackup {
    $data=Read-JunoStore 'Policy' 'Machine' $null
    if ($null -ne $data) { return $data }
    $legacy=Get-JunoMachineLegacy 'Policy'
    if ($null -ne $legacy) { return $legacy.Data }
    return [pscustomobject]@{Owned=@();MadeGlobal=$false}
}
function Write-BPPBackup($backup) { Write-JunoStore 'Policy' $backup 'Machine' }
function Get-BPPValues([Microsoft.Win32.RegistryKey]$key, [string]$name) {
    if ($null -eq $key -or -not ($key.GetValueNames() -contains $name)) { return ,([string[]]@()) }
    if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
        throw "El valor $name no tiene el tipo esperado REG_MULTI_SZ. No se modificara."
    }
    [string[]]$raw = $key.GetValue($name, [string[]]@())
    return ,([string[]]@($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
}
function Get-BPPPolicy {
    $state=Get-JunoPolicyState
    return [pscustomobject]@{Deny=@($state.Deny.Value | Where-Object {$null -ne $_});Allow=@($state.Allow.Value | Where-Object {$null -ne $_});HasGlobal=$state.Global.Exists;Global=$state.Global.Value}
}
function Get-BPPPackages { return @(Get-BPPPackageInventory) }
function Confirm-BPPWrite([bool]$restore=$false) {
    $environment=Get-BPPEnvironment
    if($restore){if(-not $environment.CanRestorePolicy){throw ('No se puede restaurar la directiva: '+$environment.Reason)}}
    elseif(-not $environment.CanWrite){throw ('No se puede solicitar la directiva: '+$environment.Reason)}
    $state=Get-BPPPolicy
    if($state.HasGlobal -and $state.Global -ne 0){throw 'Conflicto: una directiva general externa controla el segundo plano. Se conserva el respaldo.'}
    return $state
}
function Disable-BPPApps([string[]]$families) { Invoke-JunoPolicy $families $false }
function Restore-BPPApps([string[]]$families) { Invoke-JunoPolicy $families $true }
function Show-BackgroundPermissions([System.Windows.Forms.Form]$parent) {
    $dialog=New-Object Windows.Forms.Form
    if($null -ne $script:JunoIcon){$dialog.Icon=$script:JunoIcon}
    $dialog.Text='JUNO v0.8 | Permisos en segundo plano';$dialog.StartPosition='CenterParent'
    $dialog.ClientSize=New-Object Drawing.Size(990,695);$dialog.FormBorderStyle='FixedSingle';$dialog.MaximizeBox=$false
    $dialog.BackColor=[Drawing.Color]::FromArgb(22,26,34);$dialog.ForeColor=[Drawing.Color]::White;$dialog.Font=New-Object Drawing.Font('Segoe UI',10)
    $dialog.Controls.Add((New-Label '5. Permisos de aplicaciones en segundo plano' 20 12 950 32 18 $true $white))
    $dialog.Controls.Add((New-Label 'Directiva de equipo: edicion compatible y administrador. HKCU: solo restauracion de respaldos.' 22 51 948 24 10 $false $muted))
    $dialog.Controls.Add((New-Label 'Una escritura del Registro no demuestra restriccion efectiva. Aplicaciones de escritorio: gestion manual.' 22 77 946 24 9 $false $muted))
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Location=New-Object Drawing.Point(20,112);$grid.Size=New-Object Drawing.Size(950,352)
    $grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false
    $grid.AutoGenerateColumns=$false;$grid.MultiSelect=$false;$grid.SelectionMode='FullRowSelect'
    $grid.BackgroundColor=[Drawing.Color]::FromArgb(30,35,45);$grid.GridColor=[Drawing.Color]::FromArgb(65,72,86);$grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(47,59,77);$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White
    $grid.ColumnHeadersHeight=36;$grid.RowTemplate.Height=29;$grid.DefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(31,38,49)
    $grid.DefaultCellStyle.ForeColor=[Drawing.Color]::White;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(47,85,121)
    $grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::White;$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(38,45,57)
    $check=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$check.HeaderText='Elegir';$check.Width=50;[void]$grid.Columns.Add($check)
    foreach($info in @(@('Aplicacion',175),@('Tipo / compatibilidad',175),@('Configuracion / evidencia',205),@('Ambito / metodo',110),@('Identificador del paquete',230))){
        $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.HeaderText=$info[0];$column.Width=$info[1];$column.ReadOnly=$true;$column.SortMode='NotSortable';[void]$grid.Columns.Add($column)
    }
    $dialog.Controls.Add($grid)
    $status=New-Label 'Consultando inventario y respaldos; no se aplicaran cambios.' 22 473 944 50 9 $false $muted;$dialog.Controls.Add($status)
    $dialog.Controls.Add((New-Label 'Las entradas pendientes se conservan aunque la app no figure instalada. Eficacia: no verificada.' 22 526 944 24 9 $false $muted))
    $refresh=New-Button 'Actualizar lista' 20 562 295 36 $gray
    $request=New-Button 'Solicitar restriccion' 329 562 316 36 $blue
    $restore=New-Button 'Restaurar seleccionadas' 659 562 311 36 $green
    $settings=New-Button 'Abrir ajustes de Windows' 20 614 461 36 $gray
    $close=New-Button 'Cerrar' 495 614 475 36 $gray
    foreach($button in @($refresh,$request,$restore,$settings,$close)){$dialog.Controls.Add($button)}
    $request.Enabled=$false;$restore.Enabled=$false
    $context=[pscustomobject]@{Reloading=$false;View=$null}
    $selected={
        [void]$grid.EndEdit()
        return @($grid.Rows|Where-Object{[bool]$_.Cells[0].Value -and $null -ne $_.Tag}|ForEach-Object{$_.Tag})
    }
    $update={
        if($context.Reloading){return}
        $actions=Get-BPPSelectionActions @(& $selected)
        $request.Enabled=$actions.Request;$restore.Enabled=$actions.Restore
    }
    $reload={
        $context.Reloading=$true
        try{
            $grid.Rows.Clear();$request.Enabled=$false;$restore.Enabled=$false
            $context.View=Get-BPPPermissionView
            foreach($entry in $context.View.Rows){
                $index=$grid.Rows.Add();$row=$grid.Rows[$index];$row.Tag=$entry;$row.Cells[0].Value=$false
                $row.Cells[1].Value=$entry.Name;$row.Cells[2].Value=$entry.Type+' / '+$entry.Classification
                $row.Cells[3].Value=$entry.Configuration;$row.Cells[4].Value=$entry.Method;$row.Cells[5].Value=$entry.Family
                $row.Cells[0].ReadOnly=(-not $entry.CanRequest -and -not $entry.CanRestore)
                foreach($cell in $row.Cells){$cell.ToolTipText=$entry.Reason+' Solicitud: '+$entry.Requested+' | Reconocimiento de politica y restriccion efectiva: no verificados.'}
                if($row.Cells[0].ReadOnly){$row.Cells[0].Style.BackColor=[Drawing.Color]::FromArgb(53,53,57);$row.Cells[0].Style.SelectionBackColor=[Drawing.Color]::FromArgb(53,53,57)}
            }
            $grid.ClearSelection()
            $status.Text=$context.View.Environment.Reason+' Entradas: '+$context.View.Rows.Count+'. '+($context.View.Errors -join ' ')
        }finally{$context.Reloading=$false}
        & $update
    }
    $act={
        param($action)
        $entries=@(& $selected);$actions=Get-BPPSelectionActions $entries
        if(-not $actions.$action){return}
        if(-not(Confirm-BPPAction $action $entries.Count)){return}
        try{$message=Invoke-BPPSelection $action $entries $true;[void][Windows.Forms.MessageBox]::Show($dialog,$message,'Resultado de configuracion')}
        catch{[void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Operacion pendiente o fallida','OK','Warning')}
        finally{try{& $reload}catch{$status.Text=$_.Exception.Message}}
    }
    $grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){[void]$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)}})
    $grid.Add_CellValueChanged({& $update})
    $grid.Add_SelectionChanged({if(-not $context.Reloading -and $grid.SelectedRows.Count -eq 1 -and $null -ne $grid.SelectedRows[0].Tag){$entry=$grid.SelectedRows[0].Tag;$status.Text=$entry.Classification+': '+$entry.Reason}})
    $refresh.Add_Click({try{& $reload}catch{$status.Text='Error de lectura: '+$_.Exception.Message}})
    $request.Add_Click({& $act 'Request'});$restore.Add_Click({& $act 'Restore'})
    $settings.Add_Click({try{$family='';if($grid.SelectedRows.Count -eq 1){$family=$grid.SelectedRows[0].Tag.Family};Open-BPPSettings $family}catch{$status.Text='No se pudo abrir Ajustes: '+$_.Exception.Message}})
    $close.Add_Click({$dialog.Close()})
    Initialize-JunoWindow $dialog $parent
    try{& $reload;[void]$dialog.ShowDialog($parent)}finally{$dialog.Dispose()}
}
