<#
.SYNOPSIS
    Installs SMM Monitor on Windows, inside WSL.

.DESCRIPTION
    Run this in PowerShell:

        iwr -useb https://raw.githubusercontent.com/phravins/SMM-Monitor/main/scripts/install.ps1 | iex

    SMM Monitor draws its dashboard with termbox, which is a POSIX
    library — it talks to a terminal through termios and select, and
    there is no Windows build of it. A native .exe would compile the
    Erlang runtime fine and then have nothing to draw with, so rather
    than ship something that starts and shows you an empty window, this
    installs the Linux build into WSL, where it works exactly as it does
    on a Linux laptop.

    WSL is a Microsoft feature and takes one command to enable; if it
    isn't there yet, this tells you which command and stops.

    Use Windows Terminal to run it. The old conhost console (the one you
    get from cmd.exe in a plain window) does not render the box-drawing
    and block characters the dashboard is made of.
#>

[CmdletBinding()]
param(
    # Which WSL distribution to install into. Defaults to the one WSL
    # itself considers default.
    [string]$Distribution = ""
)

$ErrorActionPreference = "Stop"

$InstallerUrl = "https://raw.githubusercontent.com/phravins/SMM-Monitor/main/scripts/install.sh"

function Write-Step($message) {
    Write-Host "==> " -ForegroundColor Cyan -NoNewline
    Write-Host $message
}

function Write-Problem($message) {
    Write-Host "x " -ForegroundColor Red -NoNewline
    Write-Host $message
}

function Test-Wsl {
    $command = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $command) { return $false }

    # `wsl -l -q` lists installed distributions, one per line. WSL writes
    # UTF-16, which arrives full of nulls through the pipe.
    $distributions = (& wsl.exe -l -q) -replace "`0", "" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    return ($distributions.Count -gt 0)
}

function Install-SmmMonitor {
    $command = "curl -fsSL $InstallerUrl | sh"

    if ($Distribution -ne "") {
        Write-Step "Installing into WSL distribution '$Distribution'"
        & wsl.exe -d $Distribution -- bash -lc $command
    }
    else {
        Write-Step "Installing into your default WSL distribution"
        & wsl.exe -- bash -lc $command
    }

    if ($LASTEXITCODE -ne 0) {
        throw "The Linux installer exited with code $LASTEXITCODE."
    }
}

Write-Step "SMM Monitor for Windows (via WSL)"

if (-not (Test-Wsl)) {
    Write-Problem "No WSL distribution found."
    Write-Host ""
    Write-Host "SMM Monitor's dashboard needs a POSIX terminal, so on Windows it runs"
    Write-Host "inside WSL. Installing WSL takes one command and a restart:"
    Write-Host ""
    Write-Host "    wsl --install" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Then run this installer again."
    Write-Host ""
    exit 1
}

Install-SmmMonitor

Write-Host ""
Write-Step "Run it:"
Write-Host ""
Write-Host "    wsl smm-monitor" -ForegroundColor Yellow
Write-Host ""
Write-Host "Use Windows Terminal rather than the old console window — the dashboard"
Write-Host "is drawn with box and block characters that conhost renders as boxes."
Write-Host ""
Write-Host "First run asks a couple of questions on screen; there is nothing to edit"
Write-Host "and no API key required to look around."
Write-Host ""
