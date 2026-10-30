@echo off
:: Atalho: inicia o executavel (UAC Administrador via manifesto)
cd /d "%~dp0"
if exist "%~dp0PFD-WriteBlocker.exe" (
  start "" "%~dp0PFD-WriteBlocker.exe"
  exit /b 0
)

echo PFD-WriteBlocker.exe nao encontrado. Compilando...
call "%~dp0build\Build-Exe.cmd"
if exist "%~dp0PFD-WriteBlocker.exe" (
  start "" "%~dp0PFD-WriteBlocker.exe"
  exit /b 0
)

echo Falha ao gerar o executavel. Abrindo GUI via PowerShell...
net session >nul 2>&1
if %errorLevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
start "PFD WriteBlocker" powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PFD-WriteBlocker-GUI.ps1"
