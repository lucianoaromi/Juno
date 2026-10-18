#requires -Version 5.1
# Prototipo aislado: controles en memoria, sin operaciones de Windows ni navegador.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$previewRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $previewRoot 'Juno-Prototipo.ps1') -LoadOnly

function Get-PreviewControls($control) {
    foreach($child in $control.Controls){$child;Get-PreviewControls $child}
}
function Test-PreviewLayout($control) {
    foreach($child in $control.Controls){
        if($control.Name -notin @('ContentViewport','Sidebar')){
            ($child.Left -ge 0)|Should Be $true
            ($child.Top -ge 0)|Should Be $true
            ($child.Right -le $control.ClientSize.Width+1)|Should Be $true
            ($child.Bottom -le $control.ClientSize.Height+1)|Should Be $true
        }
        if($child -is [Windows.Forms.Label] -and $child.AutoSize){
            ($child.Height -ge $child.GetPreferredSize((New-Object Drawing.Size($child.Width,0))).Height)|Should Be $true
        }
        Test-PreviewLayout $child
    }
    $children=@($control.Controls)
    for($i=0;$i -lt $children.Count;$i++){
        for($j=$i+1;$j -lt $children.Count;$j++){
            if($children[$i].Bounds.IntersectsWith($children[$j].Bounds)){throw ('Solapamiento en '+$control.Name+': '+$children[$i].Name+' '+$children[$i].Text+' / '+$children[$j].Name+' '+$children[$j].Text)}
        }
    }
}

Describe 'JUNO v0.9: shell visual independiente' {
    BeforeEach {$script:preview=New-Object Juno.Preview.ShellForm($previewRoot)}
    AfterEach {if($null -ne $script:preview){$script:preview.Dispose()}}

    It 'inicia en Inicio con seis destinos sin inventar lecturas' {
        $preview.SelectedSection|Should Be 'Inicio'
        $controls=@(Get-PreviewControls $preview)
        @($controls|Where-Object{$_ -is [Windows.Forms.Button] -and $_.Name -like 'Nav*'}).Count|Should Be 6
        ($controls.Text -join ' ')|Should Match 'LECTURA DEL SISTEMA'
        ($controls.Text -join ' ')|Should Match 'No disponible'
        ($controls.Text -join ' ')|Should Not Match 'AMD Ryzen 5|Windows 11 Pro|DATOS DE DEMOSTRACIÓN'
        $preview.Dashboard.HasRequested|Should Be $false
    }

    It 'navega a <Section> en el mismo formulario' -TestCases @(
        @{Section='Inicio'},@{Section='Rendimiento'},@{Section='Aplicaciones'},
        @{Section='Mantenimiento'},@{Section='Restauración'},@{Section='Acerca de'}
    ) {
        param($Section)
        $preview.Navigate($Section)
        $preview.SelectedSection|Should Be $Section
        $preview.Controls.Count|Should Be 4
        @($preview.OwnedForms).Count|Should Be 0
        $nav=@(Get-PreviewControls $preview|Where-Object{$_ -is [Windows.Forms.Button] -and $_.Name -like 'Nav*'})
        @($nav|Where-Object{$_.AccessibleDescription -eq 'Sección seleccionada'}).Count|Should Be 1
        @($nav|Where-Object{$_.AccessibleDescription -eq 'Sección seleccionada'})[0].Text|Should Be $Section
    }

    It 'los botones de navegación ejecutan el cambio de sección' {
        foreach($section in [Juno.Preview.ShellForm]::Sections){
            $button=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq ('Nav'+$section)})[0]
            $method=$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
            [void]$method.Invoke($button,@([EventArgs]::Empty))
            $preview.SelectedSection|Should Be $section
        }
    }

    It 'actualizar inicia una sola consulta sin abrir ventanas' {
        $button=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'RefreshInformation'})[0]
        [void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $preview.SelectedSection|Should Be 'Inicio'
        $preview.Dashboard.HasRequested|Should Be $true
        $preview.Dashboard.IsBusy|Should Be $true
        $preview.RefreshInformation()|Should Be $false
        @($preview.OwnedForms).Count|Should Be 0
    }

    It 'mantiene todas las operaciones de herramientas inactivas' {
        $counts=@{'Rendimiento'=3;'Aplicaciones'=3;'Mantenimiento'=2;'Restauración'=3}
        foreach($section in $counts.Keys){
            $preview.Navigate($section)
            $actions=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'ToolAction'})
            $actions.Count|Should Be $counts[$section]
            foreach($action in $actions){$action.Enabled|Should Be $false;$action.Text|Should Be 'Sin conectar'}
        }
    }

    It 'distribuye todas las secciones en <Width>x<Height> sin solapamientos ni texto recortado' -TestCases @(
        @{Width=1180;Height=790},@{Width=940;Height=650},@{Width=700;Height=500}
    ) {
        param($Width,$Height)
        $preview.ClientSize=New-Object Drawing.Size($Width,$Height)
        foreach($section in [Juno.Preview.ShellForm]::Sections){
            $preview.Navigate($section);$preview.PerformLayout()
            Test-PreviewLayout $preview
        }
    }

    It 'reorganiza las tarjetas y ofrece desplazamiento con poco espacio' {
        $preview.ClientSize=New-Object Drawing.Size(1180,790);$preview.Navigate('Inicio')
        $grid=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'Tiles'})[0]
        $grid.Columns|Should Be 3
        $preview.ClientSize=New-Object Drawing.Size(700,500);$preview.PerformLayout()
        $grid.Columns|Should Be 1
        $viewport=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'ContentViewport'})[0]
        $viewport.AutoScroll|Should Be $true
        ($viewport.AutoScrollMinSize.Height -gt $viewport.Height)|Should Be $true
    }

    It 'la barra lateral reserva espacio para el scroll vertical sin scroll horizontal' {
        $preview.ClientSize=New-Object Drawing.Size(700,500)
        $preview.Show();[Windows.Forms.Application]::DoEvents();$preview.PerformLayout()
        $sidebar=$preview.Controls['Sidebar']
        foreach($button in @($sidebar.Controls|Where-Object{$_ -is [Windows.Forms.Button]})){
            ($button.Right -le $sidebar.ClientSize.Width)|Should Be $true
        }
        $sidebar.HorizontalScroll.Visible|Should Be $false
        $preview.Close()
    }

    It 'rechaza una sección desconocida sin alterar la actual' {
        {$preview.Navigate('No existe')}|Should Throw
        $preview.SelectedSection|Should Be 'Inicio'
    }

    It 'mantiene los puntos de cambio de columnas con escala lógica <Scale>' -TestCases @(
        @{Scale=1.0},@{Scale=1.25},@{Scale=1.5},@{Scale=2.0}
    ) {
        param($Scale)
        $grid=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'Tiles'})[0]
        $grid.UiScale=$Scale
        [void]$grid.GetPreferredSize((New-Object Drawing.Size(([int](900*$Scale)),0)))
        $grid.Columns|Should Be 3
        [void]$grid.GetPreferredSize((New-Object Drawing.Size(([int](420*$Scale)),0)))
        $grid.Columns|Should Be 1
    }

    It 'navegar repetidamente dispone la página anterior' {
        $old=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'DashboardToolbar'})[0]
        1..5|ForEach-Object{foreach($section in [Juno.Preview.ShellForm]::Sections){$preview.Navigate($section)}}
        $old.IsDisposed|Should Be $true
        $preview.Controls.Count|Should Be 4
        @($preview.OwnedForms).Count|Should Be 0
    }

    It 'conserva el enlace público del repositorio sin abrirlo en la prueba' {
        $preview.Navigate('Acerca de')
        $link=@(Get-PreviewControls $preview|Where-Object{$_.Name -eq 'GitHub'})[0]
        $link.AccessibleDescription|Should Be 'https://github.com/lucianoaromi/Juno'
    }

    It 'permite abrir el diseño sin recursos opcionales' {
        $other=New-Object Juno.Preview.ShellForm((Join-Path $TestDrive 'Sin icono'))
        try{$other.SelectedSection|Should Be 'Inicio';$other.Text|Should Match 'JUNO v0.9'}finally{$other.Dispose()}
    }

    It 'libera el formulario y sus recursos de manera idempotente' {
        $preview.Dispose();$preview.Dispose()
        $preview.IsDisposed|Should Be $true
        $preview.ResourcesReleased|Should Be $true
    }
}

Describe 'Separación de presentación y operaciones reales' {
    It 'el bootstrap solo carga el shell visual, con entrada independiente' {
        $source=[IO.File]::ReadAllText((Join-Path $previewRoot 'Juno-Prototipo.ps1'))
        $source|Should Not Match 'BackupStore\.ps1|RecoveryOperations\.ps1|Inicio\.ps1|Limpieza\.ps1|Discos\.ps1|SegundoPlano\.ps1|PermisosUsuario\.ps1|PermisosSegundoPlano\.ps1'
        $source|Should Not Match 'Set-ItemProperty|New-Item|Remove-Item|Stop-Process|Invoke-Expression|Invoke-Command'
        $source|Should Match 'ui\\JunoShell.cs'
        (Test-Path -LiteralPath (Join-Path $previewRoot 'Juno.ps1'))|Should Be $true
    }

    It 'el shell no tiene proveedores del sistema ni escritores y solo abre GitHub' {
        $source=[IO.File]::ReadAllText((Join-Path $previewRoot 'ui\JunoShell.cs'))
        $source|Should Not Match 'Microsoft.Win32|ManagementObject|RegistryKey|File.Write|File.Delete|Directory.Create|powercfg.exe|fsutil.exe|defrag.exe|Process.GetProcesses|PerformanceCounter'
        @([regex]::Matches($source,'Process.Start\(')).Count|Should Be 1
        $source|Should Match 'Process.Start\(new ProcessStartInfo\(RepositoryUrl\)'
        $source|Should Match 'const string RepositoryUrl="https://github.com/lucianoaromi/Juno"'
    }

    It 'el lanzador cita rutas con espacios y utiliza Windows PowerShell STA' {
        $source=[IO.File]::ReadAllText((Join-Path $previewRoot 'Abrir-Juno-Prototipo.cmd'))
        $source|Should Match '-NoProfile -STA -ExecutionPolicy Bypass'
        $source|Should Match '-File "%~dp0Juno-Prototipo.ps1"'
        $source|Should Match 'Sysnative'
        $source|Should Match 'exit /b %junoPreviewExit%'
    }

    It 'abre, navega y cierra con el bucle real en un proceso aislado de la misma arquitectura' {
        $rootLiteral=$previewRoot.Replace("'","''")
        $code=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. '__ROOT__\Juno-Prototipo.ps1' -LoadOnly
[Juno.Preview.PreviewHost]::Initialize()
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;
public static class PreviewSmoke {
 public static void Run(Form form) {
  bool shown=false,closed=false,scrolled=false;int steps=0;
  Timer timer=new Timer();timer.Interval=50;
  string[] sections={"Inicio","Rendimiento","Aplicaciones","Mantenimiento","Restauración","Acerca de"};
  timer.Tick+=delegate {
   if(steps==sections.Length){timer.Stop();form.Close();return;}
   form.GetType().GetMethod("Navigate").Invoke(form,new object[]{sections[steps++]});
   ScrollableControl viewport=(ScrollableControl)form.Controls.Find("ContentViewport",true)[0];
   if(steps==1){viewport.AutoScrollPosition=new System.Drawing.Point(0,200);scrolled=viewport.AutoScrollPosition.Y<0;}
   if(steps==2&&viewport.AutoScrollPosition.Y!=0)throw new Exception("Navegar no reinicio el desplazamiento");
  };
  form.Shown+=delegate {shown=true;timer.Start();};
  form.FormClosed+=delegate {closed=true;};
  try{Application.Run(form);}finally{timer.Dispose();form.Dispose();}
  if(!shown||!closed||steps!=6||!scrolled)throw new Exception("No se completo el ciclo de ventana, desplazamiento y navegacion");
 }
}
"@
$form=New-Object Juno.Preview.ShellForm('__ROOT__')
$form.ClientSize=New-Object Drawing.Size(700,500)
[PreviewSmoke]::Run($form)
if(-not $form.ResourcesReleased){throw 'Recursos sin liberar'}
'PREVIEW_SMOKE_OK'
'@
        $code=$code.Replace('__ROOT__',$rootLiteral)
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $exe=(Get-Process -Id $PID).Path
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$exe;$info.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand '+$encoded
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $child=New-Object Diagnostics.Process
        $child.StartInfo=$info
        try{
            [void]$child.Start()
            $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
            if(-not $child.WaitForExit(20000)){$child.Kill();throw 'Timeout del proceso privado del prototipo'}
            $out=$stdout.Result;$err=$stderr.Result
            if($child.ExitCode -ne 0){throw ('Fallo del prototipo: '+$out+' '+$err)}
            $out|Should Match 'PREVIEW_SMOKE_OK'
        }finally{$child.Dispose()}
    }
}
