@echo off
chcp 65001 >nul
setlocal
echo ============================================================
echo   PCB -^> PCA  (\\192.168.1.5\chan_month5, account chansync)
echo   connect + verify + diff check, all logged
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_reverse.ps1"
echo.
echo ==== 结论已写入 a_Data\remote_ctl\reverse_check.log ====
pause
