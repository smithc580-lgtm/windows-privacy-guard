@echo off
setlocal
rem Replace this URL before publishing the repository.
set "REPO_ZIP_URL=https://github.com/REPLACE_ME/windows-privacy-guard/archive/refs/heads/main.zip"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\DownloadAndLaunch.ps1" -RepositoryZipUrl "%REPO_ZIP_URL%"
