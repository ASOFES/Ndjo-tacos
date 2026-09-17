param(
  [string]$ApiBase = 'https://ndjo-tacos-production.up.railway.app'
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$App = Join-Path $Root 'app'
$Out = Join-Path $Root 'releases\windows'
$Stage = Join-Path $Out 'NDJO-TACOS'

function Test-Cmd($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Cmd flutter)) {
  Write-Host 'Flutter introuvable. Installez Flutter et rouvrez le terminal.' -ForegroundColor Red
  exit 1
}

Write-Host "Build Windows NDJO TACOS → $ApiBase" -ForegroundColor Cyan
Set-Location $App
flutter config --enable-windows-desktop | Out-Null
if (-not (Test-Path (Join-Path $App 'windows\CMakeLists.txt'))) {
  flutter create --platforms=windows . --project-name ndjo_tacos --org com.ndjotacos
}
flutter pub get
flutter build windows --release --dart-define="API_BASE=$ApiBase"

$Release = Join-Path $App 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $Release 'ndjo_tacos.exe'))) {
  Write-Host "Build Windows echoue : ndjo_tacos.exe introuvable." -ForegroundColor Red
  exit 1
}

Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item -Path (Join-Path $Release '*') -Destination $Stage -Recurse -Force
Copy-Item (Join-Path $Root 'scripts\install-windows.ps1') (Join-Path $Stage 'Installer.ps1') -Force
Copy-Item (Join-Path $Root 'scripts\Installer-NDJO-TACOS.bat') (Join-Path $Stage 'Installer-NDJO-TACOS.bat') -Force
Copy-Item (Join-Path $Root 'scripts\LIRE-MOI-WINDOWS.txt') (Join-Path $Stage 'LIRE-MOI.txt') -Force

$Zip = Join-Path $Out 'NDJO-TACOS-Windows-Setup.zip'
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force

Write-Host ""
Write-Host "Setup Windows pret :" -ForegroundColor Green
Write-Host "  Dossier : $Stage"
Write-Host "  Zip     : $Zip"
Write-Host "Sur un autre PC : decomprimez le zip, puis double-cliquez Installer-NDJO-TACOS.bat"
