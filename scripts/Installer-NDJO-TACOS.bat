@echo off
title NDJO TACOS — Installation Windows
cd /d "%~dp0"
echo Installation de NDJO TACOS (Windows 10/11, 64 bits)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer.ps1"
if errorlevel 1 pause
