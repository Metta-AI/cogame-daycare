## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Forked from `coworld-ctf/src/ctf/wire_constants.nim`,
## and THE GLOBAL KEEPS ITS NAME: `client/chrome_common.js` reads
## `window.CTF_WIRE` at its line 72 and that file ships BYTE-FOR-BYTE, so
## renaming the global would force a byte change in a file that must not change.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.CTF_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
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
