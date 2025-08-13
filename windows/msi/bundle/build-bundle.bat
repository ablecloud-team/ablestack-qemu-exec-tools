@echo off
REM Build bootstrapper EXE that includes Cloudbase-Init MSI and AbleStack MSI
setlocal
set WIX=%ProgramFiles%\WiX Toolset v4.0\bin
if not exist "%WIX%\candle.exe" (
  echo [ERROR] WiX v4 candle.exe not found. Adjust WIX path.
  exit /b 1
)
set OUT=%~dp0out
if not exist "%OUT%" mkdir "%OUT%"
echo [INFO] Compiling Bundle...
"%WIX%\candle.exe" -ext WixToolset.Bal.wixext -out "%OUT%\" "%~dp0Bundle.wxs" || goto :err
echo [INFO] Linking Bundle...
"%WIX%\light.exe" -ext WixToolset.Bal.wixext -out "%OUT%\AbleStack-CloudInit-Setup.exe" "%OUT%\Bundle.wixobj" || goto :err
echo [OK] Built bootstrapper: %OUT%\AbleStack-CloudInit-Setup.exe
echo NOTE: Ensure Packages\Cloudbase-Init-x64.msi exists and windows\msi\out\AbleStack-CloudInit-Automator.msi is built before bundling.
exit /b 0
:err
echo [ERROR] Bundle build failed.
exit /b 1