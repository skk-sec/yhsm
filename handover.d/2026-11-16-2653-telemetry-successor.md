# Local pending feedback candidate

This Draft adds only the generic, redacted early-error pending slice. Reading
the existing host/user-bound telemetry choice is allowed; setters remain hidden.
Unknown or denied consent and Dry-Run do not create automatic pending events.
Licence receipt Python, acceptance, texts and authentication are preserved.
Offline tests cover redaction, permissions, denial, deduplication and unsafe or
legacy state. No network or installation is part of those tests.

The existing README pin intentionally remains the released entry. Therefore
the existing exact-pin integrity gate is expected to block this Draft until a
separately approved publication binds the new immutable bytes. No workflow
weakening, release, Main pin activation or customer action is included.

## Local pending IO correction

Serialize short pending-file IO with an owner/mode/link/size-validated private
kernel lock and a five-second acquisition bound. A duplicate writer cannot read
unfinished JSON. Unsafe/partial state is retained; no reset or upload is added.
The separate released README pin and all licence/auth behavior remain unchanged.
