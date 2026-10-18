#requires -Version 5.1
# Pester 3.4. Archivos ficticios solo dentro del TestDrive privado de esta suite.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$cleanupTestSource=Join-Path (Split-Path $PSScriptRoot -Parent) 'Limpieza.ps1'
$cleanupTokens=$null; $cleanupErrors=$null
$cleanupAst=[System.Management.Automation.Language.Parser]::ParseFile($cleanupTestSource,[ref]$cleanupTokens,[ref]$cleanupErrors)
if($cleanupErrors.Count){throw ($cleanupErrors.Message -join '; ')}
foreach($node in $cleanupAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    if($node.Name -notin @('Show-CleanupManager','Show-CleanupDetails','Confirm-CleanupSelection','Get-RecycleBinEstimate','Test-CleanupIsAdmin','Get-CleanupLogRoot')) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
# Barreras independientes de los mocks: ningun proceso ni ruta real se utiliza.
function Test-CleanupIsAdmin { throw 'TEST: identidad real prohibida' }
function Get-CleanupLogRoot { throw 'TEST: registro fuera del TestDrive prohibido' }
function Start-Process { [CmdletBinding()]param([string]$FilePath,[string[]]$ArgumentList) throw 'TEST: abrir procesos reales prohibido' }
function New-CleanupTestFile([string]$name,[int]$length=10) {
    $path=[IO.Path]::GetFullPath((Join-Path $global:JunoCleanupTestRoot $name))
    if(-not $path.StartsWith($global:JunoCleanupTestRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: destino fuera del fixture'}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllBytes($path,(New-Object byte[] $length))
    [IO.File]::SetCreationTimeUtc($path,[DateTime]::UtcNow.AddDays(-30))
    [IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddDays(-30))
    return $path
}
function Get-CleanupTestSpecs {
    return @(
        [pscustomobject]@{Id='Usuario';Name='Usuario';Root=$global:JunoCleanupTestRoot;Days=7;Pattern='(?i)^[^\\/:]+\.tmp$';Action='Storage'},
        [pscustomobject]@{Id='Windows';Name='Windows';Root=(Join-Path $global:JunoCleanupTestRoot 'windows');Days=14;Pattern='(?i)^[^\\/:]+\.tmp$';Action='Storage'},
        [pscustomobject]@{Id='Miniaturas';Name='Miniaturas';Root=(Join-Path $global:JunoCleanupTestRoot 'thumbnails');Days=7;Pattern='(?i)^thumbcache_(\d+|idx|sr|wide|custom_stream)\.db$';Action='DiskCleanup'},
        [pscustomobject]@{Id='Papelera';Name='Papelera';Root=$null;Days=0;Pattern='';Action='RecycleBin'}
    )
}
function Initialize-CleanupTestFixture([string]$drive) {
    $caseRoot=Join-Path $drive ('case-'+[Guid]::NewGuid().ToString('N'))
    $global:JunoCleanupTestRoot=[IO.Path]::GetFullPath((Join-Path $caseRoot 'data')).TrimEnd('\')
    [void][IO.Directory]::CreateDirectory($global:JunoCleanupTestRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $global:JunoCleanupTestRoot 'windows'))
    [void][IO.Directory]::CreateDirectory((Join-Path $global:JunoCleanupTestRoot 'thumbnails'))
    $global:JunoCleanupTestLogRoot=Join-Path $caseRoot 'logs'
}

Describe 'Limpieza: diagnostico conservador con archivos ficticios' {
    BeforeEach {
        Initialize-CleanupTestFixture $TestDrive
        Mock Get-CleanupSpecs { Get-CleanupTestSpecs }
        Mock Test-CleanupIsAdmin { $false }
        Mock Get-CleanupLogRoot { $global:JunoCleanupTestLogRoot }
        Mock Open-CleanProbe {param($path) [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
        Mock Get-CleanAttributes {param($path) [IO.File]::GetAttributes($path)}
        Mock Start-Process { throw 'TEST: no debe abrirse ningun proceso durante el analisis' }
    }
    It 'analiza sin borrar ni alterar contenido, cantidad o fechas' {
        $path=New-CleanupTestFile 'observed.tmp' 17
        $before=[IO.File]::GetLastWriteTimeUtc($path)
        $scan=Scan-CleanFolder 'Usuario'
        $scan.Count | Should Be 1
        $scan.Bytes | Should Be 17
        $scan.CanDelete | Should Be $false
        [IO.File]::ReadAllBytes($path).Length | Should Be 17
        [IO.File]::GetLastWriteTimeUtc($path) | Should Be $before
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        (Test-Path -LiteralPath $global:JunoCleanupTestLogRoot) | Should Be $false
    }
    It 'excluye archivos desconocidos aunque sean antiguos' -TestCases @(@{Name='personal.txt'},@{Name='project.ps1'},@{Name='database.db'},@{Name='archive.zip'},@{Name='document.pdf'},@{Name='image.jpg'}) {
        param($Name)
        $path=New-CleanupTestFile $Name
        $scan=Scan-CleanFolder 'Usuario'
        $scan.Count | Should Be 0
        @($scan.Records | Where-Object Reason -eq UnknownContent).Count | Should Be 1
        [IO.File]::Exists($path) | Should Be $true
    }
    It 'no recorre subcarpetas ni borra carpetas completas' {
        $path=New-CleanupTestFile 'project\inside.tmp'
        $scan=Scan-CleanFolder 'Usuario'
        $scan.Count | Should Be 0
        @($scan.Records | Where-Object Reason -eq DirectoryNotInspected).Count | Should BeGreaterThan 0
        [IO.File]::Exists($path) | Should Be $true
    }
    It 'conserva archivos recientes y protegidos' {
        $recent=New-CleanupTestFile 'recent.tmp'
        [IO.File]::SetLastWriteTimeUtc($recent,[DateTime]::UtcNow)
        $protected=New-CleanupTestFile 'protected.tmp'
        [IO.File]::SetAttributes($protected,[IO.FileAttributes]::ReadOnly)
        try {
            $scan=Scan-CleanFolder 'Usuario'
            $scan.Count | Should Be 0
            @($scan.Records | Where-Object Reason -eq TooRecent).Count | Should Be 1
            @($scan.Records | Where-Object Reason -eq ProtectedAttributes).Count | Should Be 1
        } finally { [IO.File]::SetAttributes($protected,[IO.FileAttributes]::Normal) }
    }
    It 'lista solo patrones concretos de miniaturas como diagnostico' {
        New-CleanupTestFile 'thumbnails\thumbcache_256.db' 23 | Out-Null
        New-CleanupTestFile 'thumbnails\personal.db' 99 | Out-Null
        $scan=Scan-CleanFolder 'Miniaturas'
        $scan.Count | Should Be 1; $scan.Bytes | Should Be 23; $scan.CanDelete | Should Be $false
    }
    It 'limita todas las entradas inspeccionadas incluidas carpetas' {
        New-CleanupTestFile 'one.tmp' | Out-Null
        New-CleanupTestFile 'two.tmp' | Out-Null
        $scan=Scan-CleanFolder 'Usuario' 1
        $scan.Truncated | Should Be $true
        @($scan.Records).Count | Should Be 1
        $scan.Note | Should Match 'PARCIAL'
    }
    It 'rechaza categorias y limites no permitidos' {
        { Scan-CleanFolder 'Unknown' } | Should Throw
        { Scan-CleanFolder 'Usuario' 0 } | Should Throw
        { Scan-CleanFolder 'Usuario' 5001 } | Should Throw
    }
    It 'omite archivos bloqueados sin presentarlos como eliminables' {
        $path=New-CleanupTestFile 'locked.tmp'
        $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try {
            $scan=Scan-CleanFolder 'Usuario'
            @($scan.Records | Where-Object Reason -eq InUse).Count | Should Be 1
            $scan.Count | Should Be 0
        } finally { $lock.Dispose() }
    }
    It 'revalida archivos desaparecidos, modificados o bloqueados despues del analisis' -TestCases @(@{Change='Missing'},@{Change='Changed'},@{Change='InUse'}) {
        param($Change)
        $path=New-CleanupTestFile 'change.tmp' 10
        $scan=Scan-CleanFolder 'Usuario'; $lock=$null
        if(-not $path.StartsWith($global:JunoCleanupTestRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'TEST: destino no verificado'}
        try {
            if($Change -eq 'Missing'){[IO.File]::Delete($path)}
            elseif($Change -eq 'Changed'){[IO.File]::AppendAllText($path,'changed')}
            else{$lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
            $report=Invoke-CleanCandidates $scan $true
            $report.Removed | Should Be 0
            $report.Records[0].Reason | Should Be $Change
            ($null -eq $report.RecoveredBytes) | Should Be $true
        } finally { if($null -ne $lock){$lock.Dispose()} }
    }
    It 'registra fallos de permisos sin esconderlos como omisiones normales' {
        New-CleanupTestFile 'denied.tmp' | Out-Null
        Mock Open-CleanProbe { throw [UnauthorizedAccessException]::new('fixture denied') }
        $scan=Scan-CleanFolder 'Usuario'
        $scan.Failed | Should Be 1
        @($scan.Records | Where-Object Reason -eq AccessDenied).Count | Should Be 1
    }
    It 'una llamada antigua confirmada tampoco puede eliminar archivos' {
        $path=New-CleanupTestFile 'never-delete.tmp'
        $scan=Scan-CleanFolder 'Usuario'
        $report=Invoke-CleanCandidates $scan $true
        $report.Removed | Should Be 0; $report.Bytes | Should Be 0
        $report.Records[0].Reason | Should Be 'DiagnosticOnly'
        [IO.File]::Exists($path) | Should Be $true
    }
    It 'excluye rutas externas, prefijos parecidos, relativas, ADS y dispositivos' -TestCases @(@{Kind='Sibling'},@{Kind='Relative'},@{Kind='ADS'},@{Kind='Device'},@{Kind='Traversal'},@{Kind='UNC'}) {
        param($Kind)
        $path=New-CleanupTestFile 'allowed.tmp'
        switch($Kind){
            'Sibling' {$path=$global:JunoCleanupTestRoot+'-other\file.tmp'}
            'Relative' {$path='relative.tmp'}
            'ADS' {$path+=':stream'}
            'Device' {$path='\\?\C:\file.tmp'}
            'Traversal' {$path=$global:JunoCleanupTestRoot+'\..\file.tmp'}
            'UNC' {$path='\\server\share\file.tmp'}
        }
        (Get-CleanPathStatus $path $global:JunoCleanupTestRoot).Allowed | Should Be $false
    }
    It 'rechaza symlinks y puntos de montaje por ReparsePoint (atributos simulados)' -TestCases @(@{Link='symlink.tmp'},@{Link='mount.tmp'}) {
        param($Link)
        $global:JunoCleanupTestLink=New-CleanupTestFile $Link
        Mock Open-CleanProbe { throw 'TEST: no debe abrirse un reparse point' }
        Mock Get-CleanAttributes {
            param($path)
            if($path -eq $global:JunoCleanupTestLink){return [IO.FileAttributes]::ReparsePoint}
            [IO.File]::GetAttributes($path)
        }
        $scan=Scan-CleanFolder 'Usuario'
        $scan.Count | Should Be 0
        @($scan.Records | Where-Object Reason -eq ReparsePoint).Count | Should Be 1
        Assert-MockCalled Open-CleanProbe -Times 0 -Exactly -Scope It
    }
    It 'rechaza una junction real sin recorrer su destino privado' {
        $target=Join-Path $TestDrive 'target'; [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText((Join-Path $target 'untouched.tmp'),'fixture')
        $link=Join-Path $global:JunoCleanupTestRoot 'junction'
        [void](New-Item -ItemType Junction -Path $link -Target $target)
        $scan=Scan-CleanFolder 'Usuario'
        @($scan.Records | Where-Object Reason -eq ReparsePoint).Count | Should Be 1
        [IO.File]::ReadAllText((Join-Path $target 'untouched.tmp')) | Should Be 'fixture'
    }
    It 'rechaza una raiz con una junction en sus antecesores' {
        $target=Join-Path $TestDrive 'target'; [void][IO.Directory]::CreateDirectory((Join-Path $target 'nested'))
        $link=Join-Path $TestDrive 'parent-link'; [void](New-Item -ItemType Junction -Path $link -Target $target)
        $global:JunoCleanupTestRoot=Join-Path $link 'nested'
        (Scan-CleanFolder 'Usuario').Available | Should Be $false
    }
    It 'una sustitucion por reparse despues del analisis se omite' {
        $global:JunoCleanupTestLink=New-CleanupTestFile 'replace.tmp'
        $scan=Scan-CleanFolder 'Usuario'
        Mock Get-CleanAttributes {param($path) if($path -eq $global:JunoCleanupTestLink){return [IO.FileAttributes]::ReparsePoint}; [IO.File]::GetAttributes($path)}
        $report=Invoke-CleanCandidates $scan $true
        $report.Records[0].Reason | Should Be 'ReparsePoint'; $report.Removed | Should Be 0
    }
}

Describe 'Seleccion, confirmacion, herramientas y registros' {
    BeforeEach {
        Initialize-CleanupTestFixture $TestDrive
        Mock Get-CleanupSpecs { Get-CleanupTestSpecs }
        Mock Test-CleanupIsAdmin { $false }
        Mock Get-CleanupLogRoot { $global:JunoCleanupTestLogRoot }
        Mock Start-Process {}
    }
    It 'exige confirmacion y permite cancelar sin abrir ni guardar nada' -TestCases @(@{Mode='No'},@{Mode='Omitted'}) {
        param($Mode)
        $report=if($Mode -eq 'Omitted'){Invoke-CleanupSelection @('Usuario') @{}}else{Invoke-CleanupSelection @('Usuario') @{} $false}
        $report.Status | Should Be 'Cancelled'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        (Test-Path -LiteralPath $global:JunoCleanupTestLogRoot) | Should Be $false
    }
    It 'requiere un analisis valido de todas las categorias antes de abrir' {
        $scan=Scan-CleanFolder 'Usuario'
        { Invoke-CleanupSelection @('Usuario','Unknown') @{Usuario=$scan} $true } | Should Throw
        { Invoke-CleanupSelection @('Usuario') @{} $true } | Should Throw
        $scan.Root=Join-Path $TestDrive 'outside'
        { Invoke-CleanupSelection @('Usuario') @{Usuario=$scan} $true } | Should Throw
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'modo elevado bloquea apertura y escritura de registros' {
        Mock Test-CleanupIsAdmin {$true}
        (Invoke-CleanupSelection @('Usuario') @{} $true).Status | Should Be 'BlockedElevated'
        {Write-CleanupLog ([pscustomobject]@{Records=@()})} | Should Throw
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        (Test-Path -LiteralPath $global:JunoCleanupTestLogRoot) | Should Be $false
    }
    It 'abre solo interfaces oficiales sin argumentos de borrado' -TestCases @(@{Action='Storage'},@{Action='DiskCleanup'},@{Action='RecycleBin'}) {
        param($Action)
        Open-CleanupOfficialTool $Action
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It -ParameterFilter { $ArgumentList -match '/sagerun|/verylowdisk|/sageset|/autoclean' }
    }
    It 'rechaza herramientas no permitidas' {
        {Open-CleanupOfficialTool 'arbitrary.exe'} | Should Throw
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'deduplica almacenamiento y nunca agrega Papelera a la seleccion' {
        $report=Invoke-CleanupSelection @('Usuario','Windows') @{Usuario=(Scan-CleanFolder 'Usuario');Windows=(Scan-CleanFolder 'Windows')} $true
        $report.Opened | Should Be 1
        @($report.Records | Where-Object Category -eq Papelera).Count | Should Be 0
        $report.Removed | Should Be 0
        ($null -eq $report.RecoveredBytes) | Should Be $true
    }
    It 'Papelera se delega sin asumir que el contenido coincide con la instantanea' {
        $scan=[pscustomobject]@{Id='Papelera';Available=$true;Count=123;Bytes=99999L;Records=@();Files=@()}
        $report=Invoke-CleanupSelection @('Papelera') @{Papelera=$scan} $true
        $report.Opened | Should Be 1; $report.Removed | Should Be 0
        ($null -eq $report.RecoveredBytes) | Should Be $true
        Assert-MockCalled Start-Process -Times 1 -Scope It -ParameterFilter {$ArgumentList -eq 'shell:RecycleBinFolder'}
    }
    It 'informa resultados parciales sin simular eliminaciones exitosas' {
        New-CleanupTestFile 'good.tmp' | Out-Null
        $denied=New-CleanupTestFile 'denied.tmp'
        Mock Open-CleanProbe {param($path) if($path -like '*denied.tmp'){throw [UnauthorizedAccessException]::new('fixture')}; [IO.File]::Open($path,'Open','Read','None')}
        $scan=Scan-CleanFolder 'Usuario'
        $report=Invoke-CleanupSelection @('Usuario') @{Usuario=$scan} $true
        $report.Status | Should Be 'PartialOrFailed'; $report.Failed | Should Be 1; $report.Removed | Should Be 0
        [IO.File]::Exists($denied) | Should Be $true
    }
    It 'informa fallo de herramienta y fallo de log por separado' {
        Mock Start-Process {throw 'fixture unavailable'}
        Mock Get-CleanupLogRoot {$global:JunoCleanupTestRoot}
        $report=Invoke-CleanupSelection @('Usuario') @{Usuario=(Scan-CleanFolder 'Usuario')} $true
        $report.Failed | Should Be 1; $report.Opened | Should Be 0; $report.LogError | Should Be $true
    }
    It 'guarda resultados fuera del inventario sin nombres o rutas personales' {
        $path=New-CleanupTestFile 'sensitive-name.tmp'
        $report=Invoke-CleanupSelection @('Usuario') @{Usuario=(Scan-CleanFolder 'Usuario')} $true
        $report.LogError | Should Be $false
        $report.LogPath.StartsWith($global:JunoCleanupTestLogRoot) | Should Be $true
        $json=[IO.File]::ReadAllText($report.LogPath)
        $json | Should Not Match 'sensitive-name|TestDrive|Path'
        $saved=$json | ConvertFrom-Json
        $saved.Removed | Should Be 0
        @($saved.Records).Count | Should BeGreaterThan 0
        [IO.File]::Exists($path) | Should Be $true
    }
    It 'impide guardar logs dentro de los arboles analizados' {
        Mock Get-CleanupLogRoot {$global:JunoCleanupTestRoot}
        {Write-CleanupLog ([pscustomobject]@{Records=@()})} | Should Throw
    }
    It 'impide guardar logs a traves de una junction' {
        $target=Join-Path $TestDrive 'log-target'; [void][IO.Directory]::CreateDirectory($target)
        [void](New-Item -ItemType Junction -Path $global:JunoCleanupTestLogRoot -Target $target)
        {Write-CleanupLog ([pscustomobject]@{Records=@()})} | Should Throw
        @([IO.Directory]::EnumerateFileSystemEntries($target)).Count | Should Be 0
    }
}

Describe 'Barreras estaticas y ABI x86/x64' {
    It 'el modulo no contiene primitivas de eliminacion' {
        $source=[IO.File]::ReadAllText($cleanupTestSource)
        $source | Should Not Match 'SHEmptyRecycleBin|DeleteFile|DeleteOnClose|\[IO\.File\]::Delete'
        $commands=@($cleanupAst.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true) | ForEach-Object {$_.GetCommandName()})
        @($commands | Where-Object {$_ -in @('Remove-Item','Clear-RecycleBin','Invoke-Expression')}).Count | Should Be 0
    }
    It 'la consulta de Papelera usa estructuras correctas en ambas arquitecturas' {
        $assignment=$cleanupAst.Find({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$cleanupNative'},$true)
        $native=$assignment.Right.Find({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true).Value
        if(-not ('JunoCleanupRecycleBin' -as [type])){Add-Type -TypeDefinition $native}
        [Runtime.InteropServices.Marshal]::SizeOf([type][JunoCleanupRecycleBin+Info32]) | Should Be 20
        [Runtime.InteropServices.Marshal]::SizeOf([type][JunoCleanupRecycleBin+Info64]) | Should Be 24
        [Runtime.InteropServices.Marshal]::OffsetOf([type][JunoCleanupRecycleBin+Info32],'i64Size').ToInt32() | Should Be 4
        [Runtime.InteropServices.Marshal]::OffsetOf([type][JunoCleanupRecycleBin+Info64],'i64Size').ToInt32() | Should Be 8
    }
}

# Probar los eventos reales sin mostrar ventanas ni dialogos de confirmacion.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$uiTokens=$null; $uiErrors=$null
$uiAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Juno.ps1'),[ref]$uiTokens,[ref]$uiErrors)
foreach($name in @('New-Label','New-Button')) {
    $node=$uiAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$showNode=$cleanupAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-CleanupManager'},$true)
$showText=$showNode.Extent.Text.Replace('try {[void]$dialog.ShowDialog($parent)} finally {$dialog.Dispose()}','try {Invoke-CleanupTestUi $dialog} finally {$dialog.Dispose()}')
$showText=[regex]::Replace($showText,'(?m)^\s*\[void\]\[Windows.Forms.MessageBox\]::Show\([^\r\n]*\)\s*$','Show-CleanupTestMessage $message')
if($showText -eq $showNode.Extent.Text -or $showText -match '\$dialog\.ShowDialog|\[Windows.Forms.MessageBox\]::Show'){throw 'TEST: no se sustituyeron las ventanas modales'}
. ([scriptblock]::Create($showText))
function Confirm-CleanupSelection($parent,$categories) { return $false }
function Get-RecycleBinEstimate { throw 'TEST: consulta de Papelera real prohibida' }
function Show-CleanupDetails($parent,$result) { throw 'TEST: no mostrar ventanas reales' }
function Show-CleanupTestMessage($message) { $global:JunoCleanupTestMessage=$message }
function Invoke-CleanupTestUi($dialog) { & $global:JunoCleanupTestUiAction $dialog }
function Invoke-CleanupTestClick($button) {
    $method=$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($button,@([EventArgs]::Empty))
}
Describe 'Eventos WinForms sin ventanas ni procesos reales' {
    BeforeEach {
        Initialize-CleanupTestFixture $TestDrive
        $script:JunoIcon=$null
        $script:white=[Drawing.Color]::White; $script:muted=[Drawing.Color]::LightGray
        $script:blue=[Drawing.Color]::SteelBlue; $script:green=[Drawing.Color]::SeaGreen; $script:gray=[Drawing.Color]::Gray
        Mock Get-CleanupSpecs {Get-CleanupTestSpecs}
        Mock Test-CleanupIsAdmin {$false}
        Mock Confirm-CleanupSelection {$false}
        Mock Get-RecycleBinEstimate {[pscustomobject]@{Id='Papelera';Available=$true;Files=@();Records=@();Count=2;Bytes=40L;Failed=0;Skipped=0;Note='Instantanea';CanDelete=$false}}
        Mock Invoke-CleanupSelection {[pscustomobject]@{Status='Delegated';Opened=1;Failed=0;Skipped=0;Records=@();LogPath=$null;LogError=$false}}
        Mock Start-Process {throw 'TEST: proceso real prohibido'}
        Mock Show-CleanupDetails {}
    }
    It 'abrir no analiza ni actua; analizar deja las cuatro categorias sin marcar' {
        $global:JunoCleanupTestUiAction={param($form)
            $grid=@($form.Controls | Where-Object {$_ -is [Windows.Forms.DataGridView]})[0]
            $grid.Rows.Count | Should Be 0
            $analyze=@($form.Controls | Where-Object Text -eq Analizar)[0]
            Invoke-CleanupTestClick $analyze
            $grid.Rows.Count | Should Be 4
            @($grid.Rows | Where-Object {$_.Cells[0].Value -eq $true}).Count | Should Be 0
        }
        Show-CleanupManager $null
        Assert-MockCalled Invoke-CleanupSelection -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'cancelar la confirmacion nunca llama a la accion' {
        $global:JunoCleanupTestUiAction={param($form)
            Invoke-CleanupTestClick @($form.Controls | Where-Object Text -eq Analizar)[0]
            $grid=@($form.Controls | Where-Object {$_ -is [Windows.Forms.DataGridView]})[0]
            $grid.Rows[0].Cells[0].Value=$true
            Invoke-CleanupTestClick @($form.Controls | Where-Object Text -eq 'Revisar en Windows')[0]
        }
        Show-CleanupManager $null
        Assert-MockCalled Confirm-CleanupSelection -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-CleanupSelection -Times 0 -Exactly -Scope It
    }
    It 'solo confirma la categoria seleccionada y permite inspeccionar sus rutas' {
        Mock Confirm-CleanupSelection {$true}
        $global:JunoCleanupTestUiAction={param($form)
            Invoke-CleanupTestClick @($form.Controls | Where-Object Text -eq Analizar)[0]
            $grid=@($form.Controls | Where-Object {$_ -is [Windows.Forms.DataGridView]})[0]
            $grid.Rows[0].Cells[0].Value=$true; $grid.Rows[0].Selected=$true
            Invoke-CleanupTestClick @($form.Controls | Where-Object Text -eq 'Ver archivos / motivos')[0]
            Invoke-CleanupTestClick @($form.Controls | Where-Object Text -eq 'Revisar en Windows')[0]
        }
        Show-CleanupManager $null
        Assert-MockCalled Show-CleanupDetails -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-CleanupSelection -Times 1 -Exactly -Scope It -ParameterFilter {$categories.Count -eq 1 -and $categories[0] -eq 'Usuario' -and $confirmed}
    }
}
