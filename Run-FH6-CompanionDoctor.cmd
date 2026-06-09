@echo off
set "SCRIPT=%~dp0Tools\FH6-CompanionDoctor.ps1"
if not exist "%SCRIPT%" (
  echo Could not find "%SCRIPT%".
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
