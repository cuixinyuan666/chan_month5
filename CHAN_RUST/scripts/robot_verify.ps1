# USER manual flow only (see agent.md). Do NOT use for full automation.
# 1) User: build_rust.ps1 or flutter build windows
# 2) User: ensure a_Data/robot_verify/session.json active=true
# 3) User: set CHAN_REPO_ROOT (optional) and launch chan_kline.exe
#    OR launch via flutter run with session active (App auto-enters robot mode)
# 4) Agent: robot_verify_agent_finish.ps1 after status.json phase=done

Write-Host @"
Robot verify (semi-auto)
========================
You: compile + open App (session.json active=true).
App: runs full suite, writes:
  a_Data/robot_verify/last_report.txt
  a_Data/robot_verify/status.json
App: progress UI -> clipboard on done -> you close window manually
Optional: agent re-copy from last_report.txt:
  powershell -File CHAN_RUST/scripts/robot_verify_agent_finish.ps1

Optional env: CHAN_REPO_ROOT, CHAN_KLINE_ROOT
"@
