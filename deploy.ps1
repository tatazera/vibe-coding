# Deploy Stand1 Dashboard
# Uso: clique duplo ou rode no PowerShell

$SERVER = "root@189.126.106.238"
$HTML   = "f:\1 - TORRENT\5 - INSTALADOS\Dashboard STAND1\stand1_dashboard.html"
$JS     = "f:\1 - TORRENT\5 - INSTALADOS\Dashboard STAND1\server.js"

Write-Host "Enviando arquivos para o servidor..." -ForegroundColor Cyan

scp $HTML "${SERVER}:/app/html/index.html"
scp $JS   "${SERVER}:/app/server.js"

Write-Host "Reiniciando containers..." -ForegroundColor Cyan
ssh $SERVER "cd /app && docker compose up -d --build"

Write-Host "Deploy concluido!" -ForegroundColor Green
Write-Host "Acesse: http://189.126.106.238" -ForegroundColor Yellow
