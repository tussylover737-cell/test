#!/bin/bash

echo "======================================="
echo " VPS AI AUTOMATION ENVIRONMENT CHECK"
echo "======================================="
echo

echo "===== SYSTEM ====="
hostname
uname -a
echo

echo "===== CPU ====="
lscpu | grep "Model name"
echo

echo "===== MEMORY ====="
free -h
echo

echo "===== DISK ====="
df -h /
echo

echo "===== NODE.JS ====="
which node >/dev/null 2>&1 && node -v || echo "Not Installed"
echo

echo "===== NPM ====="
which npm >/dev/null 2>&1 && npm -v || echo "Not Installed"
echo

echo "===== N8N ====="
which n8n >/dev/null 2>&1 && n8n --version || echo "Not Installed"
echo

echo "===== OLLAMA ====="
which ollama >/dev/null 2>&1 && ollama --version || echo "Not Installed"

if command -v ollama >/dev/null 2>&1; then
    echo
    echo "Installed Models:"
    ollama list
fi
echo

echo "===== FFMPEG ====="
which ffmpeg >/dev/null 2>&1 && ffmpeg -version | head -1 || echo "Not Installed"
echo

echo "===== PYTHON ====="
which python3 >/dev/null 2>&1 && python3 --version || echo "Not Installed"
echo

echo "===== PIP ====="
which pip3 >/dev/null 2>&1 && pip3 --version || echo "Not Installed"
echo

echo "===== WHISPER ====="
python3 -m pip show openai-whisper 2>/dev/null | grep Version || echo "Not Installed"
echo

echo "===== DOCKER ====="
which docker >/dev/null 2>&1 && docker --version || echo "Not Installed"
echo

echo "===== DOCKER CONTAINERS ====="
docker ps -a 2>/dev/null || echo "Docker not running"
echo

echo "===== PM2 ====="
which pm2 >/dev/null 2>&1 && pm2 list || echo "Not Installed"
echo

echo "===== NGINX ====="
which nginx >/dev/null 2>&1 && nginx -v 2>&1 || echo "Not Installed"
echo

echo "===== OPEN PORTS ====="
ss -tulpn
echo

echo "===== RUNNING SERVICES ====="
systemctl list-units --type=service --state=running
echo

echo "===== N8N PROCESS ====="
ps aux | grep n8n | grep -v grep
echo

echo "===== OLLAMA PROCESS ====="
ps aux | grep ollama | grep -v grep
echo

echo "======================================="
echo " CHECK COMPLETE"
echo "======================================="
