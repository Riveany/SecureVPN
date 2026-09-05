@echo off
REM AutoVPN v2.0 Launcher
REM Starts the AutoVPN GUI (hides console window)
REM %~dp0 is this file's own folder, so the launcher works from any location.
powershell -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AutoVPN.ps1" %*
