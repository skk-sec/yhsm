[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$InstallDir = (Join-Path $HOME '.local\bin'),
    [string]$Repo = $env:YHSMCTL_REPO,
    [switch]$DryRun,
    [switch]$Help
)

function Mask-ArgValue {
    param([string]$Value)
    if ($Value -match '^(?<key>[^=]+)=.*$' -and $Matches.key -match '(?i)(token|pass(word)?|secret|key|auth|credential)') { return "$($Matches.key)=***" }
    if ($Value -match '(?i)(token|pass(word)?|secret|key|auth|credential)') { return '***' }
    return $Value
}
$maskedArgs = @($args | ForEach-Object { Mask-ArgValue -Value $_ })
Write-Host "[argv] $($MyInvocation.MyCommand.Path) $($maskedArgs -join ' ')"

function Write-Info { param([string]$Message) Write-Host "[*] $Message" }
function Write-WarnLine { param([string]$Message) Write-Host "[!] $Message" }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" }
function Write-ErrorLine { param([string]$Message) Write-Error "[-] $Message" }
function Show-Usage {
@'
Nutzung:
  ./client/install.ps1 [-Version <vX.Y.Z|latest>] [-InstallDir <Pfad>] [-Repo <owner/repo>] [-DryRun]

Optionen:
  -Version <wert>     Release-Version; Default: latest mit Manifest-Fallback.
  -InstallDir <pfad>  Installationsziel; Default: $HOME\.local\bin.
  -Repo <owner/repo>  GitHub Repository; alternativ YHSMCTL_REPO.
  -DryRun             Aktionen nur anzeigen; nichts herunterladen oder installieren.
  -Help               Diese Hilfe anzeigen.
'@
}

if ($Help) { Show-Usage; exit 0 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-ErrorLine "Manifest fehlt: $manifestPath"; exit 1 }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $manifest.repository }
if ([string]::IsNullOrWhiteSpace($Repo) -or $Repo -eq 'OWNER/REPO') {
    Write-ErrorLine 'GitHub Repository ist nicht konfiguriert. Bitte -Repo <owner/repo> oder YHSMCTL_REPO setzen.'
    exit 2
}

$osName = 'windows'
$arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'unsupported' }
if ($arch -ne 'amd64') { Write-ErrorLine "Nicht unterstützte Architektur: $arch"; exit 2 }
$platform = @($manifest.supported_platforms | Where-Object { $_.os -eq $osName -and $_.arch -eq $arch } | Select-Object -First 1)
if (-not $platform) { Write-ErrorLine "Keine Asset-Zuordnung für $osName-$arch im Manifest."; exit 2 }
$asset = $platform.asset

if ($Version -eq 'latest') {
    try {
        $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'Accept' = 'application/vnd.github+json' }
        $Version = $latest.tag_name
    } catch {
        $Version = $manifest.current_release_version
        Write-WarnLine "Latest Release konnte nicht über GitHub API ermittelt werden; nutze Manifest-Version $Version."
    }
}

function Expand-Template {
    param([string]$Template, [string]$ReleaseVersion, [string]$AssetName, [string]$Repository)
    return $Template.Replace('{version}', $ReleaseVersion).Replace('{asset}', $AssetName).Replace('{repository}', $Repository)
}
$assetUrl = Expand-Template -Template $manifest.release_url_template -ReleaseVersion $Version -AssetName $asset -Repository $Repo
$checksumUrl = Expand-Template -Template $manifest.checksum_url_template -ReleaseVersion $Version -AssetName $asset -Repository $Repo
$target = Join-Path $InstallDir 'yhsmctl.exe'

if ($DryRun) {
    Write-Info "(dry-run) geplant/nicht ausgeführt: Download $assetUrl"
    Write-Info "(dry-run) geplant/nicht ausgeführt: Download $checksumUrl"
    Write-Info "(dry-run) geplant/nicht ausgeführt: SHA256 prüfen und nach $target installieren"
    exit 0
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $assetPath = Join-Path $tempDir $asset
    $checksumPath = Join-Path $tempDir "$asset.sha256"
    Invoke-WebRequest -Uri $assetUrl -OutFile $assetPath
    Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath
    $expected = ((Get-Content -LiteralPath $checksumPath -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { Write-ErrorLine "SHA256-Prüfung fehlgeschlagen: erwartet $expected, erhalten $actual"; exit 1 }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $assetPath -Destination $target -Force
    Write-Success "yhsmctl installiert: $target"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
