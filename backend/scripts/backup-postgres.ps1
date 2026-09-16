$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $PSScriptRoot '..\backups'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "ndjo-tacos-$stamp.sql"
$envFile = Join-Path $PSScriptRoot '..\.env'
$url = 'postgresql://ndjo:ndjo@localhost:5432/ndjo_tacos'
if (Test-Path $envFile) {
  $line = Select-String -Path $envFile -Pattern '^DATABASE_URL=' | Select-Object -First 1
  if ($line) { $url = $line.Line -replace '^DATABASE_URL=', '' -replace '"', '' }
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
  docker compose -f (Join-Path $PSScriptRoot '..\docker-compose.yml') exec -T postgres pg_dump -U ndjo ndjo_tacos | Set-Content -Path $file -Encoding utf8
} elseif (Get-Command pg_dump -ErrorAction SilentlyContinue) {
  pg_dump $url | Set-Content -Path $file -Encoding utf8
} else {
  throw 'Ni Docker ni pg_dump. Installez PostgreSQL 16 ou Docker Desktop.'
}
Write-Host "Sauvegarde : $file"
Write-Host "Restauration : .\scripts\restore-postgres.ps1 -File `"$file`""
