# Gera o pacote .rbz a partir da fonte (loader + pasta STAND1_Memorial).
# Uso:  powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# Lê a versão do loader
$loader = Join-Path $root "STAND1_Memorial_loader.rb"
$ver = (Select-String -Path $loader -Pattern 'version\s*=\s*"([\d.]+)"').Matches[0].Groups[1].Value
if (-not $ver) { throw "Versão não encontrada no loader." }

$out = Join-Path $root "STAND1_Memorial_v$ver.rbz"
if (Test-Path $out) { Remove-Item $out -Force }

# Arquiva versoes anteriores: mantem so o .rbz atual na pasta principal,
# move os demais para versoes_anteriores/.
$arquivo = Join-Path $root "versoes_anteriores"
New-Item -ItemType Directory -Force $arquivo | Out-Null
Get-ChildItem -Path $root -Filter "STAND1_Memorial_v*.rbz" | Where-Object { $_.Name -ne "STAND1_Memorial_v$ver.rbz" } | ForEach-Object {
  Move-Item $_.FullName (Join-Path $arquivo $_.Name) -Force
}

$tmp = Join-Path $env:TEMP "s1mem_build.zip"
if (Test-Path $tmp) { Remove-Item $tmp -Force }

# Empacota apenas a fonte do plugin (loader na raiz + pasta STAND1_Memorial)
Compress-Archive -Path $loader, (Join-Path $root "STAND1_Memorial") -DestinationPath $tmp -Force
Move-Item $tmp $out

Write-Host "Gerado: $out"

# Atualiza o manifesto de auto-update (versao + url do .rbz), preservando as notas.
$manifesto = Join-Path $root "latest.json"
$notas = "Atualizacao do STAND1_Memorial."
if (Test-Path $manifesto) {
  try { $j = Get-Content $manifesto -Raw | ConvertFrom-Json; if ($j.notas) { $notas = $j.notas } } catch {}
}
$rbzUrl = "https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_Memorial_Plugin/STAND1_Memorial_v$ver.rbz"
$obj = [ordered]@{ versao = $ver; rbz = $rbzUrl; notas = $notas }
# Grava SEM BOM: o Out-File -Encoding utf8 do PowerShell 5.1 adiciona BOM (EF BB BF),
# e o JSON.parse do Ruby falha com BOM no inicio. UTF8Encoding($false) = sem BOM.
[System.IO.File]::WriteAllText($manifesto, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Manifesto atualizado: $manifesto (v$ver)"
