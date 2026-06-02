# yhsmctl Client-Distribution

## Ziel und Scope

`client/` enthält nur kundenseitige Installer, Manifest, Dokumentation und Konfiguration. Kompilierte Binaries werden nicht im Repository abgelegt, sondern als GitHub-Release-Artefakte veröffentlicht.

## Installation Linux

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/client/install.sh -o install-yhsmctl.sh
chmod +x install-yhsmctl.sh
YHSMCTL_REPO=<owner>/<repo> ./install-yhsmctl.sh
```

Erwartetes Ergebnis: `yhsmctl` liegt unter `~/.local/bin/yhsmctl` und die SHA256-Prüfung wurde erfolgreich durchgeführt.

## Installation Windows

```powershell
$env:YHSMCTL_REPO = '<owner>/<repo>'
./client/install.ps1
```

Erwartetes Ergebnis: `yhsmctl.exe` liegt unter `$HOME\.local\bin\yhsmctl.exe` und die SHA256-Prüfung wurde erfolgreich durchgeführt.

## Release-Artefakte bauen

```bash
./build-client-package.sh --version v2.0.0
```

Die Artefakte entstehen unter `dist/client/<version>/` und sind für GitHub Releases bestimmt. `client/` bleibt frei von Binaries.
