param(
  [Parameter(Mandatory = $true)]
  [string]$File
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $File)) { throw "Fichier introuvable : $File" }

if (Get-Command docker -ErrorAction SilentlyContinue) {
  Get-Content -Raw $File | docker compose -f (Join-Path $PSScriptRoot '..\docker-compose.yml') exec -T postgres psql -U ndjo -d ndjo_tacos
} elseif (Get-Command psql -ErrorAction SilentlyContinue) {
  Get-Content -Raw $File | psql 'postgresql://ndjo:ndjo@localhost:5432/ndjo_tacos'
} else {
  throw 'Ni Docker ni psql. Installez PostgreSQL 16 ou Docker Desktop.'
}
Write-Host "Restauration appliquée depuis $File"
