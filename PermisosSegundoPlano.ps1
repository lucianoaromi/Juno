# JUNO v0.7.2 - Permisos persistentes de actividad en segundo plano.
# Solo apps empaquetadas compatibles (MSIX / UWP); NO procesa aplicaciones Win32.
# Utiliza la directiva oficial LetAppsRunInBackground_ForceDenyTheseApps
# (Windows Pro/Enterprise/Education, todas las cuentas). NO modifica servicios.

$script:BPPPolicyPath = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:BPPDenyName = 'LetAppsRunInBackground_ForceDenyTheseApps'
$script:BPPAllowName = 'LetAppsRunInBackground_ForceAllowTheseApps'
$script:BPPGlobalName = 'LetAppsRunInBackground'
$script:BPPBackupPath = Join-Path $script:AppFolder 'background-policy.json'

function Test-BPPAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-BPPEnvironment {
    $current = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $edition = [string]$current.EditionID
    $supported = $edition -match '^(Professional|Enterprise|Education|IoTEnterprise)'
    $joined = $false
    try { $joined = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain }
    catch { $joined = $true } # Fail closed para evitar modificar una maquina administrada.
    return [pscustomobject]@{
        Edition=$edition; Supported=$supported; Admin=[bool](Test-BPPAdmin); Domain=$joined
        CanWrite=($supported -and -not $joined -and [bool](Test-BPPAdmin))
    }
}
function Read-BPPBackup {
    if (-not (Test-Path -LiteralPath $script:BPPBackupPath)) {
        return [pscustomobject]@{ Owned=@(); MadeGlobal=$false }
    }
    $obj = Get-Content -LiteralPath $script:BPPBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'Owned')) { throw 'Respaldo de permisos no valido; no se modificaran directivas.' }
    if (-not ($obj.PSObject.Properties.Name -contains 'MadeGlobal')) { throw 'Respaldo incompleto; no se modificaran directivas.' }
    return $obj
}
function Write-BPPBackup($backup) {
    if (-not (Test-Path -LiteralPath $script:AppFolder)) {
        New-Item -Path $script:AppFolder -ItemType Directory -Force | Out-Null
    }
    $tmp = "$($script:BPPBackupPath).tmp"
    try {
        $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:BPPBackupPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
function Get-BPPValues([Microsoft.Win32.RegistryKey]$key, [string]$name) {
    if ($null -eq $key -or -not ($key.GetValueNames() -contains $name)) { return ,([string[]]@()) }
    if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
        throw "El valor $name no tiene el tipo esperado REG_MULTI_SZ. No se modificara."
    }
    [string[]]$raw = $key.GetValue($name, [string[]]@())
    return ,([string[]]@($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
}
function Get-BPPPolicy {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:BPPPolicyPath, $false)
    try {
        $deny = Get-BPPValues $key $script:BPPDenyName
        $allow = Get-BPPValues $key $script:BPPAllowName
        $hasGlobal = ($null -ne $key -and ($key.GetValueNames() -contains $script:BPPGlobalName))
        $global = $null
        if ($hasGlobal) {
            if ($key.GetValueKind($script:BPPGlobalName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
                throw 'Directiva general con tipo inesperado; no se modificara.'
            }
            $global = [int]$key.GetValue($script:BPPGlobalName)
        }
        return [pscustomobject]@{ Deny=@($deny); Allow=@($allow); HasGlobal=$hasGlobal; Global=$global }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Get-BPPPackages {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $packages = @(Get-AppxPackage -ErrorAction Stop)
    foreach ($p in $packages) {
        $name = [string]$p.Name
        $family = [string]$p.PackageFamilyName
        $location = [string]$p.InstallLocation
        if ([string]::IsNullOrWhiteSpace($family) -or $seen.ContainsKey($family)) { continue }
        $seen[$family] = $true
        $properties = @($p.PSObject.Properties.Name)
        if ((($properties -contains 'IsFramework') -and [bool]$p.IsFramework) -or
            (($properties -contains 'IsResourcePackage') -and [bool]$p.IsResourcePackage) -or
            (($properties -contains 'IsBundle') -and [bool]$p.IsBundle)) { continue }
        if (($p.PSObject.Properties.Name -contains 'NonRemovable') -and [bool]$p.NonRemovable) { continue }
        if ($location.StartsWith($env:WINDIR, [StringComparison]::OrdinalIgnoreCase)) { continue }
        # Excluir componentes de shell, identidad, seguridad, instalacion y plataformas de Windows.
        if ($name -match '^(Microsoft\.Windows|Microsoft\.AAD|Microsoft\.Account|Microsoft\.UI\.|Microsoft\.VCLibs|Microsoft\.NET\.|Microsoft\.Services\.Store|Microsoft\.DesktopAppInstaller|Microsoft\.StorePurchaseApp|Microsoft\.SecHealth|Windows\.|Microsoft\.XboxIdentityProvider)') { continue }
        $list.Add([pscustomobject]@{ Name=$name; Family=$family })
    }
    return @($list.ToArray() | Sort-Object Name)
}
function Confirm-BPPWrite {
    $envInfo = Get-BPPEnvironment
    if (-not $envInfo.Supported) { throw "Esta edicion ($($envInfo.Edition)) no admite esta directiva. Usa Configuracion de Windows." }
    if ($envInfo.Domain) { throw 'Equipo administrado o no se pudo verificar el dominio; no se tocan sus directivas.' }
    if (-not $envInfo.Admin) { throw 'Esta funcion necesita abrir JUNO como administrador.' }
    $state = Get-BPPPolicy
    if ($state.HasGlobal -and $state.Global -ne 0) {
        throw 'Una directiva general de otra configuracion ya gobierna el segundo plano. No se modificara.'
    }
    return $state
}
function Disable-BPPApps([string[]]$families) {
    if ($families.Count -eq 0) { return 'No hay aplicaciones seleccionadas.' }
    $state = Confirm-BPPWrite
    $own = Read-BPPBackup
    $valid = @(Get-BPPPackages | ForEach-Object { $_.Family })
    $toAdd = New-Object 'System.Collections.Generic.List[string]'
    foreach ($family in @($families | Select-Object -Unique)) {
        if ($valid -notcontains $family) { throw "La aplicacion ya no esta instalada o es un componente protegido: $family" }
        if ($state.Allow -contains $family) { throw "Existe una directiva de permiso previa para: $family. No se modificara." }
        if ($state.Deny -contains $family) { continue }
        $toAdd.Add($family)
    }
    if ($toAdd.Count -eq 0) { return 'Las aplicaciones elegidas ya estaban bloqueadas por otra directiva.' }
    # Registrar propiedad ANTES de escribir, para poder recuperar cambios tras un cierre inesperado.
    $oldOwned = @($own.Owned)
    $own.Owned = @($oldOwned + $toAdd.ToArray() | Select-Object -Unique)
    if (-not $state.HasGlobal) { $own.MadeGlobal = $true }
    Write-BPPBackup $own
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($script:BPPPolicyPath)
    if ($null -eq $key) { throw 'Windows no permitio abrir la directiva.' }
    try {
        if (-not $state.HasGlobal) {
            $key.SetValue($script:BPPGlobalName, [int]0, [Microsoft.Win32.RegistryValueKind]::DWord)
        }
        [string[]]$combined = @($state.Deny + $toAdd.ToArray() | Select-Object -Unique)
        $key.SetValue($script:BPPDenyName, $combined, [Microsoft.Win32.RegistryValueKind]::MultiString)
    } finally { $key.Dispose() }
    $after = Get-BPPPolicy
    foreach ($family in $toAdd) {
        if ($after.Deny -notcontains $family) { throw "No se pudo comprobar el bloqueo de $family." }
    }
    return "Bloqueo registrado para $($toAdd.Count) app(s). Se aplica a todas las cuentas del equipo. Reinicia las aplicaciones o cierra sesion para aplicar los permisos."
}
function Restore-BPPApps([string[]]$families) {
    if ($families.Count -eq 0) { return 'No hay aplicaciones seleccionadas.' }
    $state = Confirm-BPPWrite
    $own = Read-BPPBackup
    $toRemove = @($families | Where-Object { @($own.Owned) -contains $_ } | Select-Object -Unique)
    if ($toRemove.Count -eq 0) { return 'No hay bloqueos de JUNO seleccionados.' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:BPPPolicyPath, $true)
    if ($null -eq $key) { throw 'No se pudo abrir la directiva para restaurar.' }
    try {
        [string[]]$remainingDeny = @($state.Deny | Where-Object { $toRemove -notcontains $_ })
        if ($remainingDeny.Count -eq 0) {
            if ($key.GetValueNames() -contains $script:BPPDenyName) { $key.DeleteValue($script:BPPDenyName, $false) }
        } else {
            $key.SetValue($script:BPPDenyName, $remainingDeny, [Microsoft.Win32.RegistryValueKind]::MultiString)
        }
        # Solo revertimos la directiva general si la creo esta aplicacion y
        # no hay otra lista de permisos que necesite el valor 0.
        $stillOwned = @($own.Owned | Where-Object { $toRemove -notcontains $_ })
        if ($stillOwned.Count -eq 0 -and [bool]$own.MadeGlobal -and $remainingDeny.Count -eq 0 -and $state.Allow.Count -eq 0) {
            if (($key.GetValueNames() -contains $script:BPPGlobalName) -and [int]$key.GetValue($script:BPPGlobalName) -eq 0) {
                $key.DeleteValue($script:BPPGlobalName, $false)
            }
            $own.MadeGlobal = $false
        }
    } finally { $key.Dispose() }
    $after = Get-BPPPolicy
    foreach ($family in $toRemove) {
        if ($after.Deny -contains $family) { throw "No se pudo verificar la restauracion de $family." }
    }
    $own.Owned = @($own.Owned | Where-Object { $toRemove -notcontains $_ })
    Write-BPPBackup $own
    return "Restauradas $($toRemove.Count) app(s). Se quitaron SOLO los bloqueos creados por JUNO."
}
function Show-BackgroundPermissions([System.Windows.Forms.Form]$parent) {
    $envInfo = Get-BPPEnvironment
    # En Pro/Enterprise/Education + administrador: usar directiva documentada.
    # En Home o sin admin: control POR USUARIO solamente para claves existentes.
    $mode = if ($envInfo.Supported -and $envInfo.Admin -and -not $envInfo.Domain) { 'Policy' } else { 'User' }
    $dialog = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dialog.Icon = $script:JunoIcon }
    $dialog.Text = 'JUNO v0.8 | Permisos en segundo plano'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(990, 695)
    $dialog.FormBorderStyle = 'FixedSingle'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = [Drawing.Color]::FromArgb(22,26,34)
    $dialog.ForeColor = [Drawing.Color]::White
    $dialog.Font = New-Object Drawing.Font('Segoe UI',10)
    $dialog.Controls.Add((New-Label '7. Permisos de aplicaciones en segundo plano' 20 12 950 32 18 $true $white))
    $explain = if ($mode -eq 'Policy') { 'Modo directiva (equipo): bloquea apps empaquetadas seleccionadas; afecta a TODAS las cuentas.' }
               else { 'Modo usuario (Home incluido): cambia permisos del Registro del usuario para apps compatibles.' }
    $dialog.Controls.Add((New-Label $explain 22 51 948 24 10 $false $muted))
    $dialog.Controls.Add((New-Label 'Windows 11 puede ignorar los cambios de Registro. Comproba el estado real en Ajustes > Opciones avanzadas.' 22 77 946 24 9 $false $muted))

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Location = New-Object Drawing.Point(20,112)
    $grid.Size = New-Object Drawing.Size(950,352)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.BackgroundColor = [Drawing.Color]::FromArgb(30,35,45)
    $grid.GridColor = [Drawing.Color]::FromArgb(65,72,86)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(47,59,77)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White
    $grid.ColumnHeadersHeight = 36
    $grid.RowTemplate.Height = 29
    $grid.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(31,38,49)
    $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(47,85,121)
    $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(38,45,57)
    $c = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $c.HeaderText = 'Elegir'; $c.Width = 70
    [void]$grid.Columns.Add($c)
    foreach ($info in @(@('Aplicacion',295),@('Permiso / Estado',260),@('Identificador del paquete',314))) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = [string]$info[0]; $col.Width = [int]$info[1]
        $col.SortMode = 'NotSortable'; $col.ReadOnly = $true
        [void]$grid.Columns.Add($col)
    }
    $dialog.Controls.Add($grid)
    $modeInfo = if ($mode -eq 'Policy') { 'Directiva oficial de equipo: requiere admin; afecta a todas las cuentas.' }
                else { 'Modo usuario: no requiere admin; necesita clave de permiso existente. Windows 11: revisar en Ajustes.' }
    $status = New-Label $modeInfo 22 473 944 56 10 $false $muted
    $dialog.Controls.Add($status)
    $note = New-Label 'Casilla gris: Windows no expone una clave individual; abrila desde Ajustes. Ningun cambio es automatico.' 22 526 944 24 9 $false $muted
    $dialog.Controls.Add($note)
    $btnRefresh = New-Button 'Actualizar lista' 20 562 295 36 $gray
    $btnBlock = New-Button 'Bloquear seleccionadas' 329 562 316 36 $blue
    $btnRestore = New-Button 'Restaurar seleccionadas' 659 562 311 36 $green
    $btnSettings = New-Button 'Abrir ajustes de Windows' 20 614 461 36 $gray
    $btnClose = New-Button 'Cerrar' 495 614 475 36 $gray
    foreach ($b in @($btnRefresh,$btnBlock,$btnRestore,$btnSettings,$btnClose)) { $dialog.Controls.Add($b) }
    $btnBlock.Enabled = $false
    $btnRestore.Enabled = $false
    $script:BPPReloading = $false
    $canWrite = -not $envInfo.Domain
    $ctx = [pscustomobject]@{ Policy=$null; PolicyBackup=$null; UserBackup=$null; AllApps=@() }

    $updateButtons = {
        if ($script:BPPReloading) { return }
        $blockable = $false; $restorable = $false
        foreach ($r in $grid.Rows) {
            if (-not [bool]$r.Cells[0].Value -or $null -eq $r.Tag) { continue }
            if ($r.Cells[0].ReadOnly) { continue }
            $family = [string]$r.Tag.Family
            if ($mode -eq 'Policy') {
                if ($ctx.Policy.Deny -contains $family) {
                    if (@($ctx.PolicyBackup.Owned) -contains $family) { $restorable = $true }
                } else { $blockable = $true }
            } else {
                $saved = @($ctx.UserBackup.Items | Where-Object { $_.Family -eq $family } | Select-Object -First 1)
                $owned = $saved.Count -gt 0
                if ($owned) {
                    $restorable = $true
                    if (Test-BPUApplyPending $saved[0]) { $blockable = $true }
                }
                else { $blockable = $true }
            }
        }
        $btnBlock.Enabled = $canWrite -and $blockable
        $btnRestore.Enabled = $canWrite -and $restorable
    }
    $reload = {
        $script:BPPReloading = $true
        try {
            $grid.Rows.Clear()
            $ctx.Policy = Get-BPPPolicy
            $ctx.PolicyBackup = if ($mode -eq 'Policy') { Read-BPPBackup } else { [pscustomobject]@{ Owned=@() } }
            $ctx.UserBackup = Get-BPUBackup
            $ctx.AllApps = @(Get-BPPPackages)
            $glob = Get-BPUGlobal
            $policyBusy = ($ctx.Policy.HasGlobal -and $ctx.Policy.Global -ne 0)
            foreach ($app in $ctx.AllApps) {
                $idx = $grid.Rows.Add()
                $row = $grid.Rows[$idx]
                $row.Tag = $app
                $row.Cells[0].Value = $false
                $row.Cells[1].Value = $app.Name
                if ($mode -eq 'Policy') {
                    $prior = $ctx.Policy.Deny -contains $app.Family
                    $owned = @($ctx.PolicyBackup.Owned) -contains $app.Family
                    $row.Cells[2].Value = if ($prior) { if ($owned) { 'Bloqueada por JUNO' } else { 'Bloqueada previamente' } } else { 'Sin bloqueo por directiva' }
                    $row.Cells[0].ReadOnly = (-not $canWrite) -or $policyBusy -or ($prior -and -not $owned) -or ($ctx.Policy.Allow -contains $app.Family)
                } else {
                    $s = Get-BPUState $app.Family
                    $owned = @($ctx.UserBackup.Items | Where-Object { $_.Family -eq $app.Family }).Count -gt 0
                    $row.Cells[2].Value = if (-not $s.Available) { 'No configurable desde este modulo' }
                        elseif ($owned) { 'Registro: cambio respaldado; verificar' }
                        elseif ($s.IsOff) { 'Ya desactivada en Registro' }
                        else { 'Registro: sin bloqueo individual' }
                    $row.Cells[0].ReadOnly = (-not $canWrite) -or $policyBusy -or ($glob -eq 1) -or (-not $s.Available) -or ($s.IsOff -and -not $owned) -or ($ctx.Policy.Deny -contains $app.Family) -or ($ctx.Policy.Allow -contains $app.Family)
                }
                if ($row.Cells[0].ReadOnly) {
                    $row.Cells[0].Style.BackColor = [Drawing.Color]::FromArgb(53,53,57)
                    $row.Cells[0].Style.SelectionBackColor = [Drawing.Color]::FromArgb(53,53,57)
                }
                $row.Cells[3].Value = $app.Family
            }
            $grid.ClearSelection()
            $status.Text = if ($envInfo.Domain) { 'Equipo administrado: solo lectura para evitar interferir con politicas externas.' }
                elseif ($policyBusy) { 'Ya existe una directiva general que prevalece: los cambios individuales estan deshabilitados.' }
                elseif ($mode -eq 'User' -and $glob -eq 1) { 'El bloqueo global del usuario ya esta activo. No es necesario bloquear apps individualmente.' }
                else { "$modeInfo | Apps detectadas: $($ctx.AllApps.Count)" }
        } finally { $script:BPPReloading = $false }
        & $updateButtons
    }
    $selected = {
        [void]$grid.EndEdit()
        $result = New-Object 'System.Collections.Generic.List[string]'
        foreach ($r in $grid.Rows) {
            if (-not $r.Cells[0].ReadOnly -and [bool]$r.Cells[0].Value) { $result.Add([string]$r.Tag.Family) }
        }
        return ,([string[]]$result.ToArray())
    }
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $grid.Add_CellValueChanged({ & $updateButtons })
    $btnRefresh.Add_Click({
        try { & $reload } catch { [Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Error de lectura') | Out-Null }
    })
    $btnBlock.Add_Click({
        [string[]]$names = & $selected
        if ($names.Count -eq 0) { return }
        $description = if ($mode -eq 'Policy') { 'Es una DIRECTIVA para todas las cuentas, no toca apps de escritorio.' }
                       else { 'Modifica SOLO el Registro de este usuario. En Windows 11 NO garantiza que el sistema aplique Nunca.' }
        if ([Windows.Forms.MessageBox]::Show($dialog,
            "Registrar bloqueo para $($names.Count) app(s)?`n`n$description`n`nPuede reducir notificaciones y sincronizacion. Podes revertir los valores guardados.",
            'Confirmar cambios', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning) -ne [Windows.Forms.DialogResult]::Yes) { return }
        try {
            $out = if ($mode -eq 'Policy') { Disable-BPPApps $names } else { Disable-BPUApps $names }
            & $reload
            [Windows.Forms.MessageBox]::Show($dialog, $out, 'Resultado') | Out-Null
        } catch {
            [Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'No se pudo aplicar', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            try { & $reload } catch { }
        }
    })
    $btnRestore.Add_Click({
        [string[]]$names = & $selected
        if ($names.Count -eq 0) { return }
        if ([Windows.Forms.MessageBox]::Show($dialog,
            "Restaurar la configuracion anterior de $($names.Count) app(s) seleccionadas?`nSolo se restauran los cambios respaldados por JUNO.",
            'Confirmar restauracion', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question) -ne [Windows.Forms.DialogResult]::Yes) { return }
        try {
            $out = if ($mode -eq 'Policy') { Restore-BPPApps $names } else { Restore-BPUApps $names }
            & $reload
            [Windows.Forms.MessageBox]::Show($dialog, $out, 'Restauracion') | Out-Null
        } catch {
            [Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Error al restaurar', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            try { & $reload } catch { }
        }
    })
    $btnSettings.Add_Click({
        try { Start-Process (Get-BgSettingsUri) }
        catch { [Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Ajustes') | Out-Null }
    })
    $btnClose.Add_Click({ $dialog.Close() })
    try { & $reload; [void]$dialog.ShowDialog($parent) }
    finally { $dialog.Dispose() }
}
