@echo off
wpeinit

REM Optional: make sure X: is initialized
echo [startnet] WinPE started. Launching bootstrap...

REM Prefer running from X:\ablestack\scripts if injected
if exist X:\ablestack\scripts\bootstrap.cmd (
  call X:\ablestack\scripts\bootstrap.cmd
) else (
  echo [startnet] ERROR: X:\ablestack\scripts\bootstrap.cmd not found.
  echo [startnet] Dropping to cmd.exe
  cmd.exe
)
