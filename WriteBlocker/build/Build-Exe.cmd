@echo off
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo csc.exe nao encontrado.
  exit /b 1
)

set OUT=%~dp0..\PFD-WriteBlocker.exe
echo Compilando PFD-WriteBlocker.exe (requireAdministrator)...
"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ ^
  /win32manifest:app.manifest ^
  /reference:System.Windows.Forms.dll ^
  /reference:System.Drawing.dll ^
  /out:"%OUT%" ^
  Launcher.cs

if errorlevel 1 (
  echo FALHA na compilacao.
  exit /b 1
)

echo.
echo OK: %OUT%
echo O executavel solicita UAC (Administrador) automaticamente.
exit /b 0
