@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Crear-acceso-directo.ps1"
if errorlevel 1 echo No se pudo crear el acceso directo.
pause
