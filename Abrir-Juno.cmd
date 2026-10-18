@echo off
setlocal
set "junoPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "junoPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%junoPowerShell%" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Juno.ps1"
set "junoExit=%errorlevel%"
if errorlevel 1 (
  echo Ocurrio un problema al abrir JUNO.
  echo Ejecuta Juno.ps1 desde PowerShell para consultar el error.
  pause
)
exit /b %junoExit%
