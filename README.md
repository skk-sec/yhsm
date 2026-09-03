# YubiHSM Stage-0 bootstrap

This small public package bootstraps repository access for an explicitly authorized YubiHSM pilot or evaluation. It is not an official Yubico repository and is not affiliated with or endorsed by Yubico.

## Quick start

Download and verify the currently qualified Stage-0 bootstrap in one copy-and-paste step:

```sh
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/skk-sec/yhsm/0a595fbd6be00de6a608892cd6a4cc7d88626555/bootstrap.sh && echo 'c9fb76e3707e80fc753e516a313bf77f45c3e0100ab975705fe6c0d92c5a7505  bootstrap.sh' | sha256sum -c -
```

The expected result is:

```text
bootstrap.sh: OK
```

After verification, the normal E2E path is one command:

```sh
bash ./bootstrap.sh
```

The normal run resolves and clones the authorized customer repository, verifies the Stage-0 handoff, and automatically starts its executable `run/bootstrap.sh` entrypoint. A second manual customer-bootstrap invocation is not required.

The optional planning check is separate:

```sh
bash ./bootstrap.sh --dry-run
```

It prints the planned package, authentication, routing, clone and issue-write steps, but performs none of them. It is useful for syntax/argument/contract checks; it cannot prove GitHub access, DNS routing, release availability, asset digests or customer-environment readiness.

The download URL is bound to an immutable Public commit and the SHA-256 is bound to those exact `bootstrap.sh` bytes. Do not replace the immutable ref with `main`, do not skip the checksum verification, and do not pipe a download directly into a shell.

## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host. A directly downloaded bootstrap file is not assumed to have an executable mode, so invoke it explicitly with Bash.

For the normal private onboarding path, the execution step is intentionally short:

```sh
bash ./bootstrap.sh
```

`--dry-run` is optional and is not a prerequisite for the normal E2E path.

The normal path derives the local DNS search domain from `/etc/resolv.conf` and, when present, the local `resolvectl` resolver state before it reads `_pki.<domain>` TXT. It accepts exactly one complete, valid binding containing `repo`, `release_channel`, and `lab_mode=1`. Canonical DNS TXT bindings may be semicolon-terminated `key=value` fields split across quoted TXT chunks; only documented metadata keys are accepted, and duplicates, unknown keys, malformed delimiters or missing `schema=1` are rejected. DNS `repo` must use the canonical `https://github.com/<owner>/<repository>` form; shorthand `owner/repository` is not accepted in DNS. The exact endpoint is bound by the authorized DNS channel. DNS binds only the intended pilot channel; it does not grant or prove access. Malformed, incomplete, duplicate, conflicting, ambiguous, non-lab, or DNS-error responses fail closed. The bootstrap ensures the `dig` resolver tool is present before this lookup.

Only after that target is resolved does GitHub Device/Web authentication run. GitHub is used solely to verify repository and issue-read access to the exact DNS-bound target. Stage-0 never enumerates or selects repositories from the general GitHub account.

If no local resolver source can safely provide a domain, or if the DNS channel binding is missing or unavailable, Stage-0 may use the separately maintained `/etc/yhsm/stage0-account-channels` file with exactly one valid entry for the local OS account. A present but malformed, ambiguous, incomplete or conflicting DNS binding never falls back to that map and stops with `HARD_FAIL_TARGET_REPOSITORY_DNS_BINDING_INVALID`. Each non-comment entry uses `account=<local-account> repo=<owner/repository> release_channel=<token> lab_mode=1`; the map is an explicit local account-to-channel binding, not an inference from login name or current directory. If neither source yields one valid binding, Stage 0 stops with `HARD_FAIL_TARGET_REPOSITORY_UNRESOLVED`. `--target-repo` exists only as a separately authorized recovery override. It is never part of the normal customer path, and this guide deliberately embeds no repository value.

For a fresh system, the operator-facing delivery instruction must bind download and verification together so the operator does not need to obtain, transcribe or compare a checksum separately. The immutable commit and SHA-256 above are the maintained Stage-0 download reference. Any newer qualified bootstrap must update this pin and its checksum together before it is published; download, verification and execution remain separate trust gates.

Private access uses GitHub Device/Web authentication. A working secure OS credential backend is preferred and remains supported. On a headless host where no usable Secret Service is available, Stage-0 may use an isolated session-only GitHub CLI configuration in a verified RAM-backed temporary directory. That session configuration is removed after success, failure or interruption and must not leave a plaintext token or credential helper in the normal user configuration or cloned repository. Token-bearing GitHub authentication environment variables remain rejected; do not put tokens, passwords, credentials, private keys or authorization data in arguments.

`sudo` is requested only when missing packages must actually be installed. Stage-0 verifies private repository and issue read access, clones the selected branch and prints an exact readback. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only. The customer bootstrap can write sanitized execution events directly to its already bound private GitHub Issue; Stage 0 never creates an Issue before target binding and authentication. Before that point, a routing failure produces only sanitized local output and an exit status: there is no GitHub login, no GitHub Issues API call, and no public or guessed private support destination. A future pre-Stage-0 support channel would require a separately authorized private control-plane repository and explicit opt-in; it is not part of this public entrypoint.

After successful private clone, exact branch/head readback and session-only postcondition verification, Stage-0 keeps the isolated GitHub CLI session only in verified RAM-backed storage and publishes a non-secret handoff descriptor bound to the exact repository, branch and a maximum 900-second lifetime. A producer-side reaper removes the descriptor and token-bearing session root at expiry, and the producer safely reclaims an expired handoff on retry while refusing to overwrite a live or invalid one. The matching customer bootstrap consumes a valid handoff before any customer credential-store or fallback login, so the authorized E2E path does not require a second Device/Web login. The Stage-0 process starts that customer bootstrap automatically after the clone and readback succeed. The customer side removes the descriptor and session root after extracting the token or on failure/interruption; a missing handoff follows the customer's documented fallback, while an invalid, expired or mismatched handoff fails closed. No token is written to persistent disk, argv, logs, URLs, repository content or normal user Git/GitHub configuration.

The script does not configure a YubiHSM, Connector, DNS, AD, or PKI system and does not publish a release.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.