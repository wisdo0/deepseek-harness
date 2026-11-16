@echo off
rem Portable launcher: %~dp0 = package root, works from any directory.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lowend\dsh-gpu.ps1" %*
