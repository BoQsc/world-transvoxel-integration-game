@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py -3 tools\run_human_playtest.py --latest
) else (
    python tools\run_human_playtest.py --latest
)

if errorlevel 1 (
    echo.
    echo Human playtest launch failed. Check that Python and Godot are installed.
    pause
)
endlocal
