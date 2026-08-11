# YubiHSM Stage-0 bootstrap

This small public package bootstraps repository access for an explicitly authorized YubiHSM pilot or evaluation. It is not an official Yubico repository and is not affiliated with or endorsed by Yubico.

## Safe use

Read `LICENSE` before use. Run the script only on a Debian/Ubuntu pilot host and always name the repository supplied for your authorized channel. A directly downloaded bootstrap file is not assumed to have an executable mode, so invoke it explicitly with Bash:

```sh
bash ./bootstrap.sh --private-target --target-repo owner/repository --dry-run
bash ./bootstrap.sh --private-target --target-repo owner/repository
```

When the bootstrap is obtained by direct HTTPS download, verify the separately supplied SHA-256 before running `bash ./bootstrap.sh`. Do not pipe a download directly into a shell.

There is no implicit target repository. `--target-repo` is mandatory. Do not put tokens, passwords, credentials, private keys, or authorization data in arguments. Private access uses GitHub Device/Web authentication and requires a secure OS credential backend; the bootstrap fails closed rather than accepting plaintext token storage. `sudo` is requested only when missing packages must actually be installed.

The script does not configure a YubiHSM, Connector, DNS, AD, or PKI system and does not publish a release. The optional issue smoke test must be explicitly selected and uses sanitized temporary content only.

## License and support boundary

The interim proprietary `LICENSE` permits only the stated authorized pilot/evaluation use. It does not grant modification, general redistribution, sublicensing, or independent commercial reuse. Final legal review remains pending.

No general support, maintenance, service level, production-readiness, or Yubico support commitment is included. Submit only sanitized pilot feedback through the channel separately provided by the pilot operator; never include secrets, credentials, keys, private evidence, or unrelated repository details.

## Third-party material

This Stage-0 package contains only `bootstrap.sh`, this README, and the proprietary `LICENSE`. It does not bundle third-party source, binaries, fonts, media, or copied documentation. The script downloads or invokes separately distributed system tools from their official channels; those tools remain governed by their own terms. Therefore no `THIRD_PARTY_NOTICES` artifact is required for this exact package.
