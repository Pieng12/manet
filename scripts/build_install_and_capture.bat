@echo off
setlocal enabledelayedexpansion

REM build_install_and_capture.bat
REM Usage:
REM   1) Build+install+capture (default): build_install_and_capture.bat [device_serial] [release|debug]
REM   2) Capture-only (no build/install): build_install_and_capture.bat [device_serial] capture-only

set DEVICE=%1
set MODE=%2
if "%MODE%"=="" set MODE=release

echo ===== ResQMesh build/install/log-capture helper =====
adb version >nul 2>&1
if errorlevel 1 (
  echo ERROR: adb not found in PATH. Please install Android platform-tools and add to PATH.
  pause
  exit /b 1
)

echo Connected devices:
adb devices

if "%DEVICE%"=="" (
  echo No device serial provided. Will pick the first connected device.
  for /f "skip=1 tokens=1" %%a in ('adb devices') do (
    if not "%%a"=="" (
      set DEVICE=%%a
      goto deviceFound
    )
  )
  echo No device detected. Please connect a device and enable USB debugging.
  pause
  exit /b 1
)

:deviceFound
echo Using device: %DEVICE%

if /I "%MODE%"=="capture-only" goto capture

if /I "%MODE%"=="release" (
  echo Building release APK...
  flutter build apk --release || (
    echo ERROR: flutter build failed.
    pause
    exit /b 1
  )
  set APK=build\app\outputs\flutter-apk\app-release.apk
) else (
  echo Building debug APK...
  flutter build apk --debug || (
    echo ERROR: flutter build failed.
    pause
    exit /b 1
  )
  set APK=build\app\outputs\flutter-apk\app-debug.apk
)

if not exist "%APK%" (
  echo ERROR: APK not found at %APK%
  pause
  exit /b 1
)

echo Installing APK to device %DEVICE%...
adb -s %DEVICE% install -r "%APK%" || (
  echo ERROR: adb install failed. You may need to uninstall existing app or check device.
  pause
)

echo Installed successfully.
echo Now you can: open the app, create SOS while offline, then swipe it from recent apps and re-enable network.
echo When ready, press Enter to start log capture (new window will open). Ctrl+C in that window stops capture.
pause>nul

:capture
if not exist C:\temp mkdir C:\temp
echo Starting logcat in new window and saving to C:\temp\resq_log.txt
REM Simpler command: capture full logcat; we can filter later inside the file or in tools.
start "ResQ_Log" cmd /k "adb -s %DEVICE% logcat -v time > C:\temp\resq_log.txt"
echo Logcat window started.
echo Capturing system dumps now to C:\temp
adb -s %DEVICE% shell dumpsys bluetooth_manager > C:\temp\bluetooth_dump.txt
adb -s %DEVICE% shell dumpsys jobscheduler com.example.pkmproject > C:\temp\jobs.txt
adb -s %DEVICE% shell dumpsys package com.example.pkmproject > C:\temp\package_dump.txt
REM On modern Android, use cmd package check-permission
adb -s %DEVICE% shell cmd package check-permission com.example.pkmproject android.permission.BLUETOOTH_SCAN > C:\temp\perm_bluetooth_scan.txt
adb -s %DEVICE% shell cmd package check-permission com.example.pkmproject android.permission.ACCESS_FINE_LOCATION > C:\temp\perm_location.txt
echo Done. Review files in C:\temp after reproducing the problem and stopping the log window.
echo Optional: rerun dumpsys after you re-enable network to capture state changes.
echo Script finished. Press any key to exit.
pause>nul
endlocal
exit /b 0


