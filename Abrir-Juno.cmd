@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Juno.ps1"
if errorlevel 1 (
  echo Ocurrio un problema al abrir JUNO.
  echo Ejecuta Juno.ps1 desde PowerShell para consultar el error.
  pause
)
