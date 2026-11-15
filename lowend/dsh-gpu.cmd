@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-gpu.ps1" %*
