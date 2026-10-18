#requires -Version 5.1
# Trabajador privado de lectura. No importa motores ni admite comandos externos.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$files=@('ui\DashboardModel.cs','ui\WindowsSystemSource.cs')|ForEach-Object{Join-Path $PSScriptRoot $_}
Add-Type -Path $files -ReferencedAssemblies System.Management,System.Web.Extensions
$reader=New-Object Juno.Preview.WindowsReadApi
# Las lecturas rápidas se publican antes de consultar proveedores WMI lentos.
foreach($key in @('ram','disk','power','os','cpu')) {
    $reading=[Juno.Preview.DashboardCollector]::Read($key,$reader)
    [Console]::Out.WriteLine([Juno.Preview.DashboardWire]::Encode($reading))
    [Console]::Out.Flush()
}
