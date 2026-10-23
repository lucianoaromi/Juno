#requires -Version 5.1
# Geometria y eventos reales en memoria; ninguna ventana, politica o Registro real.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$regressionRoot=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $regressionRoot 'UiSupport.ps1')
. (Join-Path $regressionRoot 'BackgroundInventory.ps1')
function Convert-RegressionUi([string]$source) {
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
    $nodes=$ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Expression.Extent.Text -match 'Windows.Forms.MessageBox\]' -and $n.Member.Value -eq 'Show'},$true)
    foreach($n in @($nodes|Sort-Object {$_.Extent.StartOffset} -Descending)){
        $replacement='(Invoke-RegressionMessage -Values @('+ (($n.Arguments|ForEach-Object{$_.Extent.Text}) -join ',')+'))'
        $source=$source.Substring(0,$n.Extent.StartOffset)+$replacement+$source.Substring($n.Extent.EndOffset)
    }
    $source=$source.Replace('[void]$dialog.ShowDialog($parent)','Invoke-RegressionWindow $dialog').Replace('[void]$dlg.ShowDialog($parent)','Invoke-RegressionWindow $dlg')
    return $source
}
foreach($file in @('PowerOperations.ps1','TransparencyOperations.ps1','VisualEffectsOperations.ps1','Juno.ps1','StartupOperations.ps1','Inicio.ps1','SegundoPlano.ps1','Discos.ps1','Limpieza.ps1','PermisosSegundoPlano.ps1')){
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $regressionRoot $file),[ref]$t,[ref]$e)
    foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
        . ([scriptblock]::Create((Convert-RegressionUi $node.Extent.Text)))
    }
    if($file -eq 'Juno.ps1'){
        $raw=[IO.File]::ReadAllText((Join-Path $regressionRoot $file))
        $ui=$raw.Substring($raw.IndexOf('# ----------------------- INTERFAZ GRAFICA'))
        $ui=$ui.Substring(0,$ui.LastIndexOf('} finally { Exit-JunoLease }'))
        $ui=(Convert-RegressionUi $ui).Replace('[void][System.Windows.Forms.Application]::Run($form)','Invoke-RegressionWindow $form')
        if($ui -match 'Application\]::Run|\.ShowDialog\('){throw 'TEST: ventana real no sustituida'}
        . ([scriptblock]::Create('function Invoke-RegressionMain {'+$ui+'}'))
    }
}
function Invoke-RegressionWindow($window){& $global:JunoRegressionAction $window}
function Invoke-RegressionMessage($Values){$global:JunoRegressionMessages+=@([pscustomobject]@{Values=$Values});return [Windows.Forms.DialogResult]::No}
function Invoke-RegressionClick($button){[void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))}
function Get-RegressionButton($form,[string]$text){return @($form.Controls|Where-Object{$_.Text -ceq $text})[0]}
function Get-RegressionGrid($form){return @($form.Controls|Where-Object{$_ -is [Windows.Forms.DataGridView]})[0]}
function Get-TransparencyState {throw 'TEST: Registro real prohibido'}
function Get-JunoStorePath {throw 'TEST: respaldo real prohibido'}
function Test-DiskIsAdmin {throw 'TEST: identidad real prohibida'}
function Test-JunoAdmin {throw 'TEST: identidad real prohibida'}
function Test-CleanupIsAdmin {throw 'TEST: identidad real prohibida'}
function Read-JunoStore {throw 'TEST: respaldo real prohibido'}
function Write-JunoStore {throw 'TEST: respaldo real prohibido'}
function Start-Process {[CmdletBinding()]param($FilePath,$ArgumentList) throw 'TEST: procesos reales prohibidos'}
function Assert-RegressionGeometry($container) {
    $controls=@($container.Controls)
    foreach($c in $controls){
        $c.Left|Should BeGreaterThan -1;$c.Top|Should BeGreaterThan -1
        ($c.Right -le $container.DisplayRectangle.Width+1)|Should Be $true
        ($c.Bottom -le $container.DisplayRectangle.Height+1)|Should Be $true
        if($c -is [Windows.Forms.Panel]){Assert-RegressionGeometry $c}
    }
    for($i=0;$i -lt $controls.Count;$i++){
        for($j=$i+1;$j -lt $controls.Count;$j++){
            if($controls[$i].Bounds.IntersectsWith($controls[$j].Bounds)){throw ('Controles superpuestos: '+$controls[$i].Text+' / '+$controls[$j].Text)}
        }
    }
}
function Reset-RegressionFixture {
    $script:JunoIcon=$null;$script:JunoImage=$null;$script:StartupIsAdmin=$false
    $script:white=[Drawing.Color]::White;$script:muted=[Drawing.Color]::LightGray;$script:blue=[Drawing.Color]::SteelBlue;$script:green=[Drawing.Color]::SeaGreen;$script:gray=[Drawing.Color]::Gray
    $script:BgOptionalNames=@('spotify');$script:AppFolder=Join-Path $TestDrive 'Usuario con espacios';$script:DiskTrimBackupPath=Join-Path $script:AppFolder 'trim-backup.json'
    foreach($name in @('DiskDialog','DiskGrid','DiskDetails','DiskStatus','DiskTrimLabel','DiskTaskLabel','DiskOptimizeButton','DiskEnableTrimButton','DiskRestoreTrimButton','DiskProcess','DiskTimer','DiskTrimStatus')){Set-Variable -Name $name -Scope Script -Value $null}
    $global:JunoRegressionMessages=@();$global:JunoRegressionAdmin=$false;$global:JunoRegressionVolumes=@();$global:JunoRegressionProcesses=@()
    $global:JunoRegressionScan=[pscustomobject]@{Complete=$false;CancelRequested=$false;Disposed=$false;Pipe=$null;Runspace=$null}
}
Describe 'Integracion WinForms sin cambios en los siete modulos' {
    BeforeEach {
        Reset-RegressionFixture
        Mock Get-JunoWindowArea {[Drawing.Rectangle]::new(0,0,1920,1080)}
        Mock Get-TransparencyState {$null}
        Mock Invoke-RegressionMessage {param($Values) $global:JunoRegressionMessages+=@([pscustomobject]@{Values=$Values});return [Windows.Forms.DialogResult]::No}
        Mock Read-JunoStore {throw 'TEST: respaldo real prohibido'}
        Mock Write-JunoStore {throw 'TEST: respaldo real prohibido'}
        Mock Get-StartupEntries {@()}
        Mock Get-BgProcesses {$global:JunoRegressionProcesses}
        Mock Get-BgFreeMemoryMB {$null}
        Mock Test-DiskIsAdmin {$global:JunoRegressionAdmin}
        Mock Test-JunoAdmin {$global:JunoRegressionAdmin}
        Mock Test-CleanupIsAdmin {$false}
        Mock Get-DiskVolumes {$global:JunoRegressionVolumes}
        Mock Get-DiskTrimState {[pscustomobject]@{State=1;Text='TRIM de prueba'}}
        Mock Get-DiskScheduleState {'Tarea de prueba: sin datos'}
        Mock Get-JunoStorePath {Join-Path $TestDrive 'No existente\trim-backup.json'}
        Mock Get-BPPPermissionView {[pscustomobject]@{Rows=@();Environment=[pscustomobject]@{Reason='Sin acciones compatibles'};Errors=@()}}
        Mock Test-Path {$false}
        Mock Start-Process {throw 'Fixture: herramienta ausente'}
        Mock Start-CleanupScan {$global:JunoRegressionScan}
        Mock Test-CleanupScanComplete {param($operation) $operation.Complete}
        Mock Stop-CleanupScan {param($operation) $operation.CancelRequested=$true}
        Mock Receive-CleanupScan {param($operation) $operation.Disposed=$true;[pscustomobject]@{Status='Cancelled';Items=@();Message='Analisis cancelado. No se borro nada.'}}
    }
    It 'construye los siete modulos y mantiene geometria al escalar de forma aislada' -TestCases @(@{Scale=1.0},@{Scale=1.25},@{Scale=1.5},@{Scale=2.0}) {
        param($Scale)
        $global:JunoRegressionScale=$Scale
        $global:JunoRegressionAction={param($form)
            [void]$form.GetType().GetMethod('OnShown',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($form,@([EventArgs]::Empty))
            $form.Scale([Drawing.SizeF]::new($global:JunoRegressionScale,$global:JunoRegressionScale))
            Assert-RegressionGeometry $form
            Limit-JunoWindow $form ([Drawing.Rectangle]::new(-1280,0,1280,720))
            ($form.Width -le 1280)|Should Be $true;($form.Height -le 720)|Should Be $true
            $form.Left|Should BeLessThan 0;$form.Top|Should BeGreaterThan -1
            $form.AutoScroll|Should Be $true
            Assert-RegressionGeometry $form
        }
        Invoke-RegressionMain
        foreach($name in @('Show-StartupManager','Show-BackgroundManager','Show-BackgroundPermissions','Show-CleanupManager','Show-DiskManager')){& $name $null}
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-CleanupScan -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-JunoStore -Times 0 -Exactly -Scope It
    }
    It 'arranca sin recursos graficos y tolera error de lectura de transparencia' {
        Mock Get-TransparencyState {throw 'Fixture: lectura denegada'}
        $global:JunoRegressionAction={param($form)
            $form.Text|Should Match 'JUNO';$script:JunoIcon|Should BeNullOrEmpty
            $panel=@($form.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})[0]
            $panel.Controls.Count|Should Be 8
            @($panel.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text -eq 'Estado de transparencia: no se pudo consultar'}).Count|Should Be 1
            $form.Close()
        }
        Invoke-RegressionMain
        Assert-MockCalled Write-JunoStore -Times 0 -Exactly -Scope It
    }
    It 'botones de energia y efectos informan herramienta ausente sin excepcion de evento' {
        $global:JunoRegressionAction={param($form)
            $panel=@($form.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})[0]
            foreach($text in @('Ver planes de energia','Configurar en Windows')){
                $button=@($panel.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text -eq $text})[0];Invoke-RegressionClick $button
            }
            $global:JunoRegressionMessages.Count|Should Be 2
        }
        Invoke-RegressionMain
    }
    It 'energia distingue administrador antes de habilitar el cambio' -TestCases @(@{Admin=$false},@{Admin=$true}) {
        param($Admin);$global:JunoRegressionAdmin=$Admin
        $global:JunoRegressionAction={param($form)
            $panel=@($form.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})[0]
            $button=@($panel.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text -eq 'Activar Alto rendimiento'})[0]
            $button.Enabled|Should Be $global:JunoRegressionAdmin
        }
        Invoke-RegressionMain
    }
    It 'restauracion general cancelada no toca originales ni otros modulos' {
        $global:JunoRegressionAction={param($form)
            $panel=@($form.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})[0]
            $button=@($panel.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text -eq 'Restaurar energia, efectos y transparencia'})[0]
            Invoke-RegressionClick $button
        }
        Invoke-RegressionMain
        Assert-MockCalled Read-JunoStore -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-JunoStore -Times 0 -Exactly -Scope It
    }
    It 'restauracion general informa resultado parcial y continua con los otros ajustes' {
        Mock Restore-VisualEffects {'Efectos: original restaurado'}
        Mock Restore-Transparency {throw 'Fixture: cambio externo; respaldo conservado'}
        Mock Restore-PowerPlan {'Energia: no hay restauracion pendiente'}
        Mock Invoke-RegressionMessage {param($Values)
            $global:JunoRegressionMessages+=@([pscustomobject]@{Values=$Values})
            if($Values[2] -eq 'Confirmar restauracion'){return [Windows.Forms.DialogResult]::Yes};return [Windows.Forms.DialogResult]::No
        }
        $global:JunoRegressionAction={param($form)
            $panel=@($form.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})[0]
            $button=@($panel.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text -eq 'Restaurar energia, efectos y transparencia'})[0]
            Invoke-RegressionClick $button
            $global:JunoRegressionMessages[-1].Values[1]|Should Match 'Restauracion parcial o pendiente'
            $global:JunoRegressionMessages[-1].Values[1]|Should Match 'cambio externo; respaldo conservado'
        }
        Invoke-RegressionMain
        Assert-MockCalled Restore-VisualEffects -Times 1 -Exactly -Scope It
        Assert-MockCalled Restore-Transparency -Times 1 -Exactly -Scope It
        Assert-MockCalled Restore-PowerPlan -Times 1 -Exactly -Scope It
    }
    It 'procesos sin seleccion ni ventana no habilitan cierres incompatibles' {
        $global:JunoRegressionProcesses=@([pscustomobject]@{Name='other';Pid=1;RamMB=1;CpuPct=0;HasWindow=$false;Suggestion='No opcional';Path='C:\Fixture\other.exe';Optional=$false})
        $global:JunoRegressionAction={param($form)
            (Get-RegressionButton $form 'Solicitar cierre normal').Enabled|Should Be $false
            (Get-RegressionButton $form 'Finalizar opcional (riesgo)').Enabled|Should Be $false
            $grid=Get-RegressionGrid $form;$grid.Rows[0].Selected=$true
            (Get-RegressionButton $form 'Solicitar cierre normal').Enabled|Should Be $false
            (Get-RegressionButton $form 'Finalizar opcional (riesgo)').Enabled|Should Be $false
        }
        Show-BackgroundManager $null
    }
    It 'habilita solo los cierres disponibles y cancelar no solicita el proceso' {
        $global:JunoRegressionProcesses=@([pscustomobject]@{Name='spotify';Pid=1;RamMB=1;CpuPct=0;HasWindow=$true;Suggestion='Opcional';Path='C:\Fixture\spotify.exe';Optional=$true})
        $global:JunoRegressionAction={param($form)
            (Get-RegressionGrid $form).Rows[0].Selected=$true
            (Get-RegressionButton $form 'Solicitar cierre normal').Enabled|Should Be $true
            (Get-RegressionButton $form 'Finalizar opcional (riesgo)').Enabled|Should Be $true
            Invoke-RegressionClick (Get-RegressionButton $form 'Solicitar cierre normal')
            $global:JunoRegressionMessages.Count|Should Be 1
        }
        Show-BackgroundManager $null
    }
    It 'inicio conserva entradas de equipo en solo lectura y comunica error al actualizar' {
        Mock Get-StartupEntries {@([pscustomobject]@{Name='Equipo';Editable=$false;State='Activo';Origin='Equipo';Publisher='Fixture';Recommendation='Revisar';Command='C:\Carpeta con espacios\app.exe'})}
        $global:JunoRegressionAction={param($form)
            (Get-RegressionGrid $form).Rows[0].Cells[0].ReadOnly|Should Be $true
            Mock Get-StartupEntries {throw 'Fixture: lectura fallida'}
            Invoke-RegressionClick (Get-RegressionButton $form 'Actualizar lista')
            $script:StartupStatus.Text|Should Match 'Error de lectura; lista incompleta'
        }
        Show-StartupManager $null
        $script:StartupDialog|Should BeNullOrEmpty
    }
    It 'discos diferencia administrador, salud y TRIM' -TestCases @(@{Admin=$false;Health='Healthy';Optimize=$false;Trim=$false},@{Admin=$true;Health='Healthy';Optimize=$true;Trim=$true},@{Admin=$true;Health='Warning';Optimize=$false;Trim=$true}) {
        param($Admin,$Health,$Optimize,$Trim)
        $global:JunoRegressionAdmin=$Admin;$global:JunoRegressionOptimize=$Optimize;$global:JunoRegressionTrim=$Trim
        $global:JunoRegressionVolumes=@([pscustomobject]@{Letter='C';Label='Fixture';Media='SSD';Size=1000;Free=500;Health=$Health;FileSystem='NTFS';DiskNumber=$null;Bus='Fixture';Model='Fixture'})
        $global:JunoRegressionAction={param($form)
            (Get-RegressionButton $form 'Optimizar unidad (/O)').Enabled|Should Be $global:JunoRegressionOptimize
            (Get-RegressionButton $form 'Habilitar TRIM NTFS').Enabled|Should Be $global:JunoRegressionTrim
            (Get-RegressionButton $form 'Restaurar TRIM anterior').Enabled|Should Be $false
        }
        Show-DiskManager $null
        $script:DiskDialog|Should BeNullOrEmpty;$script:DiskTimer|Should BeNullOrEmpty
    }
    It 'lectura de discos fallida libera el dialogo para reabrir' {
        Mock Get-DiskVolumes {throw 'Fixture: hardware inaccesible'}
        {Show-DiskManager $null}|Should Throw
        $script:DiskDialog|Should BeNullOrEmpty;$script:DiskTimer|Should BeNullOrEmpty
    }
    It 'analisis lento no bloquea el evento ni admite un segundo analisis y se cancela sin acciones' {
        $global:JunoRegressionAction={param($form)
            Invoke-RegressionClick (Get-RegressionButton $form 'Analizar')
            (Get-RegressionButton $form 'Revisar en Windows').Enabled|Should Be $false
            Invoke-RegressionClick (Get-RegressionButton $form 'Cancelar analisis')
            $global:JunoRegressionScan.CancelRequested|Should Be $true
            # Recoger el resultado cancelado mediante el mismo callback del timer.
            $global:JunoRegressionScan.Complete=$true
            $timer=$ExecutionContext.SessionState.PSVariable.GetValue('scanTimer')
            [void]$timer.GetType().GetMethod('OnTick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($timer,@([EventArgs]::Empty))
            (Get-RegressionButton $form 'Analizar').Enabled|Should Be $true
        }
        Show-CleanupManager $null
        Assert-MockCalled Start-CleanupScan -Times 1 -Exactly -Scope It
        Assert-MockCalled Receive-CleanupScan -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'cerrar durante la consulta pide cancelar y espera el resultado antes de disponer controles' {
        $global:JunoRegressionAction={param($form)
            Invoke-RegressionClick (Get-RegressionButton $form 'Analizar')
            $args=[Windows.Forms.FormClosingEventArgs]::new([Windows.Forms.CloseReason]::UserClosing,$false)
            [void]$form.GetType().GetMethod('OnFormClosing',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($form,@($args))
            $args.Cancel|Should Be $true;$global:JunoRegressionScan.CancelRequested|Should Be $true
            $form.IsDisposed|Should Be $false;$global:JunoRegressionScan.Complete=$true
            $timer=$ExecutionContext.SessionState.PSVariable.GetValue('scanTimer')
            [void]$timer.GetType().GetMethod('OnTick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($timer,@([EventArgs]::Empty))
            $global:JunoRegressionScan.Disposed|Should Be $true
        }
        Show-CleanupManager $null
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}

Describe 'Herramientas nativas y carga de dependencias' {
    BeforeEach {Mock Test-Path {$true};Mock Get-JunoRuntimeArchitecture {[pscustomobject]@{OS64=$true;Process64=$true}}}
    It 'resuelve la vista nativa sin depender de PATH' -TestCases @(@{OS64=$true;Process64=$true;Directory='System32'},@{OS64=$true;Process64=$false;Directory='Sysnative'},@{OS64=$false;Process64=$false;Directory='System32'}) {
        param($OS64,$Process64,$Directory)
        $global:JunoRegressionArchitecture=[pscustomobject]@{OS64=$OS64;Process64=$Process64};Mock Get-JunoRuntimeArchitecture {$global:JunoRegressionArchitecture}
        Get-JunoSystemTool 'fsutil.exe'|Should Be (Join-Path $env:WINDIR ($Directory+'\fsutil.exe'))
        {Get-JunoSystemTool 'cmd.exe'}|Should Throw
    }
    It 'herramienta ausente produce error comprensible antes de ejecutarla' {
        Mock Test-Path {$false};{Get-JunoSystemTool 'powercfg.exe'}|Should Throw
    }
    It 'todos los archivos cargados existen y el mutex precede a las consultas de UI' {
        $source=[IO.File]::ReadAllText((Join-Path $regressionRoot 'Juno.ps1'))
        $dependencies=$source+[IO.File]::ReadAllText((Join-Path $regressionRoot 'Inicio.ps1'))+[IO.File]::ReadAllText((Join-Path $regressionRoot 'TransparencyOperations.ps1'))
        foreach($file in @('PowerOperations.ps1','TransparencyOperations.ps1','VisualEffectsOperations.ps1','VisualInterop.ps1','UiSupport.ps1','BackupStore.ps1','RecoveryOperations.ps1','BackgroundInventory.ps1','StartupOperations.ps1','Inicio.ps1','Limpieza.ps1','Discos.ps1','SegundoPlano.ps1','PermisosUsuario.ps1','PermisosSegundoPlano.ps1')){
            [IO.File]::Exists((Join-Path $regressionRoot $file))|Should Be $true
            $dependencies.Contains("'"+$file+"'")|Should Be $true
        }
        ($source.IndexOf('try { Enter-JunoLease }') -lt $source.IndexOf('# ----------------------- INTERFAZ GRAFICA'))|Should Be $true
        $launcher=[IO.File]::ReadAllText((Join-Path $regressionRoot 'Abrir-Juno.cmd'))
        $launcher|Should Match 'Sysnative';$launcher|Should Match '"%~dp0Juno.ps1"';$launcher|Should Match '\-STA'
    }
    It 'bootstrap completo carga modulos desde una ruta con espacios sin Registro ni ventana reales' {
        $folder=Join-Path $TestDrive 'JUNO con espacios';[void][IO.Directory]::CreateDirectory($folder)
        foreach($file in @('PowerOperations.ps1','TransparencyOperations.ps1','VisualEffectsOperations.ps1','VisualInterop.ps1','UiSupport.ps1','BackupStore.ps1','RecoveryOperations.ps1','BackgroundInventory.ps1','StartupOperations.ps1','Inicio.ps1','Limpieza.ps1','Discos.ps1','SegundoPlano.ps1','PermisosUsuario.ps1','PermisosSegundoPlano.ps1')){
            [IO.File]::Copy((Join-Path $regressionRoot $file),(Join-Path $folder $file))
        }
        $source=[IO.File]::ReadAllText((Join-Path $regressionRoot 'Juno.ps1'))
        $sharedNeedle=". (Join-Path `$PSScriptRoot 'TransparencyOperations.ps1')"
        $source=$source.Replace($sharedNeedle,$sharedNeedle+"`r`nfunction Get-TransparencyState {return `$null}")
        $source=$source.Replace('try { Enter-JunoLease }',"try { Enter-JunoLease ('Local\Juno.Tests.Boot.'+[Guid]::NewGuid().ToString('N')) }")
        $barriers=@'
function Read-JunoStore {throw 'TEST: respaldo real prohibido'}
function Write-JunoStore {throw 'TEST: respaldo real prohibido'}
function Get-JunoIdentity {throw 'TEST: Registro real prohibido'}
function Invoke-PowerCfg {throw 'TEST: proceso real prohibido'}
'@
        $needle=". (Join-Path `$PSScriptRoot 'PermisosSegundoPlano.ps1')"
        $source=$source.Replace($needle,$needle+"`r`n"+$barriers)
        $source=$source.Replace('[void][System.Windows.Forms.Application]::Run($form)',"if(`$form.Controls.Count -lt 4){throw 'TEST: UI incompleta'}; [void]`$form.GetType().GetMethod('OnShown',[Reflection.BindingFlags]'Instance,NonPublic').Invoke(`$form,@([EventArgs]::Empty)); 'BOOT_OK'; `$form.Close()")
        if($source -match 'Application\]::Run\('){throw 'TEST: Application.Run no sustituido'}
        $target=Join-Path $folder 'Juno.ps1';[IO.File]::WriteAllText($target,$source,[Text.UTF8Encoding]::new($true))
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $info.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$target+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $child=[Diagnostics.Process]::new();$child.StartInfo=$info
        try {
            [void]$child.Start();$output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
            if(-not $child.WaitForExit(20000)){$child.Kill();throw 'TEST: bootstrap no termino'}
            $detail=$output.Result+$errorOutput.Result
            if($child.ExitCode -ne 0){throw $detail}
            $detail|Should Match 'BOOT_OK'
        }finally{$child.Dispose()}
    }
}

# En este Describe se usan runspaces reales y archivos privados; no se llama a Papelera.
$originalScanBatch=(Get-Command Get-CleanupScanBatch).ScriptBlock.ToString()
Describe 'Analisis asincrono de solo lectura en runspace real' {
    BeforeEach {
        . ([scriptblock]::Create('function Get-CleanupScanBatch {'+$originalScanBatch+'}'))
        $folder=Join-Path $TestDrive 'Archivos con espacios';[void][IO.Directory]::CreateDirectory($folder)
        $file=Join-Path $folder 'antiguo.tmp';[IO.File]::WriteAllText($file,'fixture')
        [IO.File]::SetCreationTimeUtc($file,[DateTime]::UtcNow.AddDays(-30));[IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddDays(-30))
        $global:JunoRegressionSpec=[pscustomobject]@{Id='Usuario';Name='Fixture';Root=$folder;Days=7;Pattern='\.tmp$';Action='Storage'}
        Mock Get-CleanupSpecs {$global:JunoRegressionSpec}
        $script:RegressionOperation=$null
    }
    AfterEach {
        if($null -ne $script:RegressionOperation -and -not $script:RegressionOperation.Disposed){$script:RegressionOperation.Pipe.Dispose();$script:RegressionOperation.Runspace.Dispose()}
    }
    It 'devuelve una instantanea sin modificar archivos y libera recursos' {
        $script:RegressionOperation=Start-CleanupScan
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-CleanupScanComplete $script:RegressionOperation) -and [DateTime]::UtcNow -lt $deadline){[Threading.Thread]::Sleep(10)}
        $result=Receive-CleanupScan $script:RegressionOperation
        $result.Status|Should Be 'Completed';$result.Items.Count|Should Be 1;$result.Items[0].Scan.Count|Should Be 1
        [IO.File]::ReadAllText($file)|Should Be 'fixture';$script:RegressionOperation.Disposed|Should Be $true
    }
    It 'cancelar descarta la instantanea sin escritores ni controles compartidos' {
        $script:RegressionOperation=Start-CleanupScan;Stop-CleanupScan $script:RegressionOperation
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-CleanupScanComplete $script:RegressionOperation) -and [DateTime]::UtcNow -lt $deadline){[Threading.Thread]::Sleep(10)}
        (Receive-CleanupScan $script:RegressionOperation).Status|Should Be 'Cancelled'
        [IO.File]::ReadAllText($file)|Should Be 'fixture';$script:RegressionOperation.Disposed|Should Be $true
    }
    It 'una categoria inaccesible produce resultado parcial legible y conserva el archivo' {
        $global:JunoRegressionSpec.Root=Join-Path $TestDrive 'Carpeta inexistente'
        $script:RegressionOperation=Start-CleanupScan
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-CleanupScanComplete $script:RegressionOperation) -and [DateTime]::UtcNow -lt $deadline){[Threading.Thread]::Sleep(10)}
        $result=Receive-CleanupScan $script:RegressionOperation
        $result.Status|Should Be 'Completed';$result.Items[0].Scan.Failed|Should Be 1;$result.Items[0].Scan.Available|Should Be $false
        [IO.File]::ReadAllText($file)|Should Be 'fixture'
    }
    It 'cancelacion concurrente con finalizacion no genera un error espurio' {
        $operation=[pscustomobject]@{Disposed=$false;CancelRequested=$false;Handle=[pscustomobject]@{IsCompleted=$false};Stopping=$null;Pipe=[pscustomobject]@{}}
        $operation.Pipe|Add-Member NoteProperty Operation $operation
        $operation.Pipe|Add-Member ScriptMethod BeginStop {$this.Operation.Handle.IsCompleted=$true;throw 'Fixture: ya termino'}
        {Stop-CleanupScan $operation}|Should Not Throw
        $operation.CancelRequested|Should Be $true
    }
    It 'errores del trabajador llegan como estado de error y no como exito' {
        function Get-CleanupScanBatch {throw 'Fixture: fallo del trabajador'}
        $script:RegressionOperation=Start-CleanupScan
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-CleanupScanComplete $script:RegressionOperation) -and [DateTime]::UtcNow -lt $deadline){[Threading.Thread]::Sleep(10)}
        $result=Receive-CleanupScan $script:RegressionOperation;$result.Status|Should Be 'Error';$result.Message|Should Match 'fallo del trabajador'
        $script:RegressionOperation.Disposed|Should Be $true
    }
}
