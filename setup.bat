@echo off
setlocal enabledelayedexpansion
rem Portable bootstrap for llama.cpp server. Safe to re-run (idempotent).
set "DIR=%~dp0"

set "PORT=18123"
set "HOST=127.0.0.1"
set "ENGINE_VERSION=b10740"
set "ENGINE_URL="
set "ENGINE_DIR=engine\llama.cpp-b10740"
set "MODEL_DIR=models"
if exist "%DIR%.env" (
    for /f "usebackq tokens=1* delims==" %%a in ("%DIR%.env") do (
        set "k=%%a" & set "v=%%b"
        if not "!k!"=="" if not "!k:~0,1!"=="#" (
            if /i "!k!"=="PORT" set "PORT=!v!"
            if /i "!k!"=="HOST" set "HOST=!v!"
            if /i "!k!"=="ENGINE_VERSION" set "ENGINE_VERSION=!v!"
            if /i "!k!"=="ENGINE_URL" set "ENGINE_URL=!v!"
            if /i "!k!"=="ENGINE_DIR" set "ENGINE_DIR=!v!"
            if /i "!k!"=="MODEL_DIR" set "MODEL_DIR=!v!"
        )
    )
)

echo === llama.cpp setup [!ENGINE_VERSION! port=!PORT! host=!HOST!] ===
mkdir "%DIR%%MODEL_DIR%" 2>nul
mkdir "%DIR%engine" 2>nul
mkdir "%DIR%config" 2>nul
mkdir "%DIR%logs" 2>nul

rem ---------- migrate legacy flat layout ----------
set MOVED=0
for %%f in ("%DIR%*.gguf") do (
    echo Moving %%~nxf -^> %MODEL_DIR%\
    move "%%f" "%DIR%%MODEL_DIR%\" >nul
    set MOVED=1
)
if exist "%DIR%models.conf" if not exist "%DIR%config\models.conf" (
    copy "%DIR%models.conf" "%DIR%config\models.conf" >nul
    echo Copied models.conf -^> config\models.conf ^(original kept for rollback^)
)
if not exist "%DIR%.env" if exist "%DIR%.env.example" (
    copy "%DIR%.env.example" "%DIR%.env" >nul
    echo Created .env from .env.example
)

rem ---------- preflight ----------
where nvidia-smi >nul 2>&1
if errorlevel 1 ( echo WARNING: nvidia-smi not found -- CPU-only fallback. Install NVIDIA driver + CUDA 12.4 runtime. ) else ( nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>nul )
where curl >nul 2>&1
if errorlevel 1 ( echo ERROR: curl required on PATH. & pause & exit /b 1 )

rem ---------- engine download (pinned) ----------
set "ENG=%DIR%%ENGINE_DIR%"
if exist "!ENG!\llama-server.exe" (
    echo Engine OK: !ENG!
) else (
    echo Downloading llama.cpp !ENGINE_VERSION! CUDA 12.4 win-x64...
    set "URL=https://github.com/ggml-org/llama.cpp/releases/download/!ENGINE_VERSION!/llama-!ENGINE_VERSION!-bin-win-cuda-12.4-x64.zip"
    if defined ENGINE_URL set "URL=!ENGINE_URL!"
    mkdir "!ENG!" 2>nul
    curl -fL "!URL!" -o "%DIR%engine\llama.zip"
    if errorlevel 1 (
        echo ERROR: download failed: !URL!
        echo Fix ENGINE_VERSION in .env or download manually into !ENG!
        pause & exit /b 1
    )
    powershell -NoProfile -Command "Expand-Archive -LiteralPath '%DIR%engine\llama.zip' -DestinationPath '!ENG!' -Force"
    del "%DIR%engine\llama.zip"
    if not exist "!ENG!\llama-server.exe" (
        echo ERROR: llama-server.exe still missing after unzip. Check zip layout.
        pause & exit /b 1
    )
    echo Engine installed: !ENG!
)
"!ENG!\llama-server.exe" --version

rem ---------- firewall (only for LAN bind) ----------
if /i "!HOST!"=="0.0.0.0" (
    netsh advfirewall firewall show rule name="llama-server !PORT!" >nul 2>&1
    if errorlevel 1 (
        echo Adding inbound firewall rule for TCP !PORT! ^(admin prompt^)...
        powershell -NoProfile -Command "Start-Process netsh -ArgumentList 'advfirewall firewall add rule name=\"llama-server !PORT!\" dir=in action=allow protocol=TCP localport=!PORT!' -Verb RunAs -Wait"
    ) else ( echo Firewall rule exists: llama-server !PORT! )
    netsh advfirewall firewall show rule name="llama-server 8080" >nul 2>&1
    if not errorlevel 1 echo NOTE: old rule 'llama-server 8080' still exists. Remove with: netsh advfirewall firewall delete rule name="llama-server 8080"
) else (
    echo HOST=!HOST! ^(localhost-only^) -- no inbound firewall rule needed. Tunnel uses outbound.
)

rem ---------- opencode provider patch ----------
set "OCFG=%USERPROFILE%\.config\opencode\opencode.json"
if exist "%OCFG%" (
    copy "%OCFG%" "%OCFG%.bak-%date:~-4%%date:~4,2%%date:~7,2%" >nul 2>&1
    powershell -NoProfile -Command "(Get-Content -LiteralPath '%OCFG%' -Raw) -replace '127\.0\.0\.1:8080', '127.0.0.1:!PORT!' | Set-Content -LiteralPath '%OCFG%' -NoNewline; Write-Output 'opencode.json patched to 127.0.0.1:!PORT! (backup .bak-*)'"
) else ( echo No opencode.json found -- skip. Manually set llamacpp baseURL to http://127.0.0.1:!PORT!/v1 )

echo.
echo Models in %MODEL_DIR%: & dir /b "%DIR%%MODEL_DIR%\*.gguf" 2>nul
echo.
echo DONE. Next:
echo   1. start-server.cmd [model.gguf] [port] [host]
echo   2. Local API: http://127.0.0.1:!PORT!/v1 ^(opencode provider llamacpp^)
echo   3. Tunnel: cloudflared tunnel --url http://127.0.0.1:!PORT!
echo      Named tunnel ingress: hostname: llm.example.com -^> service: http://127.0.0.1:!PORT!
pause
