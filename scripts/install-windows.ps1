# Installe NDJO TACOS pour l'utilisateur courant (aucun droit administrateur).
# Fonctionne sur Windows 10/11 64 bits.
$ErrorActionPreference = 'Stop'

$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppName = 'NDJO TACOS'
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\NDJO-TACOS"
$ExeName = 'ndjo_tacos.exe'
$SourceExe = Join-Path $Source $ExeName

if (-not (Test-Path $SourceExe)) {
    Write-Host "Fichier introuvable : $SourceExe" -ForegroundColor Red
    Write-Host "Lancez ce script depuis le dossier de l'application."
    exit 1
}

Write-Host "Installation de $AppName..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $Source '*') -Destination $InstallDir -Recurse -Force

$Exe = Join-Path $InstallDir $ExeName
$Wsh = New-Object -ComObject WScript.Shell

$Desktop = [Environment]::GetFolderPath('Desktop')
$DesktopLink = Join-Path $Desktop "$AppName.lnk"
$Shortcut = $Wsh.CreateShortcut($DesktopLink)
$Shortcut.TargetPath = $Exe
$Shortcut.WorkingDirectory = $InstallDir
$Shortcut.Description = $AppName
$Shortcut.Save()

$StartDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
New-Item -ItemType Directory -Force -Path $StartDir | Out-Null
$StartLink = Join-Path $StartDir "$AppName.lnk"
$Start = $Wsh.CreateShortcut($StartLink)
$Start.TargetPath = $Exe
$Start.WorkingDirectory = $InstallDir
$Start.Description = $AppName
$Start.Save()

$Uninstall = @"
`$dir = '$InstallDir'
Remove-Item -LiteralPath '$DesktopLink' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath '$StartLink' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath `$dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'NDJO TACOS desinstalle.'
"@
Set-Content -Path (Join-Path $InstallDir 'Desinstaller.ps1') -Value $Uninstall -Encoding UTF8

Write-Host ""
Write-Host "Installe dans : $InstallDir" -ForegroundColor Green
Write-Host "Raccourci Bureau et menu Demarrer crees."
Write-Host "Lancez NDJO TACOS depuis le Bureau."
Write-Host ""
Start-Process -FilePath $Exe -WorkingDirectory $InstallDir
