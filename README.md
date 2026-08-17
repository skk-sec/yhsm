# YubiHSM Stage-0 bootstrap

This small public package bootstraps repository access for an explicitly authorized YubiHSM pilot or evaluation. It is not an official Yubico repository and is not affiliated with or endorsed by Yubico.

## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host and always name the repository supplied for your authorized channel. A directly downloaded bootstrap file is not assumed to have an executable mode, so invoke it explicitly with Bash.

For the normal private onboarding path, the execution step is intentionally short:

```sh
bash ./bootstrap.sh owner/repository --dry-run
bash ./bootstrap.sh owner/repository
```

The positional `owner/repository` form is an explicit shorthand for `--target-repo owner/repository`; there is still no implicit private target. The long form remains supported when advanced options are needed:

```sh
bash ./bootstrap.sh --private-target --target-repo owner/repository
```

For a fresh system, the operator-facing delivery instruction should provide one pre-bound **download-and-verify** command that contains both an immutable Public Stage-0 ref and the expected SHA-256. The operator should not have to obtain, transcribe or compare a checksum separately. A delivery command follows this contract:

```sh
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location 'https://raw.githubusercontent.com/skk-sec/yhsm/<immutable-ref>/bootstrap.sh' -o bootstrap.sh && printf '%s  %s\n' '<expected-sha256>' 'bootstrap.sh' | sha256sum -c -
```

`<immutable-ref>` and `<expected-sha256>` are release-bound values supplied together by the authorized delivery channel; do not replace the immutable ref with `main` and do not invent the checksum. Only after the command reports `bootstrap.sh: OK` is the separately downloaded file executed with Bash. Download/verification and execution therefore remain separate trust gates even though download plus SHA-256 verification is one operator action. Do not pipe a download directly into a shell.

Private access uses GitHub Device/Web authentication. A working secure OS credential backend is preferred and remains supported. On a headless host where no usable Secret Service is available, Stage-0 may use an isolated session-only GitHub CLI configuration in a verified RAM-backed temporary directory. That session configuration is removed after success, failure or interruption and must not leave a plaintext token or credential helper in the normal user configuration or cloned repository. Token-bearing GitHub authentication environment variables remain rejected; do not put tokens, passwords, credentials, private keys or authorization data in arguments.

`sudo` is requested only when missing packages must actually be installed. Stage-0 verifies private repository and issue read access, clones the selected branch and prints an exact readback. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only.

The script does not configure a YubiHSM, Connector, DNS, AD, or PKI system and does not publish a release.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.
