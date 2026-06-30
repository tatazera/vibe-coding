# Gera o pacote .rbz a partir da fonte (loader + pasta STAND1_EVA).
# Uso:  powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# Le a versao do loader
$loader = Join-Path $root "STAND1_EVA_loader.rb"
$ver = (Select-String -Path $loader -Pattern "version\s*=\s*'([\d.]+)'").Matches[0].Groups[1].Value
if (-not $ver) { throw "Versao nao encontrada no loader." }

$out = Join-Path $root "STAND1_EVA_v$ver.rbz"
if (Test-Path $out) { Remove-Item $out -Force }

# Arquiva versoes anteriores: mantem so o .rbz atual na pasta principal.
$arquivo = Join-Path $root "versoes_anteriores"
New-Item -ItemType Directory -Force $arquivo | Out-Null
Get-ChildItem -Path $root -Filter "STAND1_EVA_v*.rbz" | Where-Object { $_.Name -ne "STAND1_EVA_v$ver.rbz" } | ForEach-Object {
  Move-Item $_.FullName (Join-Path $arquivo $_.Name) -Force
}

# Empacota com barras NORMAIS (/) — o instalador .rbz do SketchUp exige forward
# slash. O Compress-Archive do PowerShell grava com barra invertida (\), que pode
# fazer o SketchUp nao reconhecer a estrutura. Usamos ZipArchive direto.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::Open($out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  # Loader na raiz do pacote
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $loader, "STAND1_EVA_loader.rb") | Out-Null

  # Todos os arquivos da pasta STAND1_EVA, com caminho relativo em forward slash
  $srcDir = Join-Path $root "STAND1_EVA"
  Get-ChildItem -Path $srcDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel) | Out-Null
  }
} finally {
  $zip.Dispose()
}

Write-Host "Gerado: $out"

# Atualiza o manifesto de auto-update (versao + url do .rbz), preservando as notas.
$manifesto = Join-Path $root "latest.json"
$notas = "Atualizacao do EVA Stand1."
if (Test-Path $manifesto) {
  try { $j = Get-Content $manifesto -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.notas) { $notas = $j.notas } } catch {}
}
$rbzUrl = "https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_EVA/STAND1_EVA_v$ver.rbz"
$obj = [ordered]@{ versao = $ver; rbz = $rbzUrl; notas = $notas }
# Grava SEM BOM: o JSON.parse do Ruby falha com BOM (EF BB BF) no inicio.
[System.IO.File]::WriteAllText($manifesto, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Manifesto atualizado: $manifesto (v$ver)"
