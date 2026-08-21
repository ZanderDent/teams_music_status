<#
.SYNOPSIS
    Removes Teams Music Status for the current user.

.DESCRIPTION
    Undoes everything Install.ps1 did, in the order that matters: stop the app, remove the
    startup entry, remove the shortcut and the Installed Apps entry, then delete the files.

    The startup entry is removed first and deliberately. Leaving it behind after deleting
    the executable would leave Windows trying to launch a missing program at every sign-in
    -- the classic uninstall bug, and one the user cannot easily find and fix.

    Settings and logs are left alone unless -Purge is given, so reinstalling keeps the
    user's template and preferences.
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$appName = 'Teams Music Status'
$target = Join-Path $env:LOCALAPPDATA "Programs\$appName"

Write-Host "Removing $appName…" -ForegroundColor Cyan

# 1. Stop it, and stop it *politely*.
#
# Killing the process strands the user's Teams status: the app restores what they had
# before syncing when it shuts down, and a force-kill never gets there. Closing the tray
# window instead lets it run that path. It has to drive the Teams flyout to do so, which
# takes several seconds, hence the generous wait.
function Stop-TeamsMusicStatus {
    param([int]$TimeoutSeconds = 30)

    $running = Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue
    if (-not $running) { return }

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
        Write-Host '  asking it to close and restore your status…'
        [void][TMSShutdown.Win32]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) # WM_CLOSE

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue)) {
                Write-Host '  closed cleanly'
                return
            }
            Start-Sleep -Milliseconds 400
        }
    }

    # Last resort. Say so plainly rather than claiming the status was restored.
    Get-Process -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Warning 'It did not close in time and was stopped. Your Teams status message may still show a track; clear it in Teams.'
    $script:forcedStop = $true
}

$script:forcedStop = $false
Stop-TeamsMusicStatus

# 2. Startup entry, before the files go.
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -Path $runKey -Name 'TeamsMusicStatus' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $runKey -Name 'TeamsMusicStatus' -Force
    Write-Host '  removed the startup entry'
}

# 3. Start Menu shortcut.
$shortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$appName.lnk"
if (Test-Path $shortcut) {
    Remove-Item $shortcut -Force
    Write-Host '  removed the Start Menu shortcut'
}

# 4. Installed Apps entry.
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsMusicStatus'
if (Test-Path $uninstallKey) {
    Remove-Item $uninstallKey -Recurse -Force
    Write-Host '  removed the Installed Apps entry'
}

# 5. Files. Scheduled rather than deleted when this script is running from inside the
#    folder it is deleting, which is the normal case when launched from Installed Apps.
if (Test-Path $target) {
    $selfIsInside = $PSScriptRoot -and $PSScriptRoot.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)
    if ($selfIsInside) {
        $command = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$target' -Recurse -Force -ErrorAction SilentlyContinue"
        Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $command
        Write-Host '  files will be removed in a moment'
    } else {
        Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '  removed the application files'
    }
}

# 6. Settings and logs, only if asked.
if ($Purge) {
    foreach ($path in @((Join-Path $env:APPDATA 'TeamsMusicStatus'),
                        (Join-Path $env:LOCALAPPDATA 'TeamsMusicStatus'))) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $path"
        }
    }
} else {
    Write-Host ''
    Write-Host 'Settings and logs were kept. Run with -Purge to remove those too:' -ForegroundColor DarkGray
    Write-Host "  %APPDATA%\TeamsMusicStatus  and  %LOCALAPPDATA%\TeamsMusicStatus" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "$appName removed." -ForegroundColor Green
if (-not $script:forcedStop) {
    Write-Host 'Your Teams status was restored when the app closed.' -ForegroundColor DarkGray
}
