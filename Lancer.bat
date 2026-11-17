@echo off
powershell -STA -ExecutionPolicy Bypass -File GGUFChat.ps1


start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0GGUFChat.ps1"
