@echo off
REM ============================================
REM AutoVPN Build Script
REM Converts AutoVPN.ps1 to AutoVPN.exe
REM ============================================
REM Prerequisites: Install-Module -Name ps2exe -Scope CurrentUser -Force
REM ============================================

echo.
echo  =============================
echo   AutoVPN Build
echo  =============================
echo.

REM Kill AutoVPN.exe if running
tasklist /FI "IMAGENAME eq AutoVPN.exe" 2>nul | find /I "AutoVPN.exe" >nul
if %ERRORLEVEL% EQU 0 (
    echo  [..] Stopping AutoVPN.exe...
    taskkill /F /IM AutoVPN.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
)

echo  [..] Building AutoVPN.exe ...
echo.

powershell -ExecutionPolicy Bypass -Command ^
  "Invoke-PS2EXE -InputFile '%~dp0AutoVPN.ps1' -OutputFile '%~dp0AutoVPN.exe' -IconFile '%~dp0AutoVPN.ico' -Title 'AutoVPN' -Description 'VMware SSL VPN-Plus Auto-Connect' -Company 'AutoVPN' -Product 'AutoVPN' -Version '2.0.0.0' -Copyright '2025' -NoConsole -STA"

echo.
if exist "%~dp0AutoVPN.exe" (
    echo  [OK] Build successful!
    for %%A in ("%~dp0AutoVPN.exe") do echo  [OK] AutoVPN.exe - %%~zA bytes
    echo.
    echo  You can now copy AutoVPN.exe anywhere and run it.
    echo  Just keep AutoVPN.ico in the same folder ^(optional^).
) else (
    echo  [FAIL] Build failed!
    echo.
    echo  Make sure ps2exe is installed:
    echo    Install-Module -Name ps2exe -Scope CurrentUser -Force
)
echo.
pause
