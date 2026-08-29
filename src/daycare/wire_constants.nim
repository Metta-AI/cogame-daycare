## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Forked from `coworld-ctf/src/ctf/wire_constants.nim`,
## and THE GLOBAL KEEPS ITS NAME: `client/chrome_common.js` reads
## `window.CTF_WIRE` at its line 72 and that file ships byte-for-byte apart
## from the fleet-wide 0.5x transport patch, so the global is not renamed.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeed, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:" & $ShotFxTicks &
  ",shotTrailFalloff:" & $TrailFalloff &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before any
  ## script that reads window.CTF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
