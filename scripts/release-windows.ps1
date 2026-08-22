<#
.SYNOPSIS
    Produces a distributable Teams Music Status package for Windows.

.DESCRIPTION
    The counterpart of scripts/release.sh. Builds, stages, and packs a versioned zip with
    a checksum beside it.

    Deliberately unsigned unless -CertificateThumbprint is given. Authenticode signing
    needs a certificate that does not belong in a repository or in CI secrets for a project
    this size, so releases are signed on the maintainer's machine -- the same policy the
    macOS release takes with Developer ID.

.PARAMETER CertificateThumbprint
    Signs every executable and DLL with this certificate from the current user's store.
    Without it the package is unsigned and SmartScreen will warn on first run.

.PARAMETER SkipTests
    Passed through to the build.

.EXAMPLE
    .\scripts\release-windows.ps1
    .\scripts\release-windows.ps1 -CertificateThumbprint ABC123...
#>
[CmdletBinding()]
param(
    [string]$CertificateThumbprint,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$distRoot = Join-Path $repoRoot 'dist'
$appName = 'Teams Music Status'
$stageDir = Join-Path $distRoot "staging\$appName"

# --- build and stage -------------------------------------------------------

$buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               (Join-Path $PSScriptRoot 'build-windows.ps1'))
if ($SkipTests) { $buildArgs += '-SkipTests' }
& powershell @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
if (-not (Test-Path $stageDir)) { throw "staging folder missing: $stageDir" }

# --- version and architecture ---------------------------------------------

$marketingVersion = '0.0.0'
$buildNumber = '0'
foreach ($line in Get-Content (Join-Path $repoRoot 'VERSION')) {
    if ($line -match '^\s*MARKETING_VERSION\s*=\s*(.+?)\s*$') { $marketingVersion = $Matches[1] }
    if ($line -match '^\s*BUILD_NUMBER\s*=\s*(.+?)\s*$') { $buildNumber = $Matches[1] }
}
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    'AMD64' { 'x64' }
    default { $env:PROCESSOR_ARCHITECTURE.ToLowerInvariant() }
}

# --- signing ---------------------------------------------------------------

if ($CertificateThumbprint) {
    $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\|\\arm64\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $signtool) { throw 'signtool.exe not found; install the Windows SDK signing tools' }

    # Everything shipped, not just the executables: an unsigned DLL beside a signed exe
    # still trips SmartScreen and defeats the point.
    $toSign = Get-ChildItem $stageDir -Include *.exe, *.dll -Recurse | ForEach-Object { $_.FullName }
    Write-Host "Signing $($toSign.Count) files…" -ForegroundColor Cyan
    & $signtool.FullName sign /sha1 $CertificateThumbprint /fd SHA256 `
        /tr http://timestamp.digicert.com /td SHA256 @toSign
    if ($LASTEXITCODE -ne 0) { throw 'signing failed' }
} else {
    Write-Host 'Not signed. SmartScreen will warn on first run.' -ForegroundColor Yellow
}

# --- pack ------------------------------------------------------------------

$packageName = "Teams-Music-Status-$marketingVersion-win-$arch.zip"
$packagePath = Join-Path $distRoot $packageName
if (Test-Path $packagePath) { Remove-Item $packagePath -Force }

Write-Host "Packing $packageName…" -ForegroundColor Cyan
# Compress the folder itself, not its contents, so unzipping produces one tidy directory
# rather than scattering 15 DLLs into whatever folder the user happened to be in.
Compress-Archive -Path $stageDir -DestinationPath $packagePath -CompressionLevel Optimal

$hash = (Get-FileHash $packagePath -Algorithm SHA256).Hash
$sizeMB = (Get-Item $packagePath).Length / 1MB

$info = @"
Teams Music Status $marketingVersion (build $buildNumber)
Windows $arch

Package : $packageName
Size    : $([math]::Round($sizeMB, 1)) MB
SHA256  : $hash
Signed  : $(if ($CertificateThumbprint) { "yes ($CertificateThumbprint)" } else { 'no' })
Built   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Teams   : tested against 26213.1006.5014.9784

Install: unzip, then run Install.ps1 inside the folder, or just run
TeamsMusicStatus.exe from where it is.
"@
Set-Content -Path (Join-Path $distRoot 'release-info-windows.txt') -Value $info -Encoding UTF8

Write-Host ''
Write-Host $info -ForegroundColor Green
