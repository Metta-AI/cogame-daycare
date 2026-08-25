'use strict';

// broadcast_core.js is shared with the native Window client and its vendored
// Snappy module publishes through `window`. A classic Worker can provide that
// alias without introducing a second implementation or bundle step.
self.window = self;

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._daycare_stage_len ? Module._daycare_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._daycare_stage_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._daycare_error_len();
  if (!length) {
    var stage = stageNote();
    return stage
      ? 'Replay runtime failed while: ' + stage
      : 'Replay runtime rejected the replay';
  }
  var pointer = Module._daycare_error_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function ingestPacket() {
  var length = Module._daycare_packet_len();
  if (!length) throw new Error('Replay runtime produced an empty frame');
  var pointer = Module._daycare_packet_ptr();
  // BroadcastCore parses synchronously and copies any retained compressed
  // sprite bytes, so it can read the WASM heap view directly. This avoids a
  // full packet allocation/copy on every replay frame.
  core.ingest(Module.HEAPU8.subarray(pointer, pointer + length));
}

function sendRuntimeInput(bytes) {
  if (!runtimeLoaded) return;
  copyIntoRuntime(bytes, function (pointer, length) {
    Module._daycare_input(pointer, length);
  });
}

function createBroadcastCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    websocket: false,
    playoutBuffer: false,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) {
      postMessage({ type: 'text', text: text });
    },
    onStatus: function (status) {
      postMessage({ type: 'status', status: status });
    },
    onFirstFrame: function () {
      postMessage({ type: 'firstFrame' });
    },
    onTransform: function (transform) {
      postMessage({ type: 'transform', transform: transform });
    },
    onSendPacket: sendRuntimeInput
  });
  if (minimapSurface) core.attachMinimap(minimapSurface);
  core.start();
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    createBroadcastCore(message);
    var response = await fetch(message.replayUrl, {
      credentials: 'omit',
      mode: 'cors'
    });
    if (!response.ok) {
      throw new Error('Replay request returned HTTP ' + response.status);
    }
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._daycare_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    runtimeLoaded = true;
    ingestPacket();
    // No mismatchTick: Daycare records STATE, so there is no re-simulation to
    // mismatch and ctf_mismatch_tick is dropped from the export list.
    postMessage({ type: 'loaded' });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(6, Number(frames) || 1));
    for (var i = 0; i < count; i++) {
      if (Module._daycare_frame() < 0) throw new Error(runtimeError());
      ingestPacket();
    }
    postMessage({
      type: 'advanced',
      // Presentation stat for the page (the core draws over here, a thread
      // away): total frames blitted, so the page can read draws-per-second.
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') — wasm32 is limited to 2 GB' +
    (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  start();
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'command' && core) {
      core.sendCommand(message.text || '');
    } else if (message.type === 'click' && core) {
      core.clickMap(Number(message.x) || 0, Number(message.y) || 0);
    } else if (message.type === 'input' && runtimeLoaded) {
      sendRuntimeInput(new Uint8Array(message.bytes));
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'view' && core) {
      // The canvas is an OffscreenCanvas here, so wheel/drag land on the main
      // thread's placeholder element and arrive as view commands. The core's
      // transform (and the transform echoed back for click mapping) stays the
      // single source of truth either way.
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level, message.x, message.y);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      // The board pixels live here, so the minimap is drawn here too. The page
      // transferred its canvas across; hold it until the core exists.
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './daycare_replay.js');
