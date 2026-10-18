@echo off
setlocal
set "junoPreviewPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "junoPreviewPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%junoPreviewPowerShell%" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Juno-Prototipo.ps1"
set "junoPreviewExit=%errorlevel%"
if errorlevel 1 (
  echo No se pudo abrir el prototipo. Abre Juno-Prototipo.ps1 desde Windows PowerShell para leer el error.
  pause
)
exit /b %junoPreviewExit%
