# YubiHSM Stage-0 bootstrap

This small public package bootstraps repository access for an explicitly authorized YubiHSM pilot or evaluation. It is not an official Yubico repository and is not affiliated with or endorsed by Yubico.

## Quick start

Download and verify the currently qualified Stage-0 bootstrap in one copy-and-paste step:

```sh
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/skk-sec/yhsm/7ef1ffdffa112dcebb317c79c28da4153b7a1cd7/bootstrap.sh && echo '5cfac6bad63801e93f4bac14ece4f621eb188b980a1105fc0d71d50fb715457b  bootstrap.sh' | sha256sum -c -
```

The expected result is:

```text
bootstrap.sh: OK
```

Only after that verification succeeds, run the separately downloaded file with Bash and the repository supplied for your authorized channel:

```sh
bash ./bootstrap.sh --dry-run
bash ./bootstrap.sh
```

The download URL is bound to an immutable Public commit and the SHA-256 is bound to those exact `bootstrap.sh` bytes. Do not replace the immutable ref with `main`, do not skip the checksum verification, and do not pipe a download directly into a shell.

## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host. A directly downloaded bootstrap file is not assumed to have an executable mode, so invoke it explicitly with Bash.

For the normal private onboarding path, the execution step is intentionally short:

```sh
bash ./bootstrap.sh --dry-run
bash ./bootstrap.sh
```

The normal path derives the local DNS search domain and reads `_pki.<domain>` TXT. It accepts exactly one complete, valid binding containing `repo`, `release_channel`, and `lab_mode=1`. Canonical DNS TXT bindings may be semicolon-terminated `key=value` fields split across quoted TXT chunks; only documented metadata keys are accepted, and duplicates, unknown keys, malformed delimiters or missing `schema=1` are rejected. DNS `repo` must use the canonical `https://github.com/<owner>/<repository>` form; shorthand `owner/repository` is not accepted in DNS. The exact endpoint is bound by the authorized DNS channel. DNS binds only the intended pilot channel; it does not grant or prove access. Malformed, incomplete, duplicate, conflicting, ambiguous, non-lab, or DNS-error responses fail closed. The bootstrap ensures the `dig` resolver tool is present before this lookup.

Only after that target is resolved does GitHub Device/Web authentication run. GitHub is used solely to verify repository and issue-read access to the exact DNS-bound target. Stage-0 never enumerates or selects repositories from the general GitHub account.

Only an absent TXT response may use the separately maintained `/etc/yhsm/stage0-account-channels` file with exactly one valid entry for the local OS account. A malformed, ambiguous, incomplete or unavailable DNS binding stops with `HARD_FAIL_TARGET_REPOSITORY_UNRESOLVED`; it never falls back to that map. Each non-comment entry uses `account=<local-account> repo=<owner/repository> release_channel=<token> lab_mode=1`; this local map is only the fallback for a successful DNS NODATA/NXDOMAIN result. DNS transport or server errors never use the map. `--target-repo` exists only as a separately authorized recovery override. It is never part of the normal customer path, and this guide deliberately embeds no repository value.

For a fresh system, the operator-facing delivery instruction must bind download and verification together so the operator does not need to obtain, transcribe or compare a checksum separately. The immutable commit and SHA-256 above are the maintained Stage-0 download reference. Any newer qualified bootstrap must update this pin and its checksum together before it is published; download, verification and execution remain separate trust gates.

Private access uses GitHub Device/Web authentication. A working secure OS credential backend is preferred and remains supported. On a headless host where no usable Secret Service is available, Stage-0 may use an isolated session-only GitHub CLI configuration in a verified RAM-backed temporary directory. That session configuration is removed after success, failure or interruption and must not leave a plaintext token or credential helper in the normal user configuration or cloned repository. Token-bearing GitHub authentication environment variables remain rejected; do not put tokens, passwords, credentials, private keys or authorization data in arguments.

`sudo` is requested only when missing packages must actually be installed. Stage-0 verifies private repository and issue read access, clones the selected branch and prints an exact readback. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only.

The RAM-backed Stage-0 session is deliberately removed after onboarding. A later private package operation may therefore require its own bounded second Device/Web login. No single-login handoff or credential continuity is claimed.

The script does not configure a YubiHSM, Connector, DNS, AD, or PKI system and does not publish a release.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.