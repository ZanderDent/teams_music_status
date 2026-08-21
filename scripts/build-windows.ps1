<#
.SYNOPSIS
    Builds Teams Music Status for Windows and stages a self-contained folder.

.DESCRIPTION
    The counterpart of scripts/build-app.sh. Produces dist/staging/Teams Music Status/
    containing the executables, the Swift runtime they need, and the install scripts.

    Swift on Windows has no working static stdlib -- `--static-swift-stdlib` is accepted
    and silently does nothing, leaving the binary importing swiftCore.dll -- so the runtime
    has to ship alongside. Rather than copying all 61 MB of it, this walks the actual
    import graph and takes only what is reachable, which is normally a fraction of that.

.PARAMETER Configuration
    debug or release. Defaults to release.

.PARAMETER SkipTests
    Skip the unit tests. They do not need Teams or Spotify, so there is rarely a reason.

.EXAMPLE
    .\scripts\build-windows.ps1
    .\scripts\build-windows.ps1 -Configuration debug -SkipTests
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'release',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$distRoot = Join-Path $repoRoot 'dist'
$stagingRoot = Join-Path $distRoot 'staging'
$appName = 'Teams Music Status'
$stageDir = Join-Path $stagingRoot $appName

# --- version ---------------------------------------------------------------

# VERSION is the single source of truth, shared with the macOS scripts. Parsed rather
# than duplicated so the two platforms can never drift apart.
$versionFile = Join-Path $repoRoot 'VERSION'
if (-not (Test-Path $versionFile)) { throw "VERSION not found at $versionFile" }

$marketingVersion = $null
$buildNumber = $null
foreach ($line in Get-Content $versionFile) {
    if ($line -match '^\s*MARKETING_VERSION\s*=\s*(.+?)\s*$') { $marketingVersion = $Matches[1] }
    if ($line -match '^\s*BUILD_NUMBER\s*=\s*(.+?)\s*$') { $buildNumber = $Matches[1] }
}
if (-not $marketingVersion) { throw 'MARKETING_VERSION missing from VERSION' }
Write-Host "Teams Music Status $marketingVersion (build $buildNumber)" -ForegroundColor Cyan

# --- toolchain -------------------------------------------------------------

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    throw @'
swift was not found on PATH.

Swift on Windows needs the MSVC developer environment as well as the toolchain. Import it
first -- see docs/WINDOWS.md section 10. In short:

  cmd /c '"<VS>\VC\Auxiliary\Build\vcvarsarm64.bat" && set' | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item "Env:$($matches[1])" $matches[2] }
  }
  $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT','User')
'@
}
if (-not $env:SDKROOT) {
    throw 'SDKROOT is not set. vcvars replaces the environment block and drops it; see docs/WINDOWS.md section 10.'
}

# --- build -----------------------------------------------------------------

Push-Location $repoRoot
try {
    if (-not $SkipTests) {
        Write-Host 'Running unit tests…' -ForegroundColor Cyan
        & swift test
        if ($LASTEXITCODE -ne 0) { throw 'unit tests failed' }
    }

    Write-Host "Building ($Configuration)…" -ForegroundColor Cyan
    & swift build -c $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}
finally {
    Pop-Location
}

$binDir = Join-Path $repoRoot ".build\$Configuration"
$executables = @('TeamsMusicStatus.exe', 'tmswinctl.exe')
foreach ($exe in $executables) {
    if (-not (Test-Path (Join-Path $binDir $exe))) { throw "missing build output: $exe" }
}

# --- stage -----------------------------------------------------------------

if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

foreach ($exe in $executables) {
    Copy-Item (Join-Path $binDir $exe) $stageDir
}

# Transitive import closure, restricted to DLLs that actually ship with the toolchain.
# Anything else -- USER32, the api-ms-win-* API sets -- is part of Windows and must not be
# copied: shipping a system DLL is at best pointless and at worst a servicing hazard.
function Get-ImportedDlls {
    param([string]$Path)
    $output = & dumpbin /NOLOGO /DEPENDENTS $Path 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $output |
        Select-String -Pattern '^\s{4}(\S+\.dll)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
}

$swiftBin = Split-Path -Parent (Get-Command swift).Source

# Walk up to the toolchain root and take its sibling Runtimes tree. Counting Split-Path
# levels is fragile -- the layout is Swift\Toolchains\<version>\usr\bin, and getting the
# count wrong silently finds nothing, which produces a package that will not start on any
# machine but the build one.
$node = Get-Item $swiftBin
while ($node -and $node.Name -ne 'Swift') { $node = $node.Parent }
$runtimeDirs = @()
if ($node) { $runtimeDirs += (Join-Path $node.FullName 'Runtimes') }
$runtimeDirs += $swiftBin
$runtimeDirs = $runtimeDirs | Where-Object { Test-Path $_ }
if (-not $runtimeDirs) { throw "could not locate the Swift runtime next to $swiftBin" }

$runtimeIndex = @{}
foreach ($dir in $runtimeDirs) {
    Get-ChildItem $dir -Filter *.dll -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $runtimeIndex.ContainsKey($_.Name)) { $runtimeIndex[$_.Name] = $_.FullName }
    }
}

Write-Host 'Resolving the runtime the binaries actually use…' -ForegroundColor Cyan
$pending = [System.Collections.Generic.Queue[string]]::new()
$copied = @{}
foreach ($exe in $executables) { $pending.Enqueue((Join-Path $stageDir $exe)) }

while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    foreach ($dependency in Get-ImportedDlls $current) {
        if ($copied.ContainsKey($dependency)) { continue }
        $source = $null
        foreach ($key in $runtimeIndex.Keys) {
            if ($key -ieq $dependency) { $source = $runtimeIndex[$key]; break }
        }
        if (-not $source) { continue }   # a Windows DLL; leave it to Windows
        $destination = Join-Path $stageDir $dependency
        Copy-Item $source $destination -Force
        $copied[$dependency] = $true
        $pending.Enqueue($destination)
    }
}

$runtimeSize = (Get-ChildItem $stageDir -Filter *.dll | Measure-Object Length -Sum).Sum
Write-Host ("  {0} runtime DLLs, {1:N1} MB" -f $copied.Count, ($runtimeSize / 1MB))

# --- install scripts -------------------------------------------------------

Copy-Item (Join-Path $PSScriptRoot 'windows-install\Install.ps1') $stageDir
Copy-Item (Join-Path $PSScriptRoot 'windows-install\Uninstall.ps1') $stageDir
Copy-Item (Join-Path $repoRoot 'LICENSE') (Join-Path $stageDir 'LICENSE.txt')

$readme = @"
Teams Music Status $marketingVersion (build $buildNumber)
Windows, $(if ([Environment]::Is64BitOperatingSystem) { $env:PROCESSOR_ARCHITECTURE } else { 'x86' })

Shows what you are listening to as your Microsoft Teams status message.

TO RUN WITHOUT INSTALLING
    Double-click TeamsMusicStatus.exe. It puts an icon in the notification area;
    right-click it for the menu.

TO INSTALL FOR YOUR USER ACCOUNT (no administrator rights needed)
    Right-click Install.ps1 and choose "Run with PowerShell", or:
        powershell -ExecutionPolicy Bypass -File Install.ps1

    This copies the app to
        %LOCALAPPDATA%\Programs\$appName
    adds a Start Menu shortcut, and registers it in Installed Apps so it can be
    removed the usual way.

TO REMOVE IT
    Use Settings > Apps > Installed apps, or run Uninstall.ps1.

DIAGNOSTICS
    tmswinctl.exe health          Teams version and readiness
    tmswinctl.exe teams-selectors check the Teams UI still matches
    tmswinctl.exe gate            full acceptance run (writes and restores your status)

    Logs:     %LOCALAPPDATA%\TeamsMusicStatus\Logs
    Settings: %APPDATA%\TeamsMusicStatus\settings.json

REQUIREMENTS
    Windows 10 1809 or later, Microsoft Teams (the new client), and a player that
    appears in the Windows media flyout, such as Spotify.

    This build is not code-signed, so SmartScreen may warn the first time. Choose
    "More info" then "Run anyway", or build it yourself from source.

$appName is developed by Zander Dent.
https://www.zanderdent.com/teams-music-status
"@
Set-Content -Path (Join-Path $stageDir 'README.txt') -Value $readme -Encoding UTF8

Write-Host ''
Write-Host "Staged: $stageDir" -ForegroundColor Green
Get-ChildItem $stageDir | Where-Object { -not $_.PSIsContainer } |
    Sort-Object Length -Descending | Select-Object -First 6 |
    ForEach-Object { "  {0,-40} {1,8:N1} KB" -f $_.Name, ($_.Length / 1KB) }
$total = (Get-ChildItem $stageDir -Recurse | Measure-Object Length -Sum).Sum
Write-Host ("  total {0:N1} MB" -f ($total / 1MB))
