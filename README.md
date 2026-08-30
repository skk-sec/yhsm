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

Only after that verification succeeds, run the separately downloaded file with Bash and the exact repository supplied by your authorized channel instruction:

```sh
bash ./bootstrap.sh <authorized-owner>/<authorized-repository> --dry-run
bash ./bootstrap.sh <authorized-owner>/<authorized-repository>
```

`owner/repository` is documentation syntax only. Do not execute it literally. The `--dry-run` prints the plan but does not prove that the target repository exists or that your account can access it. If the channel instruction does not provide an explicit authorized target, stop and obtain the channel binding; do not guess a repository.

The download URL is bound to an immutable Public commit and the SHA-256 is bound to those exact `bootstrap.sh` bytes. Do not replace the immutable ref with `main`, do not skip the checksum verification, and do not pipe a download directly into a shell.

## Release selection and BUES/GEV channel rule

Stage 0 is release-neutral. After the authorized channel has been established, resolve the current qualified release live from that channel and bind it to its exact version, commit, manifest and asset SHA-256 values. Never reuse a release from memory, a snapshot or a moving `latest` label.

BUES and GEV are separate channels and may have different current qualified releases. Equality is required only when the operation explicitly declares a byte-identical BUES→GEV mirror or promotion. In that case, compare the exact version, source binding, manifest and asset hashes before proceeding.
## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host and always name the repository supplied for your authorized channel. A directly downloaded bootstrap file is not assumed to have an executable mode, so invoke it explicitly with Bash.

For the normal private onboarding path, the execution step is intentionally short:

```sh
bash ./bootstrap.sh owner/repository --dry-run
bash ./bootstrap.sh owner/repository
```

The positional `<authorized-owner>/<authorized-repository>` form is an explicit shorthand for `--target-repo <authorized-owner>/<authorized-repository>`; there is still no implicit private target. The literal `owner/repository` form is a placeholder/negative test only. The long form remains supported when advanced options are needed:

```sh
bash ./bootstrap.sh --private-target --target-repo owner/repository
```

For a fresh system, the operator-facing delivery instruction must bind download and verification together so the operator does not need to obtain, transcribe or compare a checksum separately. A future Stage-0 release may shorten the URL further by publishing `bootstrap.sh` and its checksum as immutable release assets, but download, verification and execution remain separate trust gates.

Private access uses GitHub Device/Web authentication. A working secure OS credential backend is preferred and remains supported. On a headless host where no usable Secret Service is available, Stage-0 may use an isolated session-only GitHub CLI configuration in a verified RAM-backed temporary directory. That session configuration is removed after success, failure or interruption and must not leave a plaintext token or credential helper in the normal user configuration or cloned repository. Token-bearing GitHub authentication environment variables remain rejected; do not put tokens, passwords, credentials, private keys or authorization data in arguments.

`sudo` is requested only when missing packages must actually be installed. Stage-0 verifies private repository and issue read access, clones the selected branch and prints an exact readback. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only.

The script does not configure a YubiHSM, Connector, DNS, AD, or PKI system and does not publish a release.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.
