@echo off
chcp 65001 >nul
setlocal
set "SCRIPTS=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTS%check_reverse.ps1"
echo.
echo ==== 结论已写入 a_Data\remote_ctl\reverse_check.log ====
echo 这个窗口可以关了（或按任意键）。
pause >nul
