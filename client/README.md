# yhsmctl Client-Installer

## Zweck
Dieses Verzeichnis enthält die kundenseitigen Installer und das Manifest für `yhsmctl`. Die Binaries werden nicht im Repository abgelegt, sondern als GitHub-Release-Assets bereitgestellt.

## Release-Version im Installer
Beide Installer geben direkt zu Beginn die aufgelöste Client-Release-Version aus:

```text
YHSM Client Release Version: v2.0.0
```

Die Version wird standardmäßig aus `manifest.json` gelesen. Falls das Manifest fehlt, wird `YHSMCTL_VERSION` als Fallback genutzt; im Dry-run werden dabei keine Downloads, API-Aufrufe oder Installationsschritte ausgeführt.

## Dry-run
Linux:

```bash
./client/install.sh --dry-run
```

Windows:

```powershell
./client/install.ps1 -DryRun
```

Erwartetes Ergebnis: Der Installer zeigt Release-Version, Repository und geplante Download-/Prüfschritte an, führt aber nichts aus.

## Repository-Override
Für Tests oder getrennte Release-Repositories bleiben Overrides erhalten:

```bash
./client/install.sh --repo example/yhsm --dry-run
YHSMCTL_REPO=example/yhsm ./client/install.sh --dry-run
```

```powershell
./client/install.ps1 -Repo example/yhsm -DryRun
$env:YHSMCTL_REPO = 'example/yhsm'; ./client/install.ps1 -DryRun
```
