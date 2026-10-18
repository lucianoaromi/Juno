#requires -Version 5.1
# JUNO v0.9: prototipo visual independiente, sin importar motores de v0.8.1.
[CmdletBinding()]
param([switch]$LoadOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('Juno.Preview.ShellForm' -as [type])) {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui\JunoShell.cs'))
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms,System.Drawing
}
if ($LoadOnly) { return }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Abre Abrir-Juno-Prototipo.cmd para iniciar la interfaz en modo STA.'
}
# Solo afecta al proceso nuevo. No cambia pantalla, Registro ni configuracion del host.
[Juno.Preview.PreviewHost]::Initialize()
$window = New-Object Juno.Preview.ShellForm($PSScriptRoot)
try { [Windows.Forms.Application]::Run($window) }
finally { $window.Dispose() }
