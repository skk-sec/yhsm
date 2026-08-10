# yhsmctl Client-Installer

## Stage 0 — frischer Linux-Host ohne git/gh

`client/bootstrap.sh` ist der öffentliche Stage-0-Einstieg für einen frischen Debian-/Ubuntu-Host. Er installiert nur die für den Repositoryzugriff notwendigen Basistools und führt keine DNS-, Connector-, HSM-, AD- oder PKI-Mutation aus.

Sicherer Start ohne vorinstalliertes `git` oder `gh`:

1. `client/bootstrap.sh` über einen ausdrücklich genannten **immutable Commit-SHA** aus diesem öffentlichen Repository herunterladen.
2. SHA-256 separat prüfen.
3. Erst danach mit `bash` ausführen.
4. Kein `curl | sh`.

Aktueller privater Pilotkanal:

```bash
./client/bootstrap.sh --target-repo skk-sec/yhsm-customer-pilot --target-branch main --private-target
```

Bei einem späteren vollständig öffentlichen Kanal ist kein GitHub-Login erforderlich:

```bash
./client/bootstrap.sh --target-repo skk-sec/yhsm --target-branch main --public-target
```

Nur Plan anzeigen:

```bash
./client/bootstrap.sh --dry-run
```

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
