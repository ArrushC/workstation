@echo off
rem ws-agent for cmd: the logic is ws-agent.ps1 beside this file. cmd has no UNC working
rem directory, so from cmd only commands that need no repository (ls --all, inbox, result) are useful.
setlocal
set "WS_PS=powershell"
where pwsh >nul 2>nul && set "WS_PS=pwsh"
%WS_PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0ws-agent.ps1" %*
exit /b %errorlevel%
