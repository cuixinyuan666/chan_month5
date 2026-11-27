@echo off
set TG_BOT_TOKEN=8912050396:AAFMZIxx_h1aE1ndZRl2z-FUO0eq7Cu8dgo
set TG_CHAT_ID=8194035177
set TG_PROXY=127.0.0.1:19828
cd /d D:\2\chan_month5\CHAN_RUST\scripts
:loop
python pipeline_stream_ticks.py >> G:\chan_month5_data\pipeline_stream_stdout.log 2>&1
echo [%date% %time%] pipeline exited code %errorlevel%, restart in 10s >> G:\chan_month5_data\pipeline_supervisor.log
timeout /t 10 /nobreak >nul
goto loop
