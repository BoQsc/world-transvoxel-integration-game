@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py -3 tools\run_human_playtest.py --latest --gpu-resident-render-candidate
) else (
    python tools\run_human_playtest.py --latest --gpu-resident-render-candidate
)

if errorlevel 1 (
    echo.
    echo GPU candidate human playtest launch failed. Check that Python and Godot 4.7 or newer are installed.
    pause
)
endlocal
