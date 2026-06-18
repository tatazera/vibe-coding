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

$tmp = Join-Path $env:TEMP "s1mem_build.zip"
if (Test-Path $tmp) { Remove-Item $tmp -Force }

# Empacota apenas a fonte do plugin (loader na raiz + pasta STAND1_Memorial)
Compress-Archive -Path $loader, (Join-Path $root "STAND1_Memorial") -DestinationPath $tmp -Force
Move-Item $tmp $out

Write-Host "Gerado: $out"
