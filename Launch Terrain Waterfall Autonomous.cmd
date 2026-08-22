@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %errorlevel%==0 (
    py -3 tools\run_human_playtest.py --latest --terrain-waterfall-autonomous
) else (
    python tools\run_human_playtest.py --latest --terrain-waterfall-autonomous
)

if not %errorlevel%==0 (
    echo Autonomous terrain waterfall failed. Check the terminal output above.
    pause
)
