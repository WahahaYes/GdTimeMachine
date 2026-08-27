@echo off
REM gdtime wrapper — Windows batch (see gdtime bash shim for docs)
REM Consumers run: gdtime <command>
setlocal

REM Resolve repo root (this script dir: addons\GdTimeMachine\cli)
set "SCRIPT_DIR=%~dp0"
REM Walk up to find project.godot
set "PROJECT_ROOT=%SCRIPT_DIR%\..\..\.."
if exist "%PROJECT_ROOT%\project.godot" goto found
set "PROJECT_ROOT=%CD%"

:found
REM Resolve Godot binary: GODOT_BIN env > godot on PATH
if defined GODOT_BIN goto run
where godot >nul 2>&1
if %errorlevel%==0 set "GODOT_BIN=godot" & goto run
echo gdtime: Godot not found. Install Godot 4.7+ or set GODOT_BIN. >&2
exit /b 1

:run
"%GODOT_BIN%" --headless --path "%PROJECT_ROOT%" -s "res://addons/GdTimeMachine/cli/main.gd" -- %*
