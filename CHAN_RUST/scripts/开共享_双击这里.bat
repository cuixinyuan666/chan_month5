@echo off
chcp 65001 >nul
setlocal
rem 双击这个文件：会弹一次用户账户控制，确认后自动建共享 chan_month5 指向本机仓库
set "SCRIPTS=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -NoExit -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPTS%share_repo.ps1')"
