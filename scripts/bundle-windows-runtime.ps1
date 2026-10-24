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

# Bundle the NEWEST x64 CRT, matching the compiler. Visual Studio keeps old
# redist folders too (e.g. 14.29 / VC142) and the first one found used to win.
# Code built with VS 2022 17.10+ initialises std::mutex differently and an
# older msvcp140.dll (< 14.40) crashes with 0xc0000005 on the first lock:
# that was the Windows crash when a stream started.
$crt = $null
$candidates = foreach ($root in $roots) {
  Get-ChildItem -Path $root -Recurse -Filter "msvcp140.dll" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT\\msvcp140\.dll$' -and
      $_.FullName -notmatch '\\onecore\\' -and
      $_.FullName -notmatch 'debug_nonredist'
    }
}
if ($candidates) {
  $crt = $candidates |
    Sort-Object { [version]$_.VersionInfo.FileVersionRaw } -Descending |
    Select-Object -First 1
}

if ($null -ne $crt) {
  Copy-Item -Force (Join-Path $crt.DirectoryName "*.dll") $ReleaseDir
  Write-Host "Bundled VC++ CRT $($crt.VersionInfo.FileVersionRaw) from $($crt.DirectoryName)"
} else {
  Write-Warning "Visual C++ CRT folder was not found. The installer will fail on PCs that do not already have the VC++ 2015-2022 x64 redistributable."
}

$bundled = Join-Path $ReleaseDir "msvcp140.dll"
if (Test-Path $bundled) {
  $v = [version](Get-Item $bundled).VersionInfo.FileVersionRaw
  if ($v -lt [version]"14.40.0.0") {
    throw "Bundled msvcp140.dll is $v; builds from current Visual Studio need 14.40 or newer (older ones crash in std::mutex)."
  }
  Write-Host "msvcp140.dll version check passed ($v)"
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
    Where-Object { $_ -match '^[\w.-]+\.dll$' }  # bare names only, not the "Dump of file C:\...dll" header
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
