@echo off
REM Build AbleStack CloudInit Automator MSI using WiX Toolset v4
setlocal
set WIX=%ProgramFiles%\WiX Toolset v4.0\bin
if not exist "%WIX%\candle.exe" (
  echo [ERROR] WiX v4 candle.exe not found. Adjust WIX path in build-msi.bat.
  exit /b 1
)
set SRC=%~dp0SourceDir
set OUT=%~dp0out
if not exist "%OUT%" mkdir "%OUT%"
echo [INFO] Compiling...
"%WIX%\candle.exe" -ext WixToolset.Util.wixext -dSourceDir="%SRC%" -out "%OUT%\" "%~dp0Product.wxs" || goto :err
echo [INFO] Linking...
"%WIX%\light.exe" -ext WixToolset.Util.wixext -out "%OUT%\AbleStack-CloudInit-Automator.msi" "%OUT%\Product.wixobj" || goto :err
echo [OK] Built: %OUT%\AbleStack-CloudInit-Automator.msi
exit /b 0
:err
echo [ERROR] Build failed.
exit /b 1