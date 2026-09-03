# Build PeanutButter for Windows and zip it into dist\
# Run from a Windows machine with Flutter installed:
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Front = Join-Path $Root "frontend"
$Dist = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

Set-Location $Front
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release

$src = Join-Path $Front "build\windows\x64\runner\Release"
$zip = Join-Path $Dist "PeanutButter-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $src "*") -DestinationPath $zip -Force
Write-Host "Wrote $zip"
Write-Host "Unzip and run peanutbutter.exe"
