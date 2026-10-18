# JUNO 0.8.1 - Diagnostico y revision de limpieza en Windows.
# Ninguna primitiva de borrado. Las comprobaciones de rutas NO son atomicas.
$cleanupNative = @'
using System;
using System.Runtime.InteropServices;
public static class JunoCleanupRecycleBin {
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    public struct Info32 { public UInt32 cbSize; public Int64 i64Size; public Int64 i64NumItems; }
    [StructLayout(LayoutKind.Sequential, Pack=8)]
    public struct Info64 { public UInt32 cbSize; public Int64 i64Size; public Int64 i64NumItems; }
    [DllImport("shell32.dll", EntryPoint="SHQueryRecycleBinW", CharSet=CharSet.Unicode)]
    public static extern int Query32(string drive, ref Info32 info);
    [DllImport("shell32.dll", EntryPoint="SHQueryRecycleBinW", CharSet=CharSet.Unicode)]
    public static extern int Query64(string drive, ref Info64 info);
}
'@
if (-not ('JunoCleanupRecycleBin' -as [type])) { Add-Type -TypeDefinition $cleanupNative }

function Format-CleanBytes([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}
function Test-CleanupIsAdmin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-CleanupSpecs {
    $local=[Environment]::GetFolderPath('LocalApplicationData')
    $windows=[Environment]::GetFolderPath('Windows')
    if (-not $local -or -not $windows) { throw 'No se pudieron determinar las carpetas de Windows.' }
    # Reglas de INVENTARIO. Ni la extension ni la antiguedad autorizan borrados.
    return @(
        [pscustomobject]@{Id='Usuario';Name='Temporales del usuario';Root=(Join-Path $local 'Temp');Days=7;Pattern='(?i)^[^\\/:]+\.tmp$';Action='Storage'},
        [pscustomobject]@{Id='Windows';Name='Temporales de Windows';Root=(Join-Path $windows 'Temp');Days=14;Pattern='(?i)^[^\\/:]+\.tmp$';Action='Storage'},
        [pscustomobject]@{Id='Miniaturas';Name='Cache de miniaturas';Root=(Join-Path $local 'Microsoft\Windows\Explorer');Days=7;Pattern='(?i)^thumbcache_(\d+|idx|sr|wide|custom_stream)\.db$';Action='DiskCleanup'},
        [pscustomobject]@{Id='Papelera';Name='Papelera de reciclaje';Root=$null;Days=0;Pattern='';Action='RecycleBin'}
    )
}
function Get-CleanupSpec([string]$id) {
    $found=@(Get-CleanupSpecs | Where-Object { $_.Id -ceq $id })
    if ($found.Count -ne 1) { throw 'Categoria de limpieza no permitida.' }
    return $found[0]
}
function Get-CleanErrorReason($exception) {
    while ($null -ne $exception.InnerException) { $exception=$exception.InnerException }
    $code=$exception.HResult -band 0xffff
    if ($exception -is [UnauthorizedAccessException] -or $code -eq 5) { return 'AccessDenied' }
    if ($code -in @(2,3)) { return 'Missing' }
    if ($code -in @(32,33)) { return 'InUse' }
    return 'IOError'
}
function Get-CleanAttributes([string]$path) { return [IO.File]::GetAttributes($path) }
function Get-CleanPathStatus([string]$path,[string]$root,[bool]$allowRoot=$false,[bool]$allowMissing=$false) {
    try {
        foreach ($text in @($path,$root)) {
            if (-not $text -or $text -notmatch '^[A-Za-z]:\\' -or $text.Substring(2).Contains(':') -or
                $text -match '(^|[\\/])\.{1,2}([\\/]|$)') { return [pscustomobject]@{Allowed=$false;Reason='InvalidPath'} }
        }
        $base=[IO.Path]::GetFullPath($root).TrimEnd('\')
        $full=[IO.Path]::GetFullPath($path).TrimEnd('\')
        if (-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase) -and
            -not ($allowRoot -and $full.Equals($base,[StringComparison]::OrdinalIgnoreCase))) {
            return [pscustomobject]@{Allowed=$false;Reason='OutOfScope'}
        }
        # Comprobar tambien antecesores de la raiz, hasta la raiz del volumen.
        $cursor=$full
        while ($cursor) {
            try {
                if (((Get-CleanAttributes $cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return [pscustomobject]@{Allowed=$false;Reason='ReparsePoint'}
                }
            } catch {
                $reason=Get-CleanErrorReason $_.Exception
                if (-not ($allowMissing -and $reason -eq 'Missing')) { return [pscustomobject]@{Allowed=$false;Reason=$reason} }
            }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
        return [pscustomobject]@{Allowed=$true;Reason='CheckedSnapshot'}
    } catch { return [pscustomobject]@{Allowed=$false;Reason=(Get-CleanErrorReason $_.Exception)} }
}
function Test-CleanPath([string]$path,[string]$root) { return (Get-CleanPathStatus $path $root).Allowed }
function Open-CleanProbe([string]$path) {
    return [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
}
function Get-CleanCandidateStatus($candidate,$spec,[bool]$revalidate=$false) {
    $check=Get-CleanPathStatus ([string]$candidate.Path) ([string]$spec.Root)
    if (-not $check.Allowed) { return [pscustomobject]@{Status=$(if($check.Reason -in @('AccessDenied','IOError')){'Failed'}else{'Skipped'});Reason=$check.Reason;File=$null} }
    $probe=$null
    try {
        $file=[IO.FileInfo]::new([string]$candidate.Path); $file.Refresh()
        if (($file.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $reason='DirectoryNotInspected' }
        elseif (($file.Attributes -band ([IO.FileAttributes]::System -bor [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { $reason='ProtectedAttributes' }
        elseif ($file.Name -notmatch $spec.Pattern) { $reason='UnknownContent' }
        elseif ($revalidate -and ($file.Length -ne [long]$candidate.Length -or
            $file.LastWriteTimeUtc.Ticks -ne [long]$candidate.LastWriteUtc -or
            $file.CreationTimeUtc.Ticks -ne [long]$candidate.CreationUtc -or
            [int]$file.Attributes -ne [int]$candidate.Attributes)) { $reason='Changed' }
        elseif ($file.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-$spec.Days) -or $file.CreationTimeUtc -ge [DateTime]::UtcNow.AddDays(-$spec.Days)) { $reason='TooRecent' }
        else { $reason='' }
        if ($reason) { return [pscustomobject]@{Status='Skipped';Reason=$reason;File=$null} }
        $probe=Open-CleanProbe $file.FullName
        if ($probe.Length -ne $file.Length) { return [pscustomobject]@{Status='Skipped';Reason='Changed';File=$null} }
        return [pscustomobject]@{Status='Listed';Reason='DiagnosticOnly';File=[pscustomobject]@{
            Path=$file.FullName;Length=[long]$file.Length;LastWriteUtc=$file.LastWriteTimeUtc.Ticks
            CreationUtc=$file.CreationTimeUtc.Ticks;Attributes=[int]$file.Attributes
        }}
    } catch {
        $reason=Get-CleanErrorReason $_.Exception
        return [pscustomobject]@{Status=$(if($reason -in @('Missing','InUse')){'Skipped'}else{'Failed'});Reason=$reason;File=$null}
    } finally { if ($null -ne $probe) { $probe.Dispose() } }
}
function Scan-CleanFolder([string]$category,[int]$limit=5000) {
    $spec=Get-CleanupSpec $category
    if (-not $spec.Root -or $limit -lt 1 -or $limit -gt 5000) { throw 'Ambito o limite de analisis no permitido.' }
    $result=[pscustomobject]@{Id=$category;Root=$spec.Root;Files=@();Count=0;Bytes=0L;Skipped=0;Failed=0;Records=@();Truncated=$false;Available=$false;CanDelete=$false;Note=''}
    $rootCheck=Get-CleanPathStatus $spec.Root $spec.Root $true
    if (-not $rootCheck.Allowed) {
        $result.Note=$rootCheck.Reason; $result.Failed=1
        $result.Records=@([pscustomobject]@{Path=$spec.Root;Status='Failed';Reason=$rootCheck.Reason})
        return $result
    }
    $result.Available=$true
    $files=New-Object 'System.Collections.Generic.List[object]'
    $records=New-Object 'System.Collections.Generic.List[object]'
    $inspected=0
    try {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($spec.Root)) {
            $inspected++
            if ($inspected -gt $limit) { $result.Truncated=$true; break }
            $candidate=Get-CleanCandidateStatus ([pscustomobject]@{Path=$path}) $spec
            $records.Add([pscustomobject]@{Path=$path;Status=$candidate.Status;Reason=$candidate.Reason})
            if ($candidate.Status -eq 'Listed') { $files.Add($candidate.File); $result.Bytes += $candidate.File.Length }
            elseif ($candidate.Status -eq 'Failed') { $result.Failed++ }
            else { $result.Skipped++ }
        }
    } catch {
        $result.Failed++; $records.Add([pscustomobject]@{Path=$spec.Root;Status='Failed';Reason=(Get-CleanErrorReason $_.Exception)})
    }
    $result.Files=$files.ToArray(); $result.Records=$records.ToArray(); $result.Count=$files.Count
    $result.Note="Solo diagnostico, sin recursion | omitidos: $($result.Skipped), fallidos: $($result.Failed)"
    if ($result.Truncated) { $result.Note='PARCIAL: limite de entradas alcanzado. '+$result.Note }
    return $result
}
function Get-RecycleBinEstimate {
    if ([IntPtr]::Size -eq 4) {
        $info=New-Object JunoCleanupRecycleBin+Info32
        $info.cbSize=[uint32][Runtime.InteropServices.Marshal]::SizeOf([type][JunoCleanupRecycleBin+Info32])
        $code=[JunoCleanupRecycleBin]::Query32($null,[ref]$info)
    } else {
        $info=New-Object JunoCleanupRecycleBin+Info64
        $info.cbSize=[uint32][Runtime.InteropServices.Marshal]::SizeOf([type][JunoCleanupRecycleBin+Info64])
        $code=[JunoCleanupRecycleBin]::Query64($null,[ref]$info)
    }
    if ($code -ne 0 -or $info.i64Size -lt 0 -or $info.i64NumItems -lt 0) { throw 'No se pudo consultar la Papelera.' }
    return [pscustomobject]@{Id='Papelera';Root=$null;Available=$true;Files=@();Records=@();Count=[long]$info.i64NumItems;Bytes=[long]$info.i64Size;Failed=0;Skipped=0;CanDelete=$false;Note='Instantanea de todas las unidades; revisar contenido actual en Windows'}
}
function Invoke-CleanCandidates($result,[bool]$confirmed=$false) {
    # Barrera para llamadas antiguas: JAMAS elimina, aun confirmada.
    $report=[pscustomobject]@{Removed=0;Bytes=0L;RecoveredBytes=$null;Skipped=0;Failed=0;Records=@();Status='DiagnosticOnly'}
    if (-not $confirmed) { $report.Status='Cancelled'; return $report }
    $spec=Get-CleanupSpec ([string]$result.Id)
    if (-not $spec.Root -or -not ([string]$result.Root).Equals([string]$spec.Root,[StringComparison]::OrdinalIgnoreCase)) { throw 'El analisis no pertenece al ambito autorizado.' }
    foreach ($file in $result.Files) {
        $check=Get-CleanCandidateStatus $file $spec $true
        $status=if($check.Status -eq 'Listed'){'Skipped'}else{$check.Status}
        $report.Records += [pscustomobject]@{Category=$spec.Id;Path=$file.Path;Status=$status;Reason=$check.Reason}
        if ($status -eq 'Failed') { $report.Failed++ } else { $report.Skipped++ }
    }
    return $report
}
function Get-CleanupLogRoot { return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinRendimiento\logs\cleanup') }
function Write-CleanupLog($report) {
    if (Test-CleanupIsAdmin) { throw 'No se escriben registros en el perfil desde un proceso elevado.' }
    $root=Get-CleanupLogRoot
    foreach ($spec in Get-CleanupSpecs) {
        if ($spec.Root) {
            $base=[IO.Path]::GetFullPath($spec.Root).TrimEnd('\'); $full=[IO.Path]::GetFullPath($root)
            if ($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Registro dentro de un ambito de analisis.' }
        }
    }
    $check=Get-CleanPathStatus $root $root $true $true
    if (-not $check.Allowed) { throw 'Ruta de registros no permitida.' }
    [void][IO.Directory]::CreateDirectory($root)
    if (-not (Get-CleanPathStatus $root $root $true).Allowed) { throw 'Ruta de registros redirigida.' }
    # No persistir nombres, rutas personales ni mensajes de excepciones.
    $safeRecords=@(); $index=0
    foreach ($record in $report.Records) {
        $index++; $safeRecords += [pscustomobject]@{Item=$index;Category=$record.Category;Status=$record.Status;Reason=$record.Reason}
    }
    $safe=[pscustomobject]@{Version=1;Date=[DateTime]::UtcNow.ToString('o');Removed=0;RecoveredBytes=$null;Records=$safeRecords}
    $path=Join-Path $root ('cleanup-'+[Guid]::NewGuid().ToString('N')+'.json')
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes=[Text.UTF8Encoding]::new($true).GetBytes(($safe | ConvertTo-Json -Depth 6))
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
    } finally { $stream.Dispose() }
    return $path
}
function Open-CleanupOfficialTool([string]$action) {
    $windows=[Environment]::GetFolderPath('Windows')
    switch ($action) {
        'Storage' { Start-Process 'ms-settings:storagesense' -ErrorAction Stop }
        'DiskCleanup' { Start-Process (Join-Path $windows 'System32\cleanmgr.exe') -ErrorAction Stop }
        'RecycleBin' { Start-Process (Join-Path $windows 'explorer.exe') -ArgumentList 'shell:RecycleBinFolder' -ErrorAction Stop }
        default { throw 'Herramienta no permitida.' }
    }
}
function Invoke-CleanupSelection([string[]]$categories,[hashtable]$results,[bool]$confirmed=$false) {
    $report=[pscustomobject]@{Status='Cancelled';Removed=0;RecoveredBytes=$null;Opened=0;Skipped=0;Failed=0;Records=@();LogPath=$null;LogError=$false}
    if (-not $confirmed -or $categories.Count -eq 0) { return $report }
    if (Test-CleanupIsAdmin) {
        $report.Status='BlockedElevated'; $report.Records=@([pscustomobject]@{Category='All';Status='Skipped';Reason='ElevatedProcess'})
        return $report
    }
    $specs=@($categories | Select-Object -Unique | ForEach-Object {
        $spec=Get-CleanupSpec $_
        if (-not $results.ContainsKey($spec.Id) -or $results[$spec.Id].Id -cne $spec.Id) { throw 'Primero analiza las categorias seleccionadas.' }
        if ($spec.Root -and -not ([string]$results[$spec.Id].Root).Equals([string]$spec.Root,[StringComparison]::OrdinalIgnoreCase)) { throw 'El analisis no pertenece al ambito autorizado.' }
        $spec
    })
    $opened=@{}
    foreach ($spec in $specs) {
        foreach ($record in @($results[$spec.Id].Records | Where-Object Status -ne Listed)) {
            $report.Records += [pscustomobject]@{Category=$spec.Id;Path=$record.Path;Status=$record.Status;Reason=$record.Reason}
            if ($record.Status -eq 'Failed') { $report.Failed++ } else { $report.Skipped++ }
        }
        if (-not $spec.Root -and -not $results[$spec.Id].Available) {
            $report.Failed++; $report.Records += [pscustomobject]@{Category=$spec.Id;Status='Failed';Reason='InventoryUnavailable'}
        }
        if ($spec.Root) {
            $check=Invoke-CleanCandidates $results[$spec.Id] $true
            $report.Skipped += $check.Skipped; $report.Failed += $check.Failed; $report.Records += @($check.Records)
        }
        if ($opened.ContainsKey($spec.Action)) { continue }
        try {
            Open-CleanupOfficialTool $spec.Action
            $opened[$spec.Action]=$true; $report.Opened++
            $report.Records += [pscustomobject]@{Category=$spec.Id;Status='Delegated';Reason='WindowsReviewRequired'}
        } catch {
            $report.Failed++; $report.Records += [pscustomobject]@{Category=$spec.Id;Status='Failed';Reason='ToolUnavailable'}
        }
    }
    $report.Status=if($report.Failed -gt 0){'PartialOrFailed'}else{'Delegated'}
    try { $report.LogPath=Write-CleanupLog $report }
    catch {
        $report.LogError=$true; $report.Status='PartialOrFailed'
        $report.Records += [pscustomobject]@{Category='Logging';Status='Failed';Reason='LogWriteFailed'}
    }
    return $report
}
function Confirm-CleanupSelection([System.Windows.Forms.Form]$parent,[string[]]$categories) {
    $nl=[Environment]::NewLine
    $message="Abrir herramientas de Windows para: $($categories -join ', ')?"+$nl+$nl+
        'JUNO no eliminara archivos. Windows mostrara su contenido ACTUAL; la lista de JUNO no limita lo que selecciones alli.'+$nl+$nl+
        'Revisa las categorias en Windows y confirma alli cualquier borrado. Puede ser irreversible; los respaldos de JUNO no lo deshacen.'
    return ([Windows.Forms.MessageBox]::Show($parent,$message,'Revisar limpieza en Windows','YesNo','Warning','Button2') -eq [Windows.Forms.DialogResult]::Yes)
}
function Show-CleanupDetails([System.Windows.Forms.Form]$parent,$result) {
    $view=New-Object Windows.Forms.Form
    $view.Text='JUNO | Archivos observados y motivos'; $view.StartPosition='CenterParent'; $view.ClientSize=New-Object Drawing.Size(780,450)
    $text=New-Object Windows.Forms.TextBox
    $text.Multiline=$true; $text.ReadOnly=$true; $text.ScrollBars='Both'; $text.WordWrap=$false; $text.Dock='Fill'
    $text.BackColor=[Drawing.Color]::FromArgb(22,26,34); $text.ForeColor=[Drawing.Color]::White
    $nl=[Environment]::NewLine
    $text.Text='Solo diagnostico; ninguna ruta autoriza un borrado.'+$nl+$result.Note+$nl+$nl+
        (($result.Records | ForEach-Object { "$($_.Status) | $($_.Reason) | $($_.Path)" }) -join $nl)
    $view.Controls.Add($text)
    try { [void]$view.ShowDialog($parent) } finally { $view.Dispose() }
}

function Show-CleanupManager([System.Windows.Forms.Form]$parent) {
    $dialog = New-Object System.Windows.Forms.Form
    if ($null -ne $script:JunoIcon) { $dialog.Icon = $script:JunoIcon }
    $dialog.Text = 'JUNO | Limpieza: diagnostico y Windows'
    $dialog.ClientSize = New-Object System.Drawing.Size(840, 535)
    $dialog.MinimumSize = New-Object System.Drawing.Size(840, 535)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(22,26,34)
    $dialog.ForeColor = [System.Drawing.Color]::White
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $dialog.Controls.Add((New-Label '6. Limpieza: diagnostico primero' 22 15 750 36 19 $true $white))
    $dialog.Controls.Add((New-Label 'JUNO no borra archivos. Analiza, inspecciona y revisa la limpieza en Windows.' 24 52 790 23 10 $false $muted))
    $dialog.Controls.Add((New-Label 'Antiguedad y extension no garantizan seguridad. El contenido puede cambiar.' 24 78 790 23 10 $false $muted))

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
    $colSize.HeaderText='Tamano listado'; $colSize.Width=115; $colSize.ReadOnly=$true
    $colNote = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colNote.HeaderText='Informacion'; $colNote.Width=255; $colNote.ReadOnly=$true
    foreach ($column in @($colChoose,$colName,$colFiles,$colSize,$colNote)) { [void]$grid.Columns.Add($column) }
    $dialog.Controls.Add($grid)

    $hint = New-Label 'Inventario parcial, sin recursion. Tamano logico; no es espacio recuperable verificado.' 24 344 795 34 10 $false $muted
    $dialog.Controls.Add($hint)
    $btnAnalyze = New-Button 'Analizar' 22 391 181 39 $blue
    $btnRecommended = New-Button 'Ver archivos / motivos' 217 391 223 39 $gray
    $btnClean = New-Button 'Revisar en Windows' 454 391 189 39 $green
    $btnClose = New-Button 'Cerrar' 656 391 162 39 $gray
    foreach ($button in @($btnAnalyze,$btnRecommended,$btnClean,$btnClose)) { [void]$dialog.Controls.Add($button) }
    $statusClean = New-Label 'Listo para analizar.' 24 443 795 26 10 $false $white
    $dialog.Controls.Add($statusClean)
    $dialog.Controls.Add((New-Label 'Los borrados que confirmes en Windows pueden ser irreversibles. JUNO no puede deshacerlos.' 24 480 795 40 10 $false $muted))

    $ctx=[pscustomobject]@{Results=@{};Busy=$false;LastReport=$null}
    $btnClean.Enabled=$false; $btnRecommended.Enabled=$false
    $btnAnalyze.Add_Click({
        if($ctx.Busy){return}
        $ctx.Busy=$true; $ctx.LastReport=$null
        $btnAnalyze.Enabled=$false; $btnClean.Enabled=$false; $btnRecommended.Enabled=$false
        $dialog.UseWaitCursor=$true; $grid.Rows.Clear(); $ctx.Results=@{}
        try {
            foreach($spec in Get-CleanupSpecs) {
                if($spec.Root){$scan=Scan-CleanFolder $spec.Id}
                else {
                    try {$scan=Get-RecycleBinEstimate}
                    catch {$scan=[pscustomobject]@{Id=$spec.Id;Available=$false;Files=@();Records=@();Count=0;Bytes=0L;Failed=1;Skipped=0;CanDelete=$false;Note='Consulta no disponible; revisar contenido actual en Windows'}}
                }
                $ctx.Results[$spec.Id]=$scan
                $count=if($scan.Available){[string]$scan.Count}else{'Sin datos'}
                $size=if($scan.Available){Format-CleanBytes $scan.Bytes}else{'Sin datos'}
                $index=$grid.Rows.Add($false,$spec.Name,$count,$size,$scan.Note); $grid.Rows[$index].Tag=$spec.Id
            }
            $failures=($ctx.Results.Values | Measure-Object -Property Failed -Sum).Sum
            $statusClean.Text="Analisis finalizado: $failures fallos. Ver archivos / motivos; selecciona categorias."
            if(Test-CleanupIsAdmin){$statusClean.Text='Modo elevado: solo consulta. Reabre JUNO sin administrador para continuar.'}
            $btnRecommended.Enabled=$true; $btnClean.Enabled=-not (Test-CleanupIsAdmin)
        } catch {$statusClean.Text='Analisis incompleto. No se borro nada. '+$_.Exception.Message}
        finally {$ctx.Busy=$false; $btnAnalyze.Enabled=$true; $dialog.UseWaitCursor=$false}
    })
    $btnRecommended.Add_Click({
        if($grid.SelectedRows.Count -eq 1) {
            $id=[string]$grid.SelectedRows[0].Tag
            $result=$ctx.Results[$id]
            if($null -ne $ctx.LastReport) {
                $result=[pscustomobject]@{Note='Resultado de revalidacion / apertura; JUNO no borro archivos.';Records=@($ctx.LastReport.Records | Where-Object { $_.Category -eq $id -and $_.PSObject.Properties.Name -contains 'Path' })}
            }
            Show-CleanupDetails $dialog $result
        }
    })
    $btnClean.Add_Click({
        if($ctx.Busy){return}
        [void]$grid.EndEdit()
        $selected=@($grid.Rows | Where-Object {$_.Cells[0].Value -eq $true} | ForEach-Object {[string]$_.Tag})
        if($selected.Count -eq 0){$statusClean.Text='Selecciona categorias; Papelera es siempre opcional.';return}
        if(-not (Confirm-CleanupSelection $dialog $selected)) {
            $statusClean.Text='Cancelado. No se abrieron herramientas ni se borro nada.'; return
        }
        $ctx.Busy=$true
        try {
            $report=Invoke-CleanupSelection $selected $ctx.Results $true
            $ctx.LastReport=$report
            $statusClean.Text="Herramientas abiertas: $($report.Opened). Eliminados por JUNO: 0. Espacio recuperado: no medido."
            $nl=[Environment]::NewLine
            $message=$statusClean.Text+$nl+"Estado: $($report.Status). Omitidos: $($report.Skipped); fallidos: $($report.Failed)."+$nl+
                (($report.Records | Where-Object Status -ne Skipped | Select-Object -First 15 | ForEach-Object {"$($_.Category): $($_.Status) / $($_.Reason)"}) -join $nl)+$nl+'Ver archivos / motivos para el detalle completo.'
            if($report.LogPath){$message+=$nl+"Registro sin rutas personales: $($report.LogPath)"}
            if($report.LogError){$message+=$nl+'ATENCION: no se pudo guardar el registro; el detalle solo esta en esta ventana.'}
            if($report.Status -eq 'BlockedElevated'){$message+=$nl+'Reabre JUNO sin administrador. No se realizaron acciones.'}
            [void][Windows.Forms.MessageBox]::Show($dialog,$message,'Revision de limpieza','OK',$(if($report.Failed -gt 0 -or $report.LogError){'Warning'}else{'Information'}))
        } catch {$statusClean.Text='Operacion incompleta: '+$_.Exception.Message+' JUNO no borro archivos.'}
        finally {$ctx.Busy=$false}
    })
    $btnClose.Add_Click({if(-not $ctx.Busy){$dialog.Close()}})
    $dialog.Add_FormClosing({param($sender,$e) if($ctx.Busy){$e.Cancel=$true}})
    try {[void]$dialog.ShowDialog($parent)} finally {$dialog.Dispose()}
}
