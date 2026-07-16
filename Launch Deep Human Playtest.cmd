@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py -3 tools\run_human_playtest.py --profile g20_deep_2k_256_on_demand --material production_texture_array
) else (
    python tools\run_human_playtest.py --profile g20_deep_2k_256_on_demand --material production_texture_array
)

if errorlevel 1 (
    echo.
    echo Deep human playtest launch failed. Check that Python and Godot are installed.
    pause
)
endlocal
