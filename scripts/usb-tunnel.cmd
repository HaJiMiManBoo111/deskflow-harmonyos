@echo off
setlocal enabledelayedexpansion
REM ---------------------------------------------------------------
REM  Deskflow HarmonyOS client over USB.
REM
REM  Use this when the HarmonyOS PC and the Windows box sit on a Wi-Fi
REM  that isolates clients: both can ping the gateway and each other's
REM  subnet, but ARP between the two machines never resolves, so the
REM  client times out after ~3 s ("connect failed" every 3 s in hilog).
REM
REM  What it does:
REM    1. finds hdc.exe
REM    2. picks the first connected device
REM    3. hdc rport tcp:24800 tcp:24800   (device 24800 -> Windows 24800)
REM    4. restarts BackGroundAbility pointed at 127.0.0.1:24800
REM
REM  Re-run after unplugging the cable, after "hdc kill", or after a
REM  device reboot: USB forwards do not survive any of those.
REM ---------------------------------------------------------------

set "PKG=com.deskflow.ohospoc"
set "ABILITY=BackGroundAbility"
set "PORT=24800"

set "HDC="
if defined LINGXI_HDC if exist "%LINGXI_HDC%" set "HDC=%LINGXI_HDC%"
if not defined HDC if exist "%ProgramFiles%\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=%ProgramFiles%\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if not defined HDC for /f "delims=" %%i in ('where hdc 2^>nul') do if not defined HDC set "HDC=%%i"
if not defined HDC (
  echo [x] hdc.exe not found.
  echo     Set LINGXI_HDC to its full path, or install DevEco Studio, or put it on PATH.
  exit /b 1
)
echo [i] hdc: %HDC%

set "SERIAL="
for /f "usebackq delims=" %%i in (`"%HDC%" list targets 2^>nul`) do (
  if not defined SERIAL if not "%%i"=="[Empty]" set "SERIAL=%%i"
)
if not defined SERIAL (
  echo [x] No device found. Check the USB cable and that USB debugging is allowed on the device.
  exit /b 1
)
echo [i] device: %SERIAL%

"%HDC%" -t %SERIAL% fport rm tcp:%PORT% tcp:%PORT% >nul 2>&1
"%HDC%" -t %SERIAL% rport tcp:%PORT% tcp:%PORT%
if errorlevel 1 (
  echo [x] rport failed. Is something else listening on device port %PORT%?
  exit /b 1
)

"%HDC%" -t %SERIAL% shell aa start -a %ABILITY% -b %PKG% --ps host 127.0.0.1 --ps port %PORT% --ps autoreconnect true
if errorlevel 1 (
  echo [x] aa start failed. Install the hap first: hdc install -r entry-default-signed.hap
  exit /b 1
)

echo.
echo [i] Client now connects to 127.0.0.1:%PORT% through the USB tunnel.
echo [i] Verify on the Windows side: netstat -ano ^| findstr :%PORT%
echo [i] Re-run this script after unplugging the cable or restarting hdc.
endlocal
