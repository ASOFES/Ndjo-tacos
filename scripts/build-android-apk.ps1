param(
  [string]$ApiBase = 'https://ndjo-tacos-production.up.railway.app'
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$App = Join-Path $Root 'app'
$Out = Join-Path $Root 'releases\android'

function Test-Cmd($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Cmd flutter)) {
  Write-Host 'Flutter introuvable. Installez Flutter et rouvrez le terminal.' -ForegroundColor Red
  exit 1
}

Write-Host "Build APK universel NDJO TACOS → $ApiBase" -ForegroundColor Cyan
Set-Location $App
flutter config --enable-android | Out-Null
flutter pub get
flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --dart-define="API_BASE=$ApiBase"

$ApkSrc = Join-Path $App 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $ApkSrc)) {
  Write-Host "Build APK echoue." -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$ApkDest = Join-Path $Out 'NDJO-TACOS.apk'
Copy-Item $ApkSrc $ApkDest -Force
Copy-Item (Join-Path $Root 'scripts\LIRE-MOI-ANDROID.txt') (Join-Path $Out 'LIRE-MOI.txt') -Force

Write-Host ""
Write-Host "APK pret :" -ForegroundColor Green
Write-Host "  $ApkDest"
Write-Host "Copiez ce fichier sur le telephone et ouvrez-le pour installer."
