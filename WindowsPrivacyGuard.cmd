@echo off
setlocal
rem Double-click this file to open the Windows Privacy Guard control panel.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-WindowsPrivacyGuard.ps1"
