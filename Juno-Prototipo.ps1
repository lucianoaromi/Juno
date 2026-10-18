#requires -Version 5.1
# JUNO v0.9: interfaz independiente; motores aislados detrás del adaptador.
[CmdletBinding()]
param([switch]$LoadOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('Juno.Preview.ShellForm' -as [type])) {
    $files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs','ui\DashboardWorker.cs','ui\TransparencyModel.cs','ui\PowerShellTransparencyService.cs','ui\TransparencyConfirmation.cs','ui\JunoShell.cs')|ForEach-Object{Join-Path $PSScriptRoot $_}
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
if ($LoadOnly) { return }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Abre Abrir-Juno-Prototipo.cmd para iniciar la interfaz en modo STA.'
}
# Solo afecta al proceso nuevo. No cambia pantalla, Registro ni configuracion del host.
[Juno.Preview.PreviewHost]::Initialize()
$query=New-Object Juno.Preview.ProcessDashboardQuery((Join-Path $PSHOME 'powershell.exe'),(Join-Path $PSScriptRoot 'Juno-DashboardWorker.ps1'))
$dashboard=New-Object Juno.Preview.DashboardController($query)
$transparency=New-Object Juno.Preview.TransparencyController((New-Object Juno.Preview.PowerShellTransparencyService($PSScriptRoot)))
$window = $null
try {
    $window=New-Object Juno.Preview.ShellForm($PSScriptRoot,$dashboard,$transparency,$null)
    [Windows.Forms.Application]::Run($window)
}
finally { if($null -ne $window){$window.Dispose()};$dashboard.Dispose();$transparency.Dispose() }
