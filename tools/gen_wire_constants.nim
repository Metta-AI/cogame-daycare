## Emits the wire-constants JS block for the static wasm bundle
## (Dockerfile.replay-viewer pipes stdout into replay-viewer/dist/
## wire_constants.js). The native server splices the same string from
## src/daycare/wire_constants.nim, so the two can never drift.
import daycare/wire_constants

when isMainModule:
  echo WireConstantsJs
