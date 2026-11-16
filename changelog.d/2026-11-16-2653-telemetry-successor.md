# Local pending feedback candidate

Retain redacted early errors privately after a saved telemetry opt-in, without
changing licence/auth decisions. Keep the released README pin pending separate
publication. Offline regressions preserve denied/unknown and legacy behavior.

## Local pending IO correction

Serialize short pending-file IO with an owner/mode/link/size-validated private
kernel lock and a five-second acquisition bound. A duplicate writer cannot read
unfinished JSON. Unsafe/partial state is retained; no reset or upload is added.
The separate released README pin and all licence/auth behavior remain unchanged.
