# YubiHSM Stage-0 bootstrap

This small public package bootstraps repository access for an explicitly authorized YubiHSM pilot or evaluation. It is not an official Yubico repository and is not affiliated with or endorsed by Yubico.

## Quick start

Download and verify the currently qualified Stage-0 bootstrap in one copy-and-paste step:

```sh
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/skk-sec/yhsm/eff68338084c979f52895619ce07d56151b898b4/bootstrap.sh && echo '6ce19f00e28b9c24244c97a5a6266e0f7aacdc44545861668d2e14f01e24dca1  bootstrap.sh' | sha256sum -c -
```

The expected result is:

```text
bootstrap.sh: OK
```

The normal customer-independent entry is parameterless:

```sh
bash ./bootstrap.sh --dry-run
bash ./bootstrap.sh
```

Stage 0 resolves the customer channel before cloning:

1. DNS-first derives the local DNS search domain and reads the TXT contract at `_pki.<domain>`.
2. The record must be unambiguous and contain valid `repo`, `release_channel` and `lab_mode` fields.
3. GitHub Device/Web authentication verifies read access to that already DNS-bound repository; GitHub access is never used to enumerate or guess customer repositories.
4. If DNS is missing or invalid, a separately maintained unique account-to-channel mapping may be used after authentication. Multiple or missing mappings fail closed.
5. If no safe automatic binding exists, the script stops with a sanitized unresolved-target result and requests an explicit override.

DNS is discovery and environment binding only; it is not authorization and must not contain secrets.

The explicit override is available for diagnostics or a separately authorized exception:

```sh
bash ./bootstrap.sh --target-repo <authorized-owner>/<authorized-repository> --dry-run
bash ./bootstrap.sh --target-repo <authorized-owner>/<authorized-repository>
```

The literal forms `owner/repository` and `owner/bues` are documentation placeholders and negative tests. Do not execute them literally. The script rejects common placeholders before package installation or GitHub authentication.

Stage 0 is release-neutral. It does not select, install or infer a product release. Release selection is a later channel-specific step based on a live qualified binding; a moving `latest`, a snapshot or chat history is not a release selector.

The download URL is bound to an immutable Public commit and the SHA-256 is bound to those exact `bootstrap.sh` bytes. Do not replace the immutable ref with `main`, do not skip the checksum verification, and do not pipe a download directly into a shell.

## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host. The normal entry is parameterless:

```sh
bash ./bootstrap.sh --dry-run
bash ./bootstrap.sh
```

Use `--target-repo <authorized-owner>/<authorized-repository>` only as an explicit, separately authorized diagnostic or exception path. The literal `owner/repository` form is a placeholder/negative test only.

For a fresh system, download, integrity verification and execution remain separate trust gates. The immutable download reference and SHA-256 must be checked before Bash executes the file; never replace the immutable reference with `main), skip verification or pipe a download directly into a shell.

Private access uses GitHub Device/Web authentication. A working secure OS credential backend is preferred and remains supported. On a headless host where no usable Secret Service is available, Stage 0 may use an isolated session-only GitHub CLI configuration in a verified RAM-backed temporary directory. That session configuration is removed after success, failure or interruption and must not leave a plaintext token or credential helper in the normal user configuration or cloned repository. Token-bearing GitHub authentication environment variables remain rejected; do not put tokens, passwords, credentials, private keys or authorization data in arguments.

`sudo` is requested only when missing packages must actually be installed. Stage 0 verifies private repository and issue read access, clones the selected branch and prints an exact readback. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only.

The script does not configure a YubiHSM, Connector, DNS, AD or PKI system and does not publish a release.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.
