# DeskLink server launcher (Windows PowerShell).
# Creates a local virtualenv on first run, installs deps, then starts the server.
#
#   Right-click -> Run with PowerShell, or:  .\run.ps1 --low-latency
#
param([Parameter(ValueFromRemainingArguments = $true)] $Args)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Test-Path ".venv")) {
    Write-Host "Creating virtual environment..." -ForegroundColor Cyan
    python -m venv .venv
}

# Install only if a previous install hasn't completed successfully.
if (-not (Test-Path ".venv\.installed")) {
    Write-Host "Installing dependencies..." -ForegroundColor Cyan
    .\.venv\Scripts\python.exe -m pip install --upgrade pip
    .\.venv\Scripts\python.exe -m pip install -e ".[windows,opus]"
    New-Item -ItemType File -Path ".venv\.installed" -Force | Out-Null
}

Write-Host "Starting DeskLink..." -ForegroundColor Green
.\.venv\Scripts\python.exe -m desklink @Args
