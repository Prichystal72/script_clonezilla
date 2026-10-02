@echo off
rem Spusti restore.sh v SIMULACI (nic se nezapisuje) ve WSL Ubuntu.
rem Pouziti: dvojklik, nebo  simulace.cmd beckhoff-xp
rem Scenare: bigger smaller toosmall windows noimage mounted beckhoff-xp beckhoff-ce beckhoff-w7
set "WSL=%SystemRoot%\System32\wsl.exe"
if exist "%SystemRoot%\Sysnative\wsl.exe" set "WSL=%SystemRoot%\Sysnative\wsl.exe"
set "SCEN=%~1"
if "%SCEN%"=="" set "SCEN=windows"
"%WSL%" -d Ubuntu-24.04 --cd "%~dp0" -- bash restore.sh --simulate=%SCEN%
pause
