@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "result=%ERRORLEVEL%"
if "%result%"=="0" echo [OK] ABLESTACK Tools installation completed.
if "%result%"=="3010" echo [REBOOT] ABLESTACK Tools installation completed; restart Windows.
if not "%result%"=="0" if not "%result%"=="3010" echo [ERROR] ABLESTACK Tools installation failed with code %result%.
echo Installation log: %ProgramData%\ABLESTACK-Tools\install.log
if /I "%SESSIONNAME%"=="Console" if not defined ABLESTACK_TOOLS_NO_PAUSE pause
exit /b %result%
