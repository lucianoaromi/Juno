$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
$destination = [Environment]::GetFolderPath('DesktopDirectory')
if (-not $destination) { throw 'No se pudo detectar el escritorio.' }
$target = Join-Path $folder 'Abrir-Juno.cmd'
$icon = Join-Path $folder 'Juno.ico'
if (-not (Test-Path -LiteralPath $target)) { throw 'No se encontro Abrir-Juno.cmd.' }
if (-not (Test-Path -LiteralPath $icon)) { throw 'No se encontro Juno.ico.' }
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $destination 'JUNO.lnk'))
$link.TargetPath = $target
$link.WorkingDirectory = $folder
$link.IconLocation = "$icon,0"
$link.Description = 'JUNO - Herramientas de rendimiento para Windows'
$link.Save()
Write-Host "Acceso directo creado: $(Join-Path $destination 'JUNO.lnk')"
Write-Host 'Importante: no muevas ni elimines la carpeta JUNO o el acceso directo dejara de funcionar.'
