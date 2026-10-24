@echo off
setlocal

set "ROOT_DIR=%~dp0"
if "%ROOT_DIR:~-1%"=="\" set "ROOT_DIR=%ROOT_DIR:~0,-1%"

where cabal >nul 2>&1
if errorlevel 1 (
  echo Error: cabal was not found on PATH. Install GHC/cabal and reopen this Command Prompt.
  exit /b 1
)

where node >nul 2>&1
if errorlevel 1 (
  echo Error: node was not found on PATH. Install Node.js and reopen this Command Prompt.
  exit /b 1
)

where pnpm >nul 2>&1
if errorlevel 1 (
  echo Error: pnpm was not found on PATH. Install Node.js and pnpm, then reopen this Command Prompt.
  exit /b 1
)

if not exist "%ROOT_DIR%\backend\cabal.project" (
  echo Error: backend\cabal.project is missing from %ROOT_DIR%.
  exit /b 1
)

if not exist "%ROOT_DIR%\frontend\package.json" (
  echo Error: frontend\package.json is missing from %ROOT_DIR%.
  exit /b 1
)

if exist "%ROOT_DIR%\.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ROOT_DIR%\.env") do (
    if not "%%A"=="" set "%%A=%%B"
  )
)

echo Starting Driftwords backend on http://localhost:8080 ...
start "Driftwords backend" /D "%ROOT_DIR%\backend" cmd /k cabal run drift-server

echo Starting Driftwords frontend on http://localhost:5173 ...
start "Driftwords frontend" /D "%ROOT_DIR%\frontend" cmd /k pnpm dev

echo Both services started in separate Command Prompt windows.
echo Close those windows to stop the services.
exit /b 0