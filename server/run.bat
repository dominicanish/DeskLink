@echo off
REM DeskLink server launcher (double-clickable).
REM Creates a virtualenv on first run, installs deps, then starts the server.
cd /d "%~dp0"

if not exist ".venv" (
    echo Creating virtual environment...
    python -m venv .venv
)

REM Install only if a previous install hasn't completed successfully.
if not exist ".venv\.installed" (
    echo Installing dependencies...
    ".venv\Scripts\python.exe" -m pip install --upgrade pip
    ".venv\Scripts\python.exe" -m pip install -e ".[windows,opus]"
    if errorlevel 1 (
        echo.
        echo Install failed. See the messages above. Fix and re-run.
        pause
        exit /b 1
    )
    echo done > ".venv\.installed"
)

echo Starting DeskLink...
".venv\Scripts\python.exe" -m desklink %*
pause
