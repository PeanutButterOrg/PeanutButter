# Copy the VC++ runtime next to peanutbutter.exe and fail if playback /
# torrent libraries are missing. Run after `flutter build windows`.
param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseDir
)

$ErrorActionPreference = "Stop"
$ReleaseDir = (Resolve-Path $ReleaseDir).Path
if (-not (Test-Path (Join-Path $ReleaseDir "peanutbutter.exe"))) {
  throw "peanutbutter.exe not found in $ReleaseDir"
}

$roots = @(
  "${env:ProgramFiles}\Microsoft Visual Studio",
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
) | Where-Object { $_ -and (Test-Path $_) }

$crt = $null
foreach ($root in $roots) {
  $crt = Get-ChildItem -Path $root -Recurse -Filter "vcruntime140.dll" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT\\vcruntime140\.dll$' } |
    Select-Object -First 1
  if ($null -ne $crt) { break }
}

if ($null -ne $crt) {
  Copy-Item -Force (Join-Path $crt.DirectoryName "*.dll") $ReleaseDir
  Write-Host "Bundled VC++ CRT from $($crt.DirectoryName)"
} else {
  Write-Warning "Visual C++ CRT folder was not found. The installer will fail on PCs that do not already have the VC++ 2015-2022 x64 redistributable."
}

$required = @(
  "flutter_windows.dll",
  "libmpv-2.dll",
  "libEGL.dll",
  "libGLESv2.dll",
  "libtorrent_flutter.dll",
  "vcruntime140.dll",
  "vcruntime140_1.dll",
  "msvcp140.dll"
)
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $ReleaseDir $_)) })
if ($missing.Count -gt 0) {
  Write-Host "Files in ${ReleaseDir}:"
  Get-ChildItem $ReleaseDir | Select-Object -ExpandProperty Name
  throw "Windows build is missing libraries required to launch: $($missing -join ', ')"
}

# libtorrent_flutter.dll is built against a static vcpkg libtorrent + OpenSSL
# (no torrent-rasterbar / libssl DLLs). Check its real imports so a change
# in how it links can't ship a build that fails to start.
$dumpbin = $null
foreach ($root in $roots) {
  $dumpbin = Get-ChildItem -Path $root -Recurse -Filter "dumpbin.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Hostx64\\x64\\dumpbin\.exe$' } |
    Select-Object -First 1
  if ($null -ne $dumpbin) { break }
}
if ($null -ne $dumpbin) {
  $imports = & $dumpbin.FullName /DEPENDENTS (Join-Path $ReleaseDir "libtorrent_flutter.dll") |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '\.dll$' }
  $systemDll = '^(?i)(kernel32|user32|advapi32|ws2_32|iphlpapi|crypt32|bcrypt|mswsock|dbghelp|ole32|shell32|secur32|ntdll|rpcrt4|shlwapi|version|userenv|api-ms-win-.*|ucrtbase|vcruntime140(_1)?|msvcp140(_\w+)?)\.dll$'
  $unshipped = @($imports | Where-Object {
    ($_ -notmatch $systemDll) -and -not (Test-Path (Join-Path $ReleaseDir $_))
  })
  Write-Host "libtorrent_flutter.dll imports: $($imports -join ', ')"
  if ($unshipped.Count -gt 0) {
    throw "libtorrent_flutter.dll needs DLLs that are not bundled: $($unshipped -join ', ')"
  }
} else {
  Write-Warning "dumpbin.exe not found; skipped the libtorrent_flutter.dll import check."
}
Write-Host "Windows runtime libraries are present."
