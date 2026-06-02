[CmdletBinding()]
param(
    [string]$Version = '',
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
$rawArgs = @()
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($entry.Value -is [switch] -or $entry.Value -is [System.Management.Automation.SwitchParameter]) {
        if ($entry.Value.IsPresent) { $rawArgs += "-$($entry.Key)" }
    } else {
        $rawArgs += "-$($entry.Key)"
        $rawArgs += [string]$entry.Value
    }
}
$rawArgs += $args
$maskedArgs = @($rawArgs | ForEach-Object { Mask-ArgValue -Value $_ })
$scriptName = [IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
Write-Host "[argv] $scriptName $($maskedArgs -join ' ')"

function Write-Info { param([string]$Message) Write-Host "[*] $Message" }
function Write-WarnLine { param([string]$Message) Write-Host "[!] $Message" }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" }
function Write-ErrorLine { param([string]$Message) Write-Error "[-] $Message" }
function Show-Usage {
@'
Nutzung:
  ./client/install.ps1 [-Version <vX.Y.Z|latest>] [-InstallDir <Pfad>] [-Repo <owner/repo>] [-DryRun]

Optionen:
  -Version <wert>     Release-Version; Default: current_release_version aus manifest.json; Fallback: YHSMCTL_VERSION.
  -InstallDir <pfad>  Installationsziel; Default: $HOME\.local\bin.
  -Repo <owner/repo>  GitHub Repository; alternativ YHSMCTL_REPO. Default: https://github.com/skk-sec/yhsm.
  -DryRun             Aktionen nur anzeigen; nichts herunterladen oder installieren.
  -Help               Diese Hilfe anzeigen.
'@
}

if ($Help) { Show-Usage; exit 0 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$manifestAvailable = Test-Path -LiteralPath $manifestPath
$manifest = $null
if ($manifestAvailable) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    if ($manifestAvailable -and -not [string]::IsNullOrWhiteSpace($manifest.current_release_version)) {
        $Version = $manifest.current_release_version
    } elseif (-not [string]::IsNullOrWhiteSpace($env:YHSMCTL_VERSION)) {
        $Version = $env:YHSMCTL_VERSION
    } else {
        $Version = 'unknown'
    }
}
if ($Version -eq 'latest' -and $manifestAvailable) {
    $Version = $manifest.current_release_version
}
Write-Host "YHSM Client Release Version: $Version"
if (-not $manifestAvailable) {
    if (-not [string]::IsNullOrWhiteSpace($env:YHSMCTL_VERSION)) {
        Write-WarnLine "Manifest fehlt; nutze YHSMCTL_VERSION als Release-Version."
    } else {
        Write-WarnLine "Manifest fehlt und YHSMCTL_VERSION ist nicht gesetzt; Release-Version ist unbekannt."
    }
    if ($DryRun) {
        Write-Info "(dry-run) geplant/nicht ausgeführt: Manifest-basierte Download-URLs können nicht aufgelöst werden."
        exit 0
    }
    Write-ErrorLine "Manifest fehlt; Installation benötigt client/manifest.json."
    exit 1
}

function Resolve-RepoUrl {
    param([string]$Repository)
    $resolved = ($Repository ?? '').Trim().TrimEnd('/')
    if ($resolved.StartsWith('https://github.com/')) { return $resolved }
    if ($resolved.StartsWith('http://github.com/')) { return "https://github.com/$($resolved.Substring('http://github.com/'.Length))" }
    if ($resolved.Contains('/')) { return "https://github.com/$resolved" }
    return $resolved
}
function Resolve-RepoSlug {
    param([string]$ResolvedRepoUrl)
    return $ResolvedRepoUrl.TrimEnd('/') -replace '^https://github\.com/', ''
}

$RepoUrl = "https://github.com/skk-sec/yhsm"
if (-not [string]::IsNullOrWhiteSpace($Repo)) {
    $RepoUrl = Resolve-RepoUrl -Repository $Repo
} elseif (-not [string]::IsNullOrWhiteSpace($manifest.repository) -and $manifest.repository -ne 'OWNER/REPO') {
    $RepoUrl = Resolve-RepoUrl -Repository $manifest.repository
}
$Repo = Resolve-RepoSlug -ResolvedRepoUrl $RepoUrl
if ([string]::IsNullOrWhiteSpace($Repo) -or $Repo -eq $RepoUrl -or $Repo -eq 'OWNER/REPO') {
    Write-ErrorLine "GitHub Repository ist ungültig: $RepoUrl. Bitte -Repo <owner/repo> oder YHSMCTL_REPO prüfen."
    exit 2
}
Write-Info "Repository: $RepoUrl"

$osName = 'windows'
$arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'unsupported' }
if ($arch -ne 'amd64') { Write-ErrorLine "Nicht unterstützte Architektur: $arch"; exit 2 }
$platform = @($manifest.supported_platforms | Where-Object { $_.os -eq $osName -and $_.arch -eq $arch } | Select-Object -First 1)
if (-not $platform) { Write-ErrorLine "Keine Asset-Zuordnung für $osName-$arch im Manifest."; exit 2 }
$asset = $platform.asset

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
