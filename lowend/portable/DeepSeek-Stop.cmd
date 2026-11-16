@echo off
rem Stop backend, lite proxy and the browser window started by this package.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lowend\dsh-gpu.ps1" -Stop
