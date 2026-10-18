# JUNO: soporte de ventanas y herramientas. Importar no consulta ni modifica Windows.
function Get-JunoRuntimeArchitecture {
    return [pscustomobject]@{OS64=[Environment]::Is64BitOperatingSystem;Process64=[Environment]::Is64BitProcess}
}
function Get-JunoSystemTool([ValidateSet('powercfg.exe','fsutil.exe','defrag.exe','SystemPropertiesPerformance.exe','dfrgui.exe','taskmgr.exe','control.exe','cleanmgr.exe')][string]$name) {
    $architecture=Get-JunoRuntimeArchitecture
    $directory=if($architecture.OS64 -and -not $architecture.Process64){'Sysnative'}else{'System32'}
    $path=Join-Path $env:WINDIR ($directory+'\'+$name)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Herramienta de Windows no disponible: $name. Revisa la instalacion o usa Configuracion de Windows."}
    return $path
}
function Get-JunoWindowArea($parent) {
    if($null -ne $parent){return [Windows.Forms.Screen]::FromControl($parent).WorkingArea}
    return [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
}
function Limit-JunoWindow($window,[Drawing.Rectangle]$area) {
    # El contenido conserva sus coordenadas y se alcanza con las barras si no cabe.
    $border=$window.Size-$window.ClientSize
    $width=[Math]::Max(1,$area.Width-$border.Width-24)
    $height=[Math]::Max(1,$area.Height-$border.Height-24)
    $desired=$window.ClientSize
    if($desired.Width -gt $width -or $desired.Height -gt $height){
        $window.MinimumSize=[Drawing.Size]::Empty
        $window.ClientSize=[Drawing.Size]::new([Math]::Min($desired.Width,$width),[Math]::Min($desired.Height,$height))
    }
    $window.StartPosition='Manual'
    $window.Location=[Drawing.Point]::new($area.Left+[Math]::Max(0,[int](($area.Width-$window.Width)/2)),$area.Top+[Math]::Max(0,[int](($area.Height-$window.Height)/2)))
}
function Initialize-JunoWindow($window,$parent=$null) {
    $window.AutoScroll=$true
    $window.AutoScrollMinSize=$window.ClientSize
    # No cambia la configuracion DPI de powershell.exe ni promete PerMonitorV2.
    # Se conserva el escalado del host; el limite se calcula despues de mostrar/escalar.
    $tip=New-Object Windows.Forms.ToolTip
    $tip.ShowAlways=$true;$tip.AutoPopDelay=20000
    $pending=New-Object 'Collections.Generic.Queue[object]';$pending.Enqueue($window)
    while($pending.Count){
        $container=$pending.Dequeue()
        foreach($control in $container.Controls){
            if($control -is [Windows.Forms.Label]){$control.AutoEllipsis=$true}
            if($control -is [Windows.Forms.Label] -or $control -is [Windows.Forms.Button]){
                $tip.SetToolTip($control,$control.Text)
                $control.Add_MouseEnter({param($sender,$e) $tip.SetToolTip($sender,$sender.Text)}.GetNewClosure())
            }
            if($control.HasChildren){$pending.Enqueue($control)}
        }
    }
    $window.Add_Disposed({$tip.Dispose()}.GetNewClosure())
    # GetNewClosure crea un modulo dinamico: capturar el bloque evita depender
    # de que las funciones del script llamador sean visibles desde ese modulo.
    $area=Get-JunoWindowArea $parent
    $limit=(Get-Command Limit-JunoWindow -CommandType Function).ScriptBlock
    $window.Add_Shown({& $limit $window $area}.GetNewClosure())
    Limit-JunoWindow $window $area
}
