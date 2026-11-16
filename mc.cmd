@echo off
rem Windows entry point for `mc` (the Python script sitting next to this file).
rem Prefers the `py` launcher, falls back to `python` on PATH.
setlocal
set "SCRIPT=%~dp0mc"

py -3 -c "import sys" >nul 2>nul
if not errorlevel 1 goto use_py
python -c "import sys" >nul 2>nul
if not errorlevel 1 goto use_python

echo mc: python 3 not found. Install it from https://www.python.org/downloads/windows/ 1>&2
exit /b 1

:use_py
py -3 "%SCRIPT%" %*
exit /b %errorlevel%

:use_python
python "%SCRIPT%" %*
exit /b %errorlevel%
