<#
.SYNOPSIS
    Installs Teams Music Status for the current user.

.DESCRIPTION
    Per-user by design, so no administrator rights are needed and nothing is written
    outside the user's own profile:

      %LOCALAPPDATA%\Programs\Teams Music Status    the application
      Start Menu shortcut
      HKCU uninstall entry, so it appears in Settings > Apps > Installed apps

    A machine-wide install would need elevation and would put one user's music status
    on a shared machine, which is not what this is for.
#>
[CmdletBinding()]
param(
    [switch]$NoStartMenu,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$appName = 'Teams Music Status'
$exeName = 'TeamsMusicStatus.exe'
$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA "Programs\$appName"

if (-not (Test-Path (Join-Path $source $exeName))) {
    throw "$exeName was not found next to this script. Run Install.ps1 from the folder you unzipped."
}

# Stop a running copy first: the executable cannot be replaced while it is loaded, and
# failing halfway would leave a half-installed folder.
#
# Closed politely rather than killed. The app restores the user's previous Teams status on
# shutdown, and a force-kill skips that — upgrading in place would silently strand whatever
# track happened to be showing.
$running = Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host 'Closing the running copy…' -ForegroundColor Yellow

    if (-not ('TMSShutdown.Win32' -as [type])) {
        Add-Type -Namespace TMSShutdown -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowW(string className, string windowName);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@
    }

    # [NullString]::Value, not $null. PowerShell converts $null to an empty string when
    # binding to a [string] parameter, so FindWindow would search for a window whose title
    # is "" and silently return 0 — which looks exactly like the app not running.
    $hwnd = [TMSShutdown.Win32]::FindWindowW('TeamsMusicStatusTray', [NullString]::Value)
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][TMSShutdown.Win32]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) # WM_CLOSE
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 400
    }
    Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

Write-Host "Installing to $target" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $target -Force | Out-Null

Get-ChildItem $source -File |
    Where-Object { $_.Name -notin @('Install.ps1', 'Uninstall.ps1') } |
    ForEach-Object { Copy-Item $_.FullName $target -Force }

# The uninstaller has to survive in the install folder, not just the zip.
Copy-Item (Join-Path $source 'Uninstall.ps1') $target -Force

$installedExe = Join-Path $target $exeName

# --- Start Menu ------------------------------------------------------------

if (-not $NoStartMenu) {
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $shortcut = Join-Path $startMenu "$appName.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $installedExe
    $link.WorkingDirectory = $target
    $link.Description = 'Show what you are listening to as your Teams status'
    $link.Save()
    Write-Host "Start Menu shortcut created" -ForegroundColor Green
}

# --- Installed Apps entry --------------------------------------------------

# Registered so the app can be removed the way every other app is, rather than by
# deleting a folder and leaving a startup entry behind.
$version = '1.0.0'
$readme = Join-Path $source 'README.txt'
if (Test-Path $readme) {
    $line = (Get-Content $readme -TotalCount 1)
    if ($line -match '(\d+\.\d+\.\d+)') { $version = $Matches[1] }
}

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsMusicStatus'
New-Item -Path $uninstallKey -Force | Out-Null
$size = [int](((Get-ChildItem $target -Recurse | Measure-Object Length -Sum).Sum) / 1KB)
$properties = @{
    DisplayName     = $appName
    DisplayVersion  = $version
    Publisher       = 'Zander Dent'
    InstallLocation = $target
    DisplayIcon     = $installedExe
    UninstallString = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $target 'Uninstall.ps1')`""
    NoModify        = 1
    NoRepair        = 1
    EstimatedSize   = $size
    URLInfoAbout    = 'https://www.zanderdent.com/teams-music-status'
}
foreach ($name in $properties.Keys) {
    Set-ItemProperty -Path $uninstallKey -Name $name -Value $properties[$name]
}

Write-Host 'Registered in Installed Apps' -ForegroundColor Green
Write-Host ''
Write-Host "Installed $appName $version" -ForegroundColor Green
Write-Host "  $target"

if (-not $NoLaunch) {
    Write-Host ''
    Write-Host 'Starting…  look for the ♪ icon in the notification area.' -ForegroundColor Cyan
    Start-Process -FilePath $installedExe -WorkingDirectory $target
}
