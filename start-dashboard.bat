@echo off
setlocal
cd /d "%~dp0"

echo Starting Pokebot NDS dashboard v38.4...
echo Build authority: lua\methods\nav\nav_version.lua
echo.

echo Stopping any old dashboard server on port 3000...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -gt 0 -and $_.OwningProcess -ne $PID } | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"
echo.

node -v >nul 2>&1
if %errorlevel% neq 0 (
    echo Node.js is required to launch the dashboard without a standalone binary.
    echo Please install Node.js, then run this file again.
    cmd /k
    exit /b 1
)

cd /d "%~dp0dashboard"

if exist "node_modules\mime\package.json" if exist "node_modules\discord.js\package.json" (
    echo Existing dashboard dependencies found. Skipping npm install.
    goto START_SERVER
)

echo Installing dashboard dependencies...
echo This build does not require Git. Discord Rich Presence is optional and disabled if not installed.
call npm install --no-audit --no-fund --omit=optional
if %errorlevel% neq 0 (
    echo.
    echo npm install failed.
    echo If you already had this dashboard working before, you can try running npm start from the dashboard folder.
    echo Otherwise, install Node.js dependencies manually after fixing npm.
    cmd /k
    exit /b 1
)

:START_SERVER
echo.
echo Starting Node dashboard server...
echo Verify with: http://localhost:3000/api/version
echo.
call npm start

cmd /k
