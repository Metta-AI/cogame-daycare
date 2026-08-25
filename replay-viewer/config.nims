import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead, which is how the
# use-after-free fixed in daycare_replay.nim (emscripten_exit_with_live_runtime)
# was found. Keep this so any future stale free crashes at the fault instead
# of corrupting replay playback at a distance.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped static bundle owns the WASM
# runtime in a Dedicated Worker, and node so CI can smoke-run that EXACT emitted
# module (the wasm-viewer CI job) — wasm32-only failures (int overflow traps,
# 2 GB address-space exhaustion) are invisible to the native 64-bit tests.
# ABORTING_MALLOC matters: with -d:useMalloc Nim never checks malloc for
# nil (that path is `when defined(zephyr)`-only), and wasm32 has no memory
# protection, so a failed allocation would otherwise write the seq header
# through the nil pointer into address 0 — silently corrupting the module's
# own globals, which is how oversized replays died with an EMPTY
# daycare_error_len(). Aborting keeps linear memory intact, and the page reads
# daycare_stage_ptr/len afterwards to report what the runtime was doing.
switch(
  "passL",
  (&"""
  -o {distDir / "daycare_replay.js"}
  --preload-file {rootDir / "data"}@data
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_daycare_load_replay,_daycare_frame,_daycare_input,_daycare_packet_ptr,_daycare_packet_len,_daycare_error_ptr,_daycare_error_len,_daycare_stage_ptr,_daycare_stage_len
  """).replace("\n", " ")
)
