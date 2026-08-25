## The wasm entry for the static replay bundle.
##
## Same structure as `coworld-ctf/replay-viewer/ctf_replay.nim`: `stampStage`,
## the five exported entry points and the `emscripten_exit_with_live_runtime()`
## epilogue (without it Nim's `main` destroys every module global while JS keeps
## calling in). `ctf_mismatch_tick` is DROPPED — Daycare records state, so there
## is no re-simulation to mismatch.
##
## THE PACKET BUILT BY `daycare_load_replay` IS THE ONLY ONE CARRYING `meta`
## (aliases, policy names, roles, config and the `secret` block): the chrome
## reads it directly from that first ingest and it is never re-derived from a
## later frame (matrix-games, 2026-08-24).

import
  daycare/[broadcast, global, replays, sim_types]

var
  runtimeLoaded = false
  player: ReplayPlayer
  viewer: ViewerState
  packet: seq[uint8]
  lastError: string
  firstHud = true

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the module's
## own globals instead of trapping. The bundle is linked with
## -s ABORTING_MALLOC=1 and this fixed buffer, stamped BEFORE each risky phase,
## stays readable from JS after the abort (aborting kills the call stack, not
## linear memory), so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent() =
  let snap = player.snapshotAt(player.tick)
  let chrome = buildStateJson(replayChromeInput(player, firstHud))
  firstHud = false
  packet = buildViewerPacket(viewer, snap, chrome)

proc daycareLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "daycare_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    player = loadReplay(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    viewer = initViewerState()
    firstHud = true
    runtimeLoaded = true
    let note = " (yard " & $player.cols & "x" & $player.rows & ", " &
      $player.frames.len & " frames)"
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc daycareInput(data: ptr uint8, length: cint)
    {.exportc: "daycare_input", cdecl.} =
  if not runtimeLoaded:
    return
  try:
    player.applyViewerMessage(data.bytesFromPointer(int(length)))
  except Exception as error:
    lastError = "viewer input: " & error.msg

proc daycareFrame(): cint {.exportc: "daycare_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    player.advance(1)
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc daycarePacketPointer(): ptr uint8 {.exportc: "daycare_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc daycarePacketLength(): cint {.exportc: "daycare_packet_len", cdecl.} =
  cint(packet.len)

proc daycareErrorPointer(): ptr uint8 {.exportc: "daycare_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc daycareErrorLength(): cint {.exportc: "daycare_error_len", cdecl.} =
  cint(lastError.len)

proc daycareStagePointer(): ptr uint8 {.exportc: "daycare_stage_ptr", cdecl.} =
  ## The progress note. Unlike daycare_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc daycareStageLength(): cint {.exportc: "daycare_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the parsed replay and the sprite caches while the wasm module stays
  # alive and JS keeps calling daycare_load_replay/daycare_frame. Unwinding main
  # through emscripten's live-runtime exit skips the destructor epilogue
  # entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
