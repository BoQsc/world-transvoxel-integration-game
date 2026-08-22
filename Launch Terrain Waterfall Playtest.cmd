@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %errorlevel%==0 (
    py -3 tools\run_human_playtest.py --latest --terrain-waterfall
) else (
    python tools\run_human_playtest.py --latest --terrain-waterfall
)

if not %errorlevel%==0 (
    echo Terrain waterfall playtest failed. Check the terminal output above.
    pause
)
