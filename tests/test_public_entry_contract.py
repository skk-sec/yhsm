#!/usr/bin/env python3
"""Regression gate for the customer-independent public Stage-0 contract."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
README = (ROOT / "README.md").read_text(encoding="utf-8")
BOOTSTRAP = (ROOT / "bootstrap.sh").read_text(encoding="utf-8")
WORKFLOW = (
    ROOT / ".github/workflows/bootstrap-integrity.yml"
).read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise SystemExit(f"public-entry-contract: FAIL: {message}")


normal_command = "PYTHONDONTWRITEBYTECODE=1 bash ./bootstrap.sh"
normal_invocations = re.findall(
    r"(?m)^(?:PYTHONDONTWRITEBYTECODE=1 )?bash \./bootstrap\.sh$",
    README,
)
if normal_invocations != [normal_command, normal_command]:
    fail(
        "README must contain exactly two protected normal invocations and no "
        "unprotected normal invocation"
    )

required_statements = (
    "This README is the complete executable instruction for every authorized "
    "pilot channel.",
    "No preliminary host, user, shell, working-directory, management-path or "
    "authorization reply is required.",
    "After the run, provide only sanitized feedback through the separately "
    "provided private GitHub issue channel.",
)
for statement in required_statements:
    if statement not in README:
        fail(f"required customer operating-model statement missing: {statement!r}")

shell_blocks = re.findall(r"```sh\n(.*?)\n```", README, flags=re.DOTALL)
for block in shell_blocks:
    for forbidden in (
        "--target-repo",
        "--release-channel",
        "--lab-mode",
        "TARGET_REPO=",
        "RELEASE_CHANNEL=",
        "LAB_MODE=",
    ):
        if forbidden in block:
            fail(f"normal public command embeds routing input {forbidden!r}")

allowed_repository_urls = {
    "skk-sec/yhsm",
    "<owner>/<repository>",
}
for match in re.finditer(
    r"https://github\.com/(?P<owner>[^/\s`]+)/(?P<repo>[^/\s`]+)",
    README,
):
    repository = (
        f"{match.group('owner')}/{match.group('repo')}".rstrip(".,;:)")
    )
    if repository not in allowed_repository_urls:
        fail(f"README embeds concrete non-entry repository {repository!r}")

allowed_repo_bindings = {
    "<owner/repository>",
    "https://github.com/<owner>/<repository>",
}
for value in re.findall(r"\brepo=([^\s;`]+)", README):
    if value not in allowed_repo_bindings:
        fail(f"README embeds concrete repo binding {value!r}")

if re.search(r"\bv\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b", README):
    fail("README embeds a concrete private release version")

for variable in ("TARGET_REPO", "RELEASE_CHANNEL", "LAB_MODE"):
    if not re.search(rf'(?m)^{variable}=""$', BOOTSTRAP):
        fail(f"bootstrap default {variable} is not empty")

workflow_requirements = (
    "- 'tests/**'",
    "python3 tests/test_public_entry_contract.py",
    "bash tests/test_stage0_resolver_contract.sh",
)
for requirement in workflow_requirements:
    if requirement not in WORKFLOW:
        fail(f"workflow requirement missing: {requirement!r}")

print("public_entry_customer_independent=true")
print("normal_invocation_bytecode_protected=true")
print("routing_defaults_empty=true")
print("workflow_contract=OK")
