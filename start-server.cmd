@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"

rem ---------- load .env defaults ----------
set "PORT=18123"
set "HOST=127.0.0.1"
set "ENGINE_DIR=engine\llama.cpp-b10740"
set "MODEL_DIR=models"
set "LLAMA_API_KEY="
if exist "%DIR%.env" (
    for /f "usebackq tokens=1* delims==" %%a in ("%DIR%.env") do (
        set "k=%%a"
        set "v=%%b"
        if not "!k!"=="" if not "!k:~0,1!"=="#" (
            if /i "!k!"=="PORT" set "PORT=!v!"
            if /i "!k!"=="HOST" set "HOST=!v!"
            if /i "!k!"=="ENGINE_DIR" set "ENGINE_DIR=!v!"
            if /i "!k!"=="MODEL_DIR" set "MODEL_DIR=!v!"
            if /i "!k!"=="LLAMA_API_KEY" set "LLAMA_API_KEY=!v!"
        )
    )
)
if not "%~2"=="" set "PORT=%~2"
if not "%~3"=="" set "HOST=%~3"
if defined PORT_OVERRIDE set "PORT=%PORT_OVERRIDE%"
if defined HOST_OVERRIDE set "HOST=%HOST_OVERRIDE%"

rem ---------- resolve dirs (with legacy fallback) ----------
if not exist "%DIR%%MODEL_DIR%\*.gguf" (
    rem fallback: flat layout before reorg
    set "MODEL_DIR=."
)
set "CONF=%DIR%config\models.conf"
if not exist "!CONF!" set "CONF=%DIR%models.conf"
set "ENG=%DIR%%ENGINE_DIR%"
if not exist "!ENG!\llama-server.exe" (
    if exist "%DIR%llama.cpp\llama-server.exe" set "ENG=%DIR%llama.cpp"
)
if not exist "!ENG!\llama-server.exe" (
    echo ERROR: llama-server.exe not found in !ENG!
    echo Run setup.bat first to download the pinned engine.
    pause
    exit /b 1
)
cd /d "!ENG!"

set "MODEL_FILE="
set "CTX=131000"
set "NGL=17"
set "KV=q8_0"
set "DRAFT_FILE="
set "SPEC_TYPE=none"
set "SPEC_N_MAX=3"

rem ---------- direct argument mode ----------
if not "%~1"=="" (
    if exist "%DIR%%MODEL_DIR%\%~1" ( set "MODEL_FILE=%~1" ) else (
    if exist "%DIR%%~1" ( set "MODEL_FILE=%~1" & set "MODEL_DIR=." ) else (
        echo Model not found: %~1
        echo.
    )
    )
)

rem ---------- interactive menu ----------
if not defined MODEL_FILE (
    (for %%f in ("%DIR%%MODEL_DIR%\*.gguf") do @echo %%~nxf) > "%TEMP%\llm_models.txt"
    echo Available models ^(from %MODEL_DIR%^):
    set /a i=0
    for /f "delims=" %%f in ('type "%TEMP%\llm_models.txt"') do (
        set /a i+=1
        set "M!i!=%%f"
        echo   !i!. %%f
    )
    if !i!==0 (
        echo No .gguf files found in %MODEL_DIR%\ -- copy models there or run setup.bat.
        del "%TEMP%\llm_models.txt" >nul 2>&1
        pause
        exit /b 1
    )
    echo.
    set /p sel=Pick model number [1]:
    if not defined sel set "sel=1"
    call :pick !sel!
    if not defined MODEL_FILE ( echo Invalid choice. & exit /b 1 )
)
del "%TEMP%\llm_models.txt" >nul 2>&1

rem ---------- smart default for models without conf entry ----------
for %%z in ("%DIR%%MODEL_DIR%\!MODEL_FILE!") do (
    if %%~zz LSS 5700000000 ( set "NGL=99" )
)

rem ---------- apply overrides from models.conf ----------
if exist "!CONF!" (
    for /f "usebackq tokens=1-7 delims=|" %%a in ("!CONF!") do (
        if /i "%%a"=="!MODEL_FILE!" ( set "CTX=%%b" & set "NGL=%%c" & set "KV=%%d" & set "DRAFT_FILE=%%e" & set "SPEC_TYPE=%%f" & set "SPEC_N_MAX=%%g" )
    )
)

rem ---------- build speculative decoding args ----------
set "SPEC_ARGS="
set "SPEC_INFO="
if defined DRAFT_FILE (
    if exist "%DIR%%MODEL_DIR%\!DRAFT_FILE!" (
        set "SPEC_ARGS=-md "%DIR%%MODEL_DIR%\!DRAFT_FILE!" --spec-type !SPEC_TYPE! --spec-draft-n-max !SPEC_N_MAX! --fit off -ngld 0"
        set "SPEC_INFO= draft=!DRAFT_FILE! spec=!SPEC_TYPE! n-max=!SPEC_N_MAX!"
    ) else (
        echo Warning: draft model not found: !DRAFT_FILE! -- continuing without spec decoding
    )
)

rem ---------- find free port (bump if busy) ----------
set "TRY_PORT=!PORT!"
set /a TRIES=0
:portcheck
netstat -ano | findstr /r /c:":!TRY_PORT! .*LISTENING" >nul 2>&1
if not errorlevel 1 (
    set /a TRIES+=1
    if !TRIES! GEQ 20 (
        echo ERROR: ports !PORT!-!TRY_PORT! all busy. Pass a free port: start-server.cmd [model] [port]
        pause
        exit /b 1
    )
    set /a TRY_PORT+=1
    goto portcheck
)
set "PORT=!TRY_PORT!"
echo !PORT! > "%DIR%.port"

rem ---------- api key ----------
set "KEY_ARGS="
if defined LLAMA_API_KEY (
    if not "!LLAMA_API_KEY!"=="" set "KEY_ARGS=--api-key !LLAMA_API_KEY!"
)

title Local Model - llama.cpp server (http://!HOST!:!PORT!)
echo Starting "Local Model" = !MODEL_FILE!  ^(ctx=!CTX! ngl=!NGL! kv=!KV!!SPEC_INFO!^)
echo URL: http://!HOST!:!PORT!  OpenAI-compatible: http://127.0.0.1:!PORT!/v1
echo Cloudflared example: cloudflared tunnel --url http://127.0.0.1:!PORT!
if "!HOST!"=="0.0.0.0" echo WARNING: bound to LAN. Prefer HOST=127.0.0.1 for tunnel-only use.
taskkill /IM llama-server.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul
".\llama-server.exe" -m "%DIR%%MODEL_DIR%\!MODEL_FILE!" -c !CTX! -ngl !NGL! -ctk !KV! -ctv !KV! -fa on --prio 2 --parallel 1 -t 8 -tb 12 --host !HOST! --reasoning-effort medium --reasoning-budget 512 --alias "Local Model" --port !PORT! !KEY_ARGS! !SPEC_ARGS!
if errorlevel 1 pause
exit /b

:pick
set "MODEL_FILE=!M%1!"
exit /b
