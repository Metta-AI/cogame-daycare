// broadcast_core.js — Bitworld sprite protocol v1 client core
// Dependency-free IIFE module for inlining into standalone HTML

(function() {
  'use strict';

  // The native replay client runs this core in a Window. The static bundle
  // runs the same parser/compositor in a Dedicated Worker with an
  // OffscreenCanvas. Keep one implementation so protocol and rendering fixes
  // cannot drift between the two delivery modes.
  const globalScope = typeof window !== 'undefined' ? window : self;
  const requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : callback => setTimeout(() => callback(performance.now()), 1000 / 60);
  const cancelFrame = typeof globalScope.cancelAnimationFrame === 'function'
    ? globalScope.cancelAnimationFrame.bind(globalScope)
    : clearTimeout;
  // Motion interpolation needs a display-cadence callback. Every engine this
  // viewer supports has real requestAnimationFrame in Windows AND dedicated
  // workers (Chromium 69+, Firefox 97+, Safari 15.4+); anywhere it is
  // genuinely missing the setTimeout shim above still draws, but motion
  // falls back to snapping at packet cadence instead of pretending a timer
  // is a vsync.
  const hasNativeRaf = typeof globalScope.requestAnimationFrame === 'function';

  function createCanvasSurface() {
    if (typeof document !== 'undefined') return document.createElement('canvas');
    if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(1, 1);
    throw new Error('Canvas rendering is unavailable in this execution context');
  }

  // ========== Vendored SnappyJS (MIT) ==========
  // @license MIT (http://opensource.org/licenses/MIT)
  // author: Zhipeng Jia
  // version: 0.7.0
  (function(r,e,n){function t(i,f){if(!e[i]){if(!r[i]){var c="function"==typeof require&&require;if(!f&&c)return c(i,!0);if(o)return o(i,!0);var a=new Error("Cannot find module '"+i+"'");throw a.code="MODULE_NOT_FOUND",a}var p=e[i]={exports:{}};r[i][0].call(p.exports,function(e){var n=r[i][1][e];return t(n||e)},p,p.exports,r,e,n)}return e[i].exports}for(var o="function"==typeof require&&require,i=0;i<n.length;i++)t(n[i]);return t})({1:[function(require,module,exports){var SnappyJS={};SnappyJS.uncompress=require("./index").uncompress,SnappyJS.compress=require("./index").compress,window.SnappyJS=SnappyJS;},{"./index":2}],2:[function(require,module,exports){"use strict";function isNode(){return"object"==typeof process&&"object"==typeof process.versions&&void 0!==process.versions.node}function isUint8Array(r){return r instanceof Uint8Array&&(!isNode()||!Buffer.isBuffer(r))}function isArrayBuffer(r){return r instanceof ArrayBuffer}function isBuffer(r){return!!isNode()&&Buffer.isBuffer(r)}var SnappyDecompressor=require("./snappy_decompressor").SnappyDecompressor,SnappyCompressor=require("./snappy_compressor").SnappyCompressor,TYPE_ERROR_MSG="Argument compressed must be type of ArrayBuffer, Buffer, or Uint8Array";function uncompress(r,e){if(!isUint8Array(r)&&!isArrayBuffer(r)&&!isBuffer(r))throw new TypeError(TYPE_ERROR_MSG);var s=!1,n=!1;isUint8Array(r)?s=!0:isArrayBuffer(r)&&(n=!0,r=new Uint8Array(r));var o,f,i=new SnappyDecompressor(r),t=i.readUncompressedLength();if(-1===t)throw new Error("Invalid Snappy bitstream");if(t>e)throw new Error("The uncompressed length of "+t+" is too big, expect at most "+e);if(s){if(o=new Uint8Array(t),!i.uncompressToBuffer(o))throw new Error("Invalid Snappy bitstream")}else if(n){if(o=new ArrayBuffer(t),f=new Uint8Array(o),!i.uncompressToBuffer(f))throw new Error("Invalid Snappy bitstream")}else if(o=Buffer.alloc(t),!i.uncompressToBuffer(o))throw new Error("Invalid Snappy bitstream");return o}function compress(r){if(!isUint8Array(r)&&!isArrayBuffer(r)&&!isBuffer(r))throw new TypeError(TYPE_ERROR_MSG);var e=!1,s=!1;isUint8Array(r)?e=!0:isArrayBuffer(r)&&(s=!0,r=new Uint8Array(r));var n,o,f,i=new SnappyCompressor(r),t=i.maxCompressedLength();if(e?(n=new Uint8Array(t),f=i.compressToBuffer(n)):s?(n=new ArrayBuffer(t),o=new Uint8Array(n),f=i.compressToBuffer(o)):(n=Buffer.alloc(t),f=i.compressToBuffer(n)),!n.slice){var p=new Uint8Array(Array.prototype.slice.call(n,0,f));if(e)return p;if(s)return p.buffer;throw new Error("Not implemented")}return n.slice(0,f)}exports.uncompress=uncompress,exports.compress=compress;},{"./snappy_compressor":3,"./snappy_decompressor":4}],3:[function(require,module,exports){"use strict";var BLOCK_LOG=16,BLOCK_SIZE=1<<BLOCK_LOG,MAX_HASH_TABLE_BITS=14,globalHashTables=new Array(MAX_HASH_TABLE_BITS+1);function hashFunc(r,a){return 506832829*r>>>a}function load32(r,a){return r[a]+(r[a+1]<<8)+(r[a+2]<<16)+(r[a+3]<<24)}function equals32(r,a,e){return r[a]===r[e]&&r[a+1]===r[e+1]&&r[a+2]===r[e+2]&&r[a+3]===r[e+3]}function copyBytes(r,a,e,o,n){var t;for(t=0;t<n;t++)e[o+t]=r[a+t]}function emitLiteral(r,a,e,o,n){return e<=60?(o[n]=e-1<<2,n+=1):e<256?(o[n]=240,o[n+1]=e-1,n+=2):(o[n]=244,o[n+1]=e-1&255,o[n+2]=e-1>>>8,n+=3),copyBytes(r,a,o,n,e),n+e}function emitCopyLessThan64(r,a,e,o){return o<12&&e<2048?(r[a]=1+(o-4<<2)+(e>>>8<<5),r[a+1]=255&e,a+2):(r[a]=2+(o-1<<2),r[a+1]=255&e,r[a+2]=e>>>8,a+3)}function emitCopy(r,a,e,o){for(;o>=68;)a=emitCopyLessThan64(r,a,e,64),o-=64;return o>64&&(a=emitCopyLessThan64(r,a,e,60),o-=60),emitCopyLessThan64(r,a,e,o)}function compressFragment(r,a,e,o,n){for(var t=1;1<<t<=e&&t<=MAX_HASH_TABLE_BITS;)t+=1;var s=32-(t-=1);void 0===globalHashTables[t]&&(globalHashTables[t]=new Uint16Array(1<<t));var i,u,p,h,l,f,c,m,y,L,C=a+e,T=a,S=a,_=!0;if(e>=15)for(i=C-15,p=hashFunc(load32(r,a+=1),s);_;){f=32,h=a;do{if(u=p,c=f>>>5,f+=1,h=(a=h)+c,a>i){_=!1;break}p=hashFunc(load32(r,h),s),l=T+globalHashTables[u],globalHashTables[u]=a-T}while(!equals32(r,a,l));if(!_)break;n=emitLiteral(r,S,a-S,o,n);do{for(m=a,y=4;a+y<C&&r[a+y]===r[l+y];)y+=1;if(a+=y,n=emitCopy(o,n,m-l,y),S=a,a>=i){_=!1;break}globalHashTables[hashFunc(load32(r,a-1),s)]=a-1-T,l=T+globalHashTables[L=hashFunc(load32(r,a),s)],globalHashTables[L]=a-T}while(equals32(r,a,l));if(!_)break;p=hashFunc(load32(r,a+=1),s)}return S<C&&(n=emitLiteral(r,S,C-S,o,n)),n}function putVarint(r,a,e){do{a[e]=127&r,(r>>>=7)>0&&(a[e]+=128),e+=1}while(r>0);return e}function SnappyCompressor(r){this.array=r}SnappyCompressor.prototype.maxCompressedLength=function(){var r=this.array.length;return 32+r+Math.floor(r/6)},SnappyCompressor.prototype.compressToBuffer=function(r){var a,e=this.array,o=e.length,n=0,t=0;for(t=putVarint(o,r,t);n<o;)t=compressFragment(e,n,a=Math.min(o-n,BLOCK_SIZE),r,t),n+=a;return t},exports.SnappyCompressor=SnappyCompressor;},{}],4:[function(require,module,exports){"use strict";var WORD_MASK=[0,255,65535,16777215,4294967295];function copyBytes(r,e,s,t,o){var p;for(p=0;p<o;p++)s[t+p]=r[e+p]}function selfCopyBytes(r,e,s,t){var o;for(o=0;o<t;o++)r[e+o]=r[e-s+o]}function SnappyDecompressor(r){this.array=r,this.pos=0}SnappyDecompressor.prototype.readUncompressedLength=function(){for(var r,e,s=0,t=0;t<32&&this.pos<this.array.length;){if(r=this.array[this.pos],this.pos+=1,(e=127&r)<<t>>>t!==e)return-1;if(s|=e<<t,r<128)return s;t+=7}return-1},SnappyDecompressor.prototype.uncompressToBuffer=function(r){for(var e,s,t,o,p=this.array,n=p.length,i=this.pos,a=0;i<p.length;)if(e=p[i],i+=1,0==(3&e)){if((s=1+(e>>>2))>60){if(i+3>=n)return!1;t=s-60,s=1+((s=p[i]+(p[i+1]<<8)+(p[i+2]<<16)+(p[i+3]<<24))&WORD_MASK[t]),i+=t}if(i+s>n)return!1;copyBytes(p,i,r,a,s),i+=s,a+=s}else{switch(3&e){case 1:s=4+(e>>>2&7),o=p[i]+(e>>>5<<8),i+=1;break;case 2:if(i+1>=n)return!1;s=1+(e>>>2),o=p[i]+(p[i+1]<<8),i+=2;break;case 3:if(i+3>=n)return!1;s=1+(e>>>2),o=p[i]+(p[i+1]<<8)+(p[i+2]<<16)+(p[i+3]<<24),i+=4}if(0===o||o>a)return!1;selfCopyBytes(r,a,o,s),a+=s}return!0},exports.SnappyDecompressor=SnappyDecompressor;},{}]},{},[1]);
  // ========== End vendored SnappyJS ==========

  const textDecoder = new TextDecoder('utf-8');

  const ZoomableFlag = 1;
  const MapLayerType = 0;
  // Reserved sprite id whose LABEL carries the broadcast chrome JSON on the
  // binary channel (see server: BroadcastChromeSpriteId). Kept off the drawable
  // sprite map and fed straight to onText.
  // Engine-authoritative when the wire-constants block was spliced ahead of
  // this script; the literal is the raw-file fallback.
  const CHROME_SPRITE_ID =
    (window.CTF_WIRE && window.CTF_WIRE.chromeSpriteId) || 4090;

  function readU16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  function readU32(bytes, offset) {
    return (bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] * 0x1000000)) >>> 0;
  }

  function readI16(bytes, offset) {
    const value = readU16(bytes, offset);
    return value & 0x8000 ? value - 0x10000 : value;
  }

  function writeI16(bytes, offset, value) {
    value = Math.max(-32768, Math.min(32767, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function writeU16(bytes, offset, value) {
    value = Math.max(0, Math.min(65535, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function decodeSpritePixelsSnappy(compressed, width, height) {
    if (!window.SnappyJS) {
      throw new Error('SnappyJS is not loaded');
    }
    const expected = width * height * 4;
    const pixels = window.SnappyJS.uncompress(compressed, expected);
    const rgba = pixels instanceof Uint8Array ? pixels : new Uint8Array(pixels);
    if (rgba.length !== expected) {
      throw new Error('Bad sprite pixel length');
    }
    return rgba;
  }

  function tryDecodeSpritePixelsSnappy(bytes, offset, remaining, width, height) {
    if (remaining < 6) return null;
    const compressedLength = readU32(bytes, offset);
    if (compressedLength > remaining - 6) return null;
    const labelOffset = offset + 4 + compressedLength;
    const labelLength = readU16(bytes, labelOffset);
    if (labelLength > remaining - 4 - compressedLength - 2) return null;
    const compressed = bytes.slice(offset + 4, labelOffset);
    const labelStart = labelOffset + 2;
    const labelEnd = labelStart + labelLength;
    const label = textDecoder.decode(bytes.slice(labelStart, labelEnd));
    let pixels = null;
    try {
      pixels = decodeSpritePixelsSnappy(compressed, width, height);
    } catch (e) {
      // Structurally this IS a snappy sprite message — only the decode failed
      // (in practice a transient allocation failure on huge boards, where 50+
      // map bands each inflate to multi-MB RGBA). The message length is known
      // from the header, so report it with the compressed payload retained for
      // a later retry. Returning null here would make the caller fall back to
      // the legacy raw advance (width*height), desyncing the parser and
      // silently discarding every later message in this packet — on the map
      // layer that means permanent black stripes, because bands are emitted
      // exactly once per viewer.
      pixels = null;
    }
    return {
      pixels,
      compressed: pixels ? null : compressed,
      label,
      offset: labelEnd
    };
  }

  function ensureLayer(layers, id) {
    if (!layers.has(id)) {
      const canvas = createCanvasSurface();
      const ctx = canvas.getContext('2d');
      ctx.imageSmoothingEnabled = false;
      layers.set(id, {
        id,
        type: MapLayerType,
        flags: ZoomableFlag,
        width: 1,
        height: 1,
        canvas,
        ctx,
        image: null
      });
    }
    return layers.get(id);
  }

  function defineLayer(layers, id, type, flags) {
    const layer = ensureLayer(layers, id);
    layer.type = type;
    layer.flags = flags;
  }

  function setViewport(layers, layerId, width, height, onResize) {
    const layer = ensureLayer(layers, layerId);
    layer.width = width;
    layer.height = height;
    layer.canvas.width = width;
    layer.canvas.height = height;
    layer.image = layer.ctx.createImageData(width, height);
    if (onResize) onResize();
  }

  function putSpritePixel(layer, x, y, sprite, srcOffset) {
    if (x < 0 || y < 0 || x >= layer.width || y >= layer.height) return;
    const srcA = sprite.pixels[srcOffset + 3];
    if (srcA === 0) return;
    const offset = (y * layer.width + x) * 4;
    if (srcA === 255 || layer.image.data[offset + 3] === 0) {
      layer.image.data[offset] = sprite.pixels[srcOffset];
      layer.image.data[offset + 1] = sprite.pixels[srcOffset + 1];
      layer.image.data[offset + 2] = sprite.pixels[srcOffset + 2];
      layer.image.data[offset + 3] = srcA;
      return;
    }
    const dstA = layer.image.data[offset + 3];
    const srcAlpha = srcA / 255, dstAlpha = dstA / 255;
    const outAlpha = srcAlpha + dstAlpha * (1 - srcAlpha);
    const dstWeight = dstAlpha * (1 - srcAlpha);
    layer.image.data[offset] = Math.round(
      (sprite.pixels[srcOffset] * srcAlpha +
        layer.image.data[offset] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 1] = Math.round(
      (sprite.pixels[srcOffset + 1] * srcAlpha +
        layer.image.data[offset + 1] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 2] = Math.round(
      (sprite.pixels[srcOffset + 2] * srcAlpha +
        layer.image.data[offset + 2] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 3] = Math.round(outAlpha * 255);
  }

  function websocketPathForClientPage(path) {
    // This core is only ever loaded by the replay pages; the other client
    // routes use bitworld's generic client with its own socket wiring.
    const mappings = [
      ['/client/replay', '/replay'],
      ['/clients/replay', '/replay']
    ];
    for (const [clientPath, websocketPath] of mappings) {
      if (path === clientPath) {
        return websocketPath;
      }
      if (path.endsWith(clientPath)) {
        return path.slice(0, path.length - clientPath.length) + websocketPath;
      }
    }
    return path;
  }

  function websocketAddress(pageUrl) {
    const url = new URL(pageUrl);
    const protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    const host = url.host || 'localhost:8080';
    const wsPath = websocketPathForClientPage(url.pathname);
    const wsUrl = new URL(protocol + '//' + host + wsPath);
    // Only `uri` means anything on a viewer socket; player-credential params
    // (name/slot/token) make the server 403 the viewer connection.
    const value = url.searchParams.get('uri');
    if (value !== null) {
      wsUrl.searchParams.set('uri', value);
    }
    return wsUrl.toString();
  }

  function BroadcastCore(config) {
    const canvas = config.canvas;
    const onText = config.onText || (() => {});
    const onStatus = config.onStatus || (() => {});
    const onFirstFrame = config.onFirstFrame || (() => {});
    const websocketEnabled = config.websocket !== false;
    const onSendPacket = config.onSendPacket || null;
    const onTransform = config.onTransform || (() => {});
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    const layers = new Map();
    const sprites = new Map();
    const objects = new Map();

    let socket = null;
    let rafHandle = null;
    let dirty = false;
    let firstFrameFired = false;
    let offscreenCanvas = null;
    let offscreenCtx = null;
    let nativeW = 1, nativeH = 1;
    let lastBoardW = 0, lastBoardH = 0;  // last REAL board size; see updateNativeSize
    let scale = 1, offsetX = 0, offsetY = 0;
    let fitScale = 1;                 // scale that fits the whole board (zoom 1).
    let zoom = 1;                     // multiplier over the fit, >= 1.
    let focusX = 0, focusY = 0;       // map px held at the viewport center.
    const minZoom = 1;                // 1 IS "fitted whole": the board can never
                                      // be smaller than the frame it lives in.
    const maxZoom = 12;               // ~1 map px per 12 css px: past this the
                                      // art is blocks, not detail.
    let reconnectDelay = 1000;
    const maxReconnectDelay = 8000;
    let reconnecting = false;
    let stopped = false;
    let viewportWidth = Number(config.viewportWidth) || 0;
    let viewportHeight = Number(config.viewportHeight) || 0;
    let pixelRatio = Number(config.devicePixelRatio) ||
      globalScope.devicePixelRatio || 1;
    let lastTransform = null;

    // ---- Motion interpolation ----
    // The sim advances 24 discrete states per second (ReplayFps / TargetFps
    // in src/ctf/sim.nim) and a packet is one such state. Drawn as-is that
    // is a 41ms motion staircase on a 60/120Hz display, so every object
    // carries a DISPLAY position (dispX/dispY) that glides from wherever it
    // was last drawn to the packet's position over one packet interval, and
    // frameTick keeps rAF-drawing while any glide is in flight. The loop
    // arms only on real motion and dies when every glide lands: a paused or
    // end-held replay draws nothing.
    //
    // Only id-stable objects glide; a new object, a layer change, or a jump
    // past SNAP_DISTANCE (respawn, teleport, scrub) snaps — gliding those
    // would invent motion the sim never had. Glide positions round to whole
    // board pixels (the compositor is integer blitting and the board draws
    // nearest-neighbor, so sub-pixel positions do not exist in this
    // pipeline); at display cadence that still turns a 3-6px tick jump into
    // steps of a pixel or two.
    const interpEnabled = hasNativeRaf;
    // Wire positions are supersampled map px (boardRenderScale×, 2× on
    // standard boards): 48 is two agent cells (SpriteSize = 12 map px).
    // Legit per-tick motion tops out near 6 wire px (MaxSpeed 704/256 map
    // px/tick at 2×); respawns and teleports jump hundreds.
    const SNAP_DISTANCE = 48;
    const movingObjects = new Set();
    let packetInterval = 1000 / 24;   // learned from motion-packet spacing
    let lastMotionAt = 0;
    let pendingDecodes = 0;           // sprites awaiting a decode retry
    let drawCount = 0;

    // ---- Playout buffer (jitter absorption) ----
    // The stream leaves the server at a clean source cadence (~24fps), but the
    // delivery chain (container → kube proxy → backend → nginx) is bursty:
    // gaps >100ms followed by catch-up bursts. Drawing on arrival turns that
    // into freeze-then-jump. Instead, queue incoming messages and present them
    // on a fixed cadence inferred from the arrival rate, cushioned by a couple
    // of frame intervals. Messages are stateful deltas (sprite defs, object
    // moves), so backlog control must fast-forward — apply everything, draw
    // once — never discard, or sprite/object state corrupts.
    const paceEnabled = config.playoutBuffer !== false;
    const onFrame = config.onFrame || null;
    // 12 frames ≈ 500ms at 24fps: replay playback has no latency budget, so a
    // deep cushion that rides out measured WAN delivery stalls (p99 ≈ 400-500ms
    // against production, July 2026) beats the responsiveness a live viewer
    // would want. Live surfaces pass their own paceTargetDepth.
    const PACE_TARGET_DEPTH = config.paceTargetDepth || 12;
    const PACE_MAX_DEPTH = PACE_TARGET_DEPTH + 7;
    const PACE_HARD_QUEUE = 240;
    const PACE_MIN_INTERVAL = 1000 / 60;
    const PACE_MAX_INTERVAL = 1000 / 10;
    const PACE_WINDOW = 48;
    const PACE_PRIME_TIMEOUT = 300;
    let paceQueue = [];
    let paceBinaryCount = 0;
    let paceArrivals = [];
    let paceInterval = 1000 / 24;
    let paceNextDue = 0;
    let pacePrimed = false;
    let paceFirstArrival = 0;
    let pacePresented = 0;
    let paceRaf = null;
    let paceTimer = null;

    function mapLayer() {
      for (const layer of layers.values()) {
        if ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType) {
          return layer;
        }
      }
      return null;
    }

    function computeNativeSize() {
      let maxW = 1, maxH = 1;
      for (const layer of layers.values()) {
        if ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType) {
          maxW = Math.max(maxW, layer.width);
          maxH = Math.max(maxH, layer.height);
        }
      }
      return { w: maxW, h: maxH };
    }

    function updateNativeSize() {
      const size = computeNativeSize();
      // A new board ALWAYS opens fitted. You see the whole map first and then
      // choose where to go in — never dropped into the corner of a board you
      // have not seen yet. Zoom and focus from the previous board mean nothing
      // on this one anyway (a 4992px colossal map and the 1235px arena share no
      // coordinates), so this also keeps a mid-replay board change from landing
      // the view in the void.
      //
      // "New" is measured against the last REAL board, not against the current
      // nativeW/H. A replay that loops or seeks re-emits its layers, and for a
      // frame or two computeNativeSize answers the 1x1 placeholder; comparing
      // frame-to-frame would read that blink as two board changes and refit the
      // view out from under someone who is mid-inspection on the SAME map.
      if (size.w > 1 && size.h > 1 &&
          (size.w !== lastBoardW || size.h !== lastBoardH)) {
        lastBoardW = size.w;
        lastBoardH = size.h;
        zoom = minZoom;
        focusX = size.w / 2;
        focusY = size.h / 2;
      }
      nativeW = size.w;
      nativeH = size.h;
      if (!offscreenCanvas) {
        offscreenCanvas = createCanvasSurface();
        offscreenCtx = offscreenCanvas.getContext('2d');
        offscreenCtx.imageSmoothingEnabled = false;
      }
      if (offscreenCanvas.width !== nativeW) offscreenCanvas.width = nativeW;
      if (offscreenCanvas.height !== nativeH) offscreenCanvas.height = nativeH;
    }

    function canvasCssSize() {
      return {
        w: viewportWidth || canvas.clientWidth || canvas.width / pixelRatio,
        h: viewportHeight || canvas.clientHeight || canvas.height / pixelRatio
      };
    }

    // Everything a view control needs, in ONE object. The page never reaches
    // into the core for view state: it reads this (getTransform, or the
    // onTransform push — the static bundle's core lives in a Worker and can
    // only answer with a message, so a synchronous getter would have to lie).
    // visW/visH are the map-space span actually on screen, which is what the
    // minimap's view box and the arrow-key pan step are both sized from.
    function viewSnapshot() {
      const size = canvasCssSize();
      return {
        scale, offsetX, offsetY, nativeW, nativeH,
        zoom, minZoom, maxZoom, fitScale, focusX, focusY,
        visW: Math.min(nativeW, size.w / scale),
        visH: Math.min(nativeH, size.h / scale)
      };
    }

    function notifyTransform() {
      // Same shape as getTransform(), which is what #245 established: the
      // Worker mirrors this payload to the page, and a payload missing `zoom`
      // left the static viewer unable to answer "am I zoomed?". It now carries
      // the whole view, because the controls need the bounds and the focus too.
      const next = viewSnapshot();
      if (!lastTransform ||
          next.scale !== lastTransform.scale ||
          next.offsetX !== lastTransform.offsetX ||
          next.offsetY !== lastTransform.offsetY ||
          next.nativeW !== lastTransform.nativeW ||
          next.nativeH !== lastTransform.nativeH ||
          next.zoom !== lastTransform.zoom ||
          next.focusX !== lastTransform.focusX ||
          next.focusY !== lastTransform.focusY) {
        lastTransform = next;
        onTransform(next);
      }
    }

    // View zoom. `zoom` multiplies the fit scale and `focusX/focusY` name the
    // MAP-space point held at the viewport center, so the view survives every
    // relayout: a container resize, a hudscale swing, or a mid-replay board
    // change (a generated map can be 960x960 where the arena is 1235x659)
    // recomputes the fit and keeps looking at the same part of the board.
    // Zoom exists because a big map is unreadable letterboxed whole: a 4992px
    // colossal board fits a ~760px stage at 0.15x, where a cog is one pixel.
    function clampView() {
      zoom = Math.min(maxZoom, Math.max(minZoom, zoom));
      const size = canvasCssSize();
      // Half the viewport, in map px. At zoom 1 this covers the whole board on
      // the fitted axis, so the focus pins to the center and the letterbox
      // bands stay symmetric exactly as before.
      const halfW = size.w / (fitScale * zoom) / 2;
      const halfH = size.h / (fitScale * zoom) / 2;
      // Never pan past the edges: if the viewport is wider than the board, the
      // board stays centered on that axis instead of drifting into the void.
      focusX = halfW * 2 >= nativeW ?
        nativeW / 2 : Math.min(nativeW - halfW, Math.max(halfW, focusX));
      focusY = halfH * 2 >= nativeH ?
        nativeH / 2 : Math.min(nativeH - halfH, Math.max(halfH, focusY));
    }

    function computeFit() {
      const size = canvasCssSize();
      const cssW = size.w;
      const cssH = size.h;
      const scaleX = cssW / nativeW;
      const scaleY = cssH / nativeH;
      fitScale = Math.min(scaleX, scaleY);
      if (!(focusX > 0) || !(focusY > 0)) {
        focusX = nativeW / 2;
        focusY = nativeH / 2;
      }
      clampView();
      scale = fitScale * zoom;
      // Place the focus point at the viewport center. At zoom 1 this reduces to
      // the old centered letterbox, to the pixel.
      offsetX = cssW / 2 - focusX * scale;
      offsetY = cssH / 2 - focusY * scale;
      notifyTransform();
    }

    function zoomAt(factor, cssX, cssY) {
      // Zoom toward a point (the cursor, usually): hold the map pixel under it
      // still, so the board grows out from what you are looking at rather than
      // from the center.
      if (!(factor > 0)) return;
      const size = canvasCssSize();
      const anchorX = typeof cssX === 'number' ? cssX : size.w / 2;
      const anchorY = typeof cssY === 'number' ? cssY : size.h / 2;
      const mapX = (anchorX - offsetX) / scale;
      const mapY = (anchorY - offsetY) / scale;
      const before = zoom;
      zoom = Math.min(maxZoom, Math.max(minZoom, zoom * factor));
      if (zoom === before) return;
      // Shift the focus so (mapX, mapY) lands back under the anchor.
      const nextScale = fitScale * zoom;
      focusX = mapX + (size.w / 2 - anchorX) / nextScale;
      focusY = mapY + (size.h / 2 - anchorY) / nextScale;
      computeFit();
      scheduleDraw();
    }

    // Absolute zoom, for the slider and the +/- buttons. Zoom is a GEOMETRIC
    // quantity (1x -> 12x), so a control that wants a linear feel maps its own
    // travel through a log; the core only ever takes a level.
    function setZoom(level, cssX, cssY) {
      if (!(level > 0)) return;
      const target = Math.min(maxZoom, Math.max(minZoom, level));
      if (target === zoom) return;
      zoomAt(target / zoom, cssX, cssY);
    }

    function panBy(cssDX, cssDY) {
      if (zoom <= minZoom) return;    // fitted whole: there is nowhere to pan.
      focusX -= cssDX / scale;
      focusY -= cssDY / scale;
      computeFit();
      scheduleDraw();
    }

    // Pan by a MAP-space delta (the arrow keys, which step by a share of what
    // is on screen rather than by screen pixels — a nudge means the same thing
    // at 2x and at 12x).
    function panByMap(mapDX, mapDY) {
      if (zoom <= minZoom) return;
      focusX += mapDX;
      focusY += mapDY;
      computeFit();
      scheduleDraw();
    }

    // Put a map point at the viewport center (clicking or dragging the minimap).
    function panTo(mapX, mapY) {
      if (!(mapX >= 0) || !(mapY >= 0)) return;
      focusX = mapX;
      focusY = mapY;
      computeFit();
      scheduleDraw();
    }

    function resetView() {
      zoom = minZoom;
      focusX = nativeW / 2;
      focusY = nativeH / 2;
      computeFit();
      scheduleDraw();
    }

    // ---- Minimap ----------------------------------------------------------
    // The core draws it, not the page, for the same reason the transform lives
    // here: the static bundle composites inside a Worker, so the page has no
    // board pixels to shrink and no view state to outline. The page hands over
    // a surface (a canvas, or an OffscreenCanvas transferred to the Worker) and
    // the core keeps it in sync with what it just drew.
    let minimapSurface = null;
    let minimapCtx = null;
    let minimapDrawnAt = 0;
    let minimapDrawnZoom = 0, minimapDrawnX = -1, minimapDrawnY = -1;
    const MinimapSpanPx = 240;        // backing-store cap on the long edge
    const MinimapMinBoxPx = 14;       // floor on the view box, so deep zoom on a
                                      // colossal board still shows you WHERE

    function attachMinimap(surface) {
      minimapSurface = surface || null;
      minimapCtx = minimapSurface ? minimapSurface.getContext('2d') : null;
      drawMinimap();
    }

    function drawMinimap() {
      if (!minimapCtx || !offscreenCanvas || nativeW < 1 || nativeH < 1) return;
      // Shrinking a 4992x4992 board into 240px is a ~25M-pixel resample. Two
      // rules keep it off the frame budget: never pay it while the minimap is
      // hidden (fitted board — the common case), and once it IS up, refresh the
      // board picture at ~12fps rather than the board's 24. A view change still
      // redraws immediately, because THAT is the frame the eye is waiting on.
      if (zoom <= minZoom) { minimapDrawnAt = 0; return; }
      const now = performance.now();
      const moved = zoom !== minimapDrawnZoom ||
        focusX !== minimapDrawnX || focusY !== minimapDrawnY;
      if (!moved && now - minimapDrawnAt < 80) return;
      minimapDrawnAt = now;
      minimapDrawnZoom = zoom;
      minimapDrawnX = focusX;
      minimapDrawnY = focusY;
      // The backing store carries the BOARD's aspect, so the view box stays a
      // true rectangle no matter what shape the CSS box ends up.
      const k = MinimapSpanPx / Math.max(nativeW, nativeH);
      const w = Math.max(1, Math.round(nativeW * k));
      const h = Math.max(1, Math.round(nativeH * k));
      if (minimapSurface.width !== w) minimapSurface.width = w;
      if (minimapSurface.height !== h) minimapSurface.height = h;
      // Resizing a canvas resets its context state, so this must follow.
      minimapCtx.imageSmoothingEnabled = true;
      minimapCtx.clearRect(0, 0, w, h);
      minimapCtx.drawImage(offscreenCanvas, 0, 0, w, h);

      const size = canvasCssSize();
      const visW = Math.min(nativeW, size.w / scale);
      const visH = Math.min(nativeH, size.h / scale);
      // A 4992px board at 12x holds ~1/40th of its width, which is 6 minimap
      // pixels: below a floor the box stops being a shape you can find. Grow it
      // around the same center instead of letting it vanish.
      const bw = Math.max(MinimapMinBoxPx, visW * (w / nativeW));
      const bh = Math.max(MinimapMinBoxPx, visH * (h / nativeH));
      const bx = Math.min(w - bw, Math.max(0, focusX * (w / nativeW) - bw / 2));
      const by = Math.min(h - bh, Math.max(0, focusY * (h / nativeH) - bh / 2));
      // Everything OUTSIDE the box goes down a stop. That is what makes it read
      // as a window rather than a drawn rectangle — the eye finds the bright
      // patch before it finds the outline.
      minimapCtx.fillStyle = 'rgba(10, 7, 4, 0.5)';
      minimapCtx.fillRect(0, 0, w, Math.max(0, by));
      minimapCtx.fillRect(0, by + bh, w, Math.max(0, h - by - bh));
      minimapCtx.fillRect(0, by, Math.max(0, bx), bh);
      minimapCtx.fillRect(bx + bw, by, Math.max(0, w - bx - bw), bh);
      // White box over a dark halo: the board under it can be pale concrete or
      // near-black pit, and a bare white line disappears into the first. The
      // strokes are deliberately heavy for a 240px surface — this canvas is
      // displayed SMALLER than its backing store, so a hairline would be
      // resampled away to nothing.
      minimapCtx.lineJoin = 'miter';
      minimapCtx.strokeStyle = 'rgba(8, 5, 3, 0.9)';
      minimapCtx.lineWidth = 5;
      minimapCtx.strokeRect(bx + 1, by + 1, Math.max(2, bw - 2), Math.max(2, bh - 2));
      minimapCtx.strokeStyle = '#ffffff';
      minimapCtx.lineWidth = 2.5;
      minimapCtx.strokeRect(bx + 1, by + 1, Math.max(2, bw - 2), Math.max(2, bh - 2));
    }

    // Static map-band cache. The full-board map bands (object ids 40 up, on
    // layer 0, z pinned at -32768 so they underlie everything) are emitted
    // once at init and never change, yet re-blitting them dominates composite
    // cost at full board size. Bake them ONCE into a per-layer base canvas
    // (per-pixel, via layer.image — bit-exact with the old software path) and
    // start each composite by drawImage-ing that base, drawing only the
    // dynamic objects above it (the endzone fade overlay at z = -32767 DOES
    // change every frame and must stay dynamic).
    //
    // Dynamic objects composite via canvas drawImage of small per-sprite
    // surfaces, NOT the per-pixel software blend the bake uses: a software
    // composite costs tens of ms per frame at full board size, which capped
    // presentation below the packet rate — the motion-interpolation draw
    // loop needs composites at display cadence, and canvas source-over is
    // the same blend putSpritePixel implements.
    //
    // The window matches the server's MapBandObjectBase pool: 40..40+bands.
    // 99 covers 60 bands — enough for every generated size class (a 4-team
    // giant is 52 bands); the next server object pool starts well above.
    // The old cap of 67 (28 bands) predated the oversize map classes: any
    // band past it broke the sorted-prefix rule below and silently disabled
    // the cache for the whole board, turning every frame into a ~100 MB
    // full re-blit on exactly the maps that could least afford it.
    const STATIC_BAND_MIN_ID = 40;
    const STATIC_BAND_MAX_ID = 99;
    const STATIC_BAND_Z = -32768;
    let staticBandsDirty = true;

    function isStaticBand(obj) {
      return obj.layer === 0 &&
        obj.id >= STATIC_BAND_MIN_ID && obj.id <= STATIC_BAND_MAX_ID &&
        obj.z === STATIC_BAND_Z;
    }

    // A sprite whose snappy payload failed to decode on arrival (transient
    // allocation failure — see tryDecodeSpritePixelsSnappy) keeps its
    // compressed bytes and is re-tried here, at most once per composite,
    // until it decodes or the budget runs out. This is what makes a dropped
    // map band self-heal instead of leaving a permanent black stripe: bands
    // are sent exactly once, so this retained payload is the only repair
    // path. ~10s at 24fps; a failure that persists that long isn't memory
    // pressure, so stop burning CPU on it.
    const SPRITE_DECODE_RETRY_LIMIT = 240;

    function spriteAwaitsRetry(sprite) {
      return Boolean(sprite && sprite.pendingCompressed) &&
        sprite.decodeRetries < SPRITE_DECODE_RETRY_LIMIT;
    }

    function retrySpriteDecode(sprite) {
      if (!spriteAwaitsRetry(sprite)) return;
      sprite.decodeRetries++;
      try {
        sprite.pixels = decodeSpritePixelsSnappy(
          sprite.pendingCompressed, sprite.width, sprite.height);
        sprite.pendingCompressed = null;
        pendingDecodes--;
        // The recovered sprite may be part of the baked static-band base.
        staticBandsDirty = true;
      } catch (e) {
        // Still failing — try again on a later composite, unless this was
        // the budget's last attempt (then stop forcing composites for it).
        if (!spriteAwaitsRetry(sprite)) pendingDecodes--;
      }
    }

    function blitObject(layer, obj) {
      const sprite = sprites.get(obj.spriteId);
      if (!sprite || !sprite.pixels) return;
      // Objects draw at their DISPLAY position: equal to x/y at rest, mid-
      // glide between packets while interpolating (see updateInterpolation).
      const objX = obj.dispX;
      const objY = obj.dispY;
      const startX = Math.max(0, -objX);
      const startY = Math.max(0, -objY);
      const endX = Math.min(sprite.width, layer.width - objX);
      const endY = Math.min(sprite.height, layer.height - objY);
      if (startX >= endX || startY >= endY) return;
      for (let y = startY; y < endY; y++) {
        for (let x = startX; x < endX; x++) {
          putSpritePixel(
            layer,
            objX + x,
            objY + y,
            sprite,
            (y * sprite.width + x) * 4
          );
        }
      }
    }

    // Small canvas per sprite, built lazily on first draw and dropped on
    // redefinition (0x01 replaces the record). Map-band sprites never build
    // one: the static prefix is baked through the per-pixel path instead.
    function spriteSurface(sprite) {
      if (!sprite.surface) {
        const canvas = createCanvasSurface();
        canvas.width = sprite.width;
        canvas.height = sprite.height;
        const surfaceCtx = canvas.getContext('2d');
        const image = surfaceCtx.createImageData(sprite.width, sprite.height);
        image.data.set(sprite.pixels);
        surfaceCtx.putImageData(image, 0, 0);
        sprite.surface = canvas;
      }
      return sprite.surface;
    }

    function drawObject(targetCtx, obj) {
      const sprite = sprites.get(obj.spriteId);
      if (!sprite || !sprite.pixels) return;
      targetCtx.drawImage(spriteSurface(sprite), obj.dispX, obj.dispY);
    }

    function composite() {
      // Retry pending sprite decodes up front (not inside blitObject): a
      // static band that recovers must dirty the baked base, and a band
      // waiting on retry is exactly the one the clean-base path never
      // re-blits, so it would otherwise never get another attempt.
      for (const sprite of sprites.values()) {
        if (spriteAwaitsRetry(sprite)) retrySpriteDecode(sprite);
      }
      const orderedLayers = [...layers.values()]
        .filter(layer => (layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType)
        .sort((a, b) => a.id - b.id);

      offscreenCtx.clearRect(0, 0, nativeW, nativeH);

      for (const layer of orderedLayers) {
        if (!layer.image) continue;
        const ordered = [...objects.values()]
          .filter(obj => obj.layer === layer.id)
          // Depth ties break on the DISPLAY y, so two agents crossing swap
          // paint order where they visibly cross, not a fraction of a tick
          // early. Static bands glide never, so the cached prefix is stable.
          .sort((a, b) => a.z - b.z || a.dispY - b.dispY || a.id - b.id);
        if (ordered.length === 0) continue;
        // The cache is only sound if the static bands form the sorted prefix
        // and every dynamic object sorts strictly after them (i.e. nothing
        // dynamic shares z = -32768). Otherwise fall back to a full re-blit.
        let staticCount = 0;
        while (staticCount < ordered.length && isStaticBand(ordered[staticCount])) {
          staticCount++;
        }
        let cacheable = staticCount > 0;
        for (let i = staticCount; cacheable && i < ordered.length; i++) {
          if (ordered[i].z <= STATIC_BAND_Z) cacheable = false;
        }
        layer.ctx.clearRect(0, 0, layer.width, layer.height);
        if (cacheable) {
          if (staticBandsDirty || !layer.baseCanvas ||
              layer.baseCanvas.width !== layer.width ||
              layer.baseCanvas.height !== layer.height) {
            layer.image.data.fill(0);
            for (let i = 0; i < staticCount; i++) blitObject(layer, ordered[i]);
            if (!layer.baseCanvas) {
              layer.baseCanvas = createCanvasSurface();
              layer.baseCtx = layer.baseCanvas.getContext('2d');
            }
            layer.baseCanvas.width = layer.width;
            layer.baseCanvas.height = layer.height;
            layer.baseCtx.putImageData(layer.image, 0, 0);
          }
          layer.ctx.drawImage(layer.baseCanvas, 0, 0);
          for (let i = staticCount; i < ordered.length; i++) {
            drawObject(layer.ctx, ordered[i]);
          }
        } else {
          layer.baseCanvas = null;
          layer.baseCtx = null;
          for (const obj of ordered) drawObject(layer.ctx, obj);
        }
        offscreenCtx.drawImage(layer.canvas, 0, 0);
      }
      staticBandsDirty = false;
      dirty = false;
    }

    function draw() {
      const dpr = pixelRatio;
      const size = canvasCssSize();
      const cssW = size.w;
      const cssH = size.h;
      if (canvas.width !== cssW * dpr) canvas.width = cssW * dpr;
      if (canvas.height !== cssH * dpr) canvas.height = cssH * dpr;

      computeFit();

      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      if (dirty) {
        composite();
      }

      if (offscreenCanvas && nativeW > 0 && nativeH > 0) {
        ctx.save();
        ctx.scale(dpr, dpr);
        ctx.translate(offsetX, offsetY);
        // Nearest-neighbor at ALL scales (matches #board's image-rendering:
        // pixelated). The old code force-enabled smoothing whenever the board
        // had to shrink (scale < 1, e.g. small windows or side panels eating
        // width), which softened the ENTIRE board — floor, cracks, sprites —
        // into a uniform blur. Retro pixel art wants crisp pixels, never a
        // bilinear wash, so keep smoothing off in every regime.
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(offscreenCanvas, 0, 0, nativeW * scale, nativeH * scale);
        ctx.restore();
      }

      drawMinimap();
      drawCount++;
    }

    // Advance every in-flight glide to `now`. Returns whether any glide is
    // still in flight (i.e. the draw loop must keep running); sets `dirty`
    // only when some object's integer display position actually changed, so
    // a 120Hz loop over slow motion skips the composites that would repaint
    // identical pixels.
    function updateInterpolation(now) {
      if (movingObjects.size === 0) return false;
      let animating = false;
      let moved = false;
      for (const obj of movingObjects) {
        // rAF timestamps mark the frame's start and can precede the
        // performance.now() the packet was stamped with — clamp, never
        // extrapolate backwards.
        const t = Math.max(0, (now - obj.moveAt) / packetInterval);
        let nextX, nextY;
        if (t >= 1) {
          nextX = obj.x;
          nextY = obj.y;
          obj.fromX = nextX;
          obj.fromY = nextY;
          obj.moveAt = 0;
          movingObjects.delete(obj);
        } else {
          nextX = Math.round(obj.fromX + (obj.x - obj.fromX) * t);
          nextY = Math.round(obj.fromY + (obj.y - obj.fromY) * t);
          animating = true;
        }
        if (nextX !== obj.dispX || nextY !== obj.dispY) {
          obj.dispX = nextX;
          obj.dispY = nextY;
          moved = true;
        }
      }
      if (moved) dirty = true;
      return animating;
    }

    function frameTick(now) {
      rafHandle = null;
      // While any glide is in flight the draw self-reschedules, turning the
      // one-shot rAF into a display-cadence loop. It dies the moment the
      // board is motionless (pause, end hold, idle scene), so a held frame
      // costs zero draws.
      const animating = updateInterpolation(now);
      draw();
      if (animating && !stopped) scheduleDraw();
    }

    function scheduleDraw() {
      if (rafHandle) return;
      rafHandle = requestFrame(frameTick);
    }

    function parse(bytes) {
      const packetTime = performance.now();
      let offset = 0;
      let changed = false;
      let motionSeen = false;
      while (offset < bytes.length) {
        const type = bytes[offset++];
        if (type === 0x01) {
          const id = readU16(bytes, offset);
          const width = readU16(bytes, offset + 2);
          const height = readU16(bytes, offset + 4);
          offset += 6;
          const remaining = bytes.length - offset;
          const snappySprite = tryDecodeSpritePixelsSnappy(
            bytes,
            offset,
            remaining,
            width,
            height
          );
          if (!snappySprite) {
            // Sprites are always snappy-compressed on the wire; a message
            // whose STRUCTURE doesn't parse is a corrupt frame, and guessing
            // a skip width would silently desync the whole stream. Fail
            // loudly instead. (A structurally-valid message whose DECODE
            // threw comes back with pixels = null plus its retained
            // compressed payload — skipped cleanly below and retried on
            // later composites, so one transient allocation failure can't
            // kill the stream or permanently black out a map band.)
            console.warn('Sprite decompress failed (corrupt frame); closing socket');
            if (socket) socket.close();
            break;
          }
          const pixels = snappySprite.pixels;
          const label = snappySprite.label;
          const pendingCompressed = snappySprite.compressed;
          offset = snappySprite.offset;
          // Broadcast chrome (scorebug/clock/scrubber/roster/events) is smuggled
          // as the label of a reserved 1×1 sprite (id 4090). Route it to onText
          // exactly like the legacy TextMessage chrome channel. This binary path
          // is the ONLY one that survives a hosted replay, where the interactive
          // TextMessage opt-in never routes through the recorded stream. Never
          // register it as a drawable sprite.
          if (id === CHROME_SPRITE_ID) {
            // Chrome paints no board pixels, so it is NOT a change: a paused
            // replay keeps sending chrome (the clock JSON rides every
            // packet), and marking the board dirty for it would re-composite
            // an identical frame per packet forever.
            if (label) onText(label);
          } else {
            if (spriteAwaitsRetry(sprites.get(id))) pendingDecodes--;
            sprites.set(id, {
              width, height, pixels, label, pendingCompressed, decodeRetries: 0
            });
            if (pendingCompressed) pendingDecodes++;
            // A sprite definition repaints the board only when a live object
            // references it: a redefinition of a static-band sprite dirties
            // the baked base, and one under any other visible object dirties
            // the frame. Everything else — chiefly the rig-pose PREFETCH
            // stream, which trickles future pose sprites a few per packet
            // even while paused — defines pixels nothing displays yet, and
            // must not force composites (the object add/retarget that later
            // uses the sprite marks the change).
            for (const obj of objects.values()) {
              if (obj.spriteId !== id) continue;
              changed = true;
              if (isStaticBand(obj)) {
                staticBandsDirty = true;
                break;
              }
            }
          }
        } else if (type === 0x02) {
          const id = readU16(bytes, offset);
          const x = readI16(bytes, offset + 2);
          const y = readI16(bytes, offset + 4);
          const z = readI16(bytes, offset + 6);
          const layer = bytes[offset + 8];
          const spriteId = readU16(bytes, offset + 9);
          offset += 11;
          const obj = objects.get(id);
          if (!obj) {
            objects.set(id, {
              id, x, y, z, layer, spriteId,
              dispX: x, dispY: y, fromX: x, fromY: y, moveAt: 0
            });
            if (id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID) {
              staticBandsDirty = true;
            }
            changed = true;
          } else if (obj.x !== x || obj.y !== y || obj.z !== z ||
              obj.layer !== layer || obj.spriteId !== spriteId) {
            // The server re-describes the board every frame, so an object
            // message is only a CHANGE when some field differs — an
            // identical re-send (every object, every packet, on a paused
            // replay) must not dirty the frame.
            if (obj.x !== x || obj.y !== y) {
              const glide = interpEnabled && obj.layer === layer &&
                Math.abs(x - obj.x) <= SNAP_DISTANCE &&
                Math.abs(y - obj.y) <= SNAP_DISTANCE &&
                !(layer === 0 && z === STATIC_BAND_Z &&
                  id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID);
              if (glide) {
                // Glide FROM the currently drawn position (mid-glide
                // included), so an early or late packet bends the path
                // instead of kinking it.
                obj.fromX = obj.dispX;
                obj.fromY = obj.dispY;
                obj.moveAt = packetTime;
                movingObjects.add(obj);
                motionSeen = true;
              } else {
                obj.dispX = x;
                obj.dispY = y;
                obj.fromX = x;
                obj.fromY = y;
                obj.moveAt = 0;
                movingObjects.delete(obj);
              }
              obj.x = x;
              obj.y = y;
            }
            obj.z = z;
            obj.layer = layer;
            obj.spriteId = spriteId;
            if (id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID) {
              staticBandsDirty = true;
            }
            changed = true;
          }
        } else if (type === 0x03) {
          const id = readU16(bytes, offset);
          offset += 2;
          const gone = objects.get(id);
          if (gone) {
            movingObjects.delete(gone);
            objects.delete(id);
            if (id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID) {
              staticBandsDirty = true;
            }
            changed = true;
          }
        } else if (type === 0x04) {
          objects.clear();
          movingObjects.clear();
          staticBandsDirty = true;
          changed = true;
        } else if (type === 0x05) {
          const layerId = bytes[offset];
          const width = readU16(bytes, offset + 1);
          const height = readU16(bytes, offset + 3);
          offset += 5;
          // The server restates every layer's viewport on every packet. Only
          // an actual resize may take the full path: setViewport reallocates
          // the layer's image and dirties the static-band bake, which would
          // otherwise re-bake the full board once per packet — the exact
          // per-frame cost the bake exists to avoid — and keep a paused
          // board drawing forever.
          const existing = layers.get(layerId);
          if (!existing || !existing.image || existing.width !== width ||
              existing.height !== height) {
            setViewport(layers, layerId, width, height, () => {
              updateNativeSize();
              computeFit();
            });
            staticBandsDirty = true;
            changed = true;
          }
        } else if (type === 0x06) {
          defineLayer(layers, bytes[offset], bytes[offset + 1], bytes[offset + 2]);
          offset += 3;
        } else {
          console.warn('Unknown sprite protocol message type:', type);
          if (socket) socket.close();
          break;
        }
      }
      if (motionSeen) {
        if (lastMotionAt) {
          const gap = packetTime - lastMotionAt;
          // Learn the real motion-packet cadence (~24Hz at every playback
          // speed). Catch-up bursts and pause gaps sit outside the window
          // and do not poison the estimate.
          if (gap >= 16 && gap <= 250) {
            packetInterval += 0.1 * (gap - packetInterval);
          }
        }
        lastMotionAt = packetTime;
      }
      if (pendingDecodes > 0) {
        // A sprite is waiting on a decode retry, and retries only run in
        // composite(): keep compositing on packet arrival until it heals or
        // exhausts its budget (the self-heal path for a transiently-dropped
        // map band — bands are sent exactly once).
        changed = true;
      }
      if (changed) {
        dirty = true;
        scheduleDraw();
        if (!firstFrameFired && objects.size > 0) {
          firstFrameFired = true;
          onFirstFrame();
        }
      }
    }

    function pacePresentOne() {
      // Pop entries up to and including the next binary frame; text messages
      // ride along in arrival order without consuming a cadence slot.
      while (paceQueue.length) {
        const entry = paceQueue.shift();
        if (entry.text !== undefined) {
          onText(entry.text);
          continue;
        }
        paceBinaryCount--;
        parse(entry.bytes);
        pacePresented++;
        if (onFrame) onFrame();
        return true;
      }
      return false;
    }

    function paceFastForward(keepDepth) {
      while (paceBinaryCount > keepDepth) pacePresentOne();
    }

    function paceReset() {
      // Drain anything still pending (in order — they're valid deltas), then
      // start priming from scratch. Used on (re)connect.
      paceFastForward(0);
      while (paceQueue.length) {
        const entry = paceQueue.shift();
        if (entry.text !== undefined) onText(entry.text);
      }
      paceArrivals = [];
      paceFirstArrival = 0;
      pacePrimed = false;
    }

    function paceSchedule() {
      // rAF gives paint-aligned pacing when the page is visible, but it
      // throttles or fully stops in hidden/occluded tabs — the timer backstop
      // keeps presentation and backlog control running there. Whichever fires
      // first cancels the other.
      if (!paceRaf) paceRaf = requestFrame(pacePumpRaf);
      if (!paceTimer) {
        paceTimer = setTimeout(pacePumpTimer, Math.max(25, paceInterval * 1.5));
      }
    }

    function pacePumpRaf(now) {
      paceRaf = null;
      if (paceTimer) {
        clearTimeout(paceTimer);
        paceTimer = null;
      }
      pacePump(now);
    }

    function pacePumpTimer() {
      paceTimer = null;
      if (paceRaf) {
        cancelFrame(paceRaf);
        paceRaf = null;
      }
      pacePump(performance.now());
    }

    function pacePump(now) {
      if (stopped) return;
      if (paceBinaryCount > PACE_MAX_DEPTH) {
        // Fell behind the live stream (delivery burst or stalled tab): apply
        // the backlog immediately so latency stays bounded at the cushion.
        paceFastForward(PACE_TARGET_DEPTH);
        pacePrimed = true;
        paceNextDue = now;
      }
      if (!pacePrimed &&
          (paceBinaryCount > PACE_TARGET_DEPTH ||
            (paceFirstArrival && now - paceFirstArrival >= PACE_PRIME_TIMEOUT))) {
        pacePrimed = true;
        paceNextDue = now;
      }
      // Text messages at the head arrived before every queued binary frame and
      // their preceding frame is already presented — deliver them now.
      while (paceQueue.length && paceQueue[0].text !== undefined) {
        onText(paceQueue.shift().text);
      }
      if (pacePrimed && paceBinaryCount > 0) {
        if (now - paceNextDue > 2 * paceInterval) {
          // Re-anchor after a long stall instead of machine-gunning the
          // backlog through the cadence (fast-forward bounds the depth).
          paceNextDue = now;
        }
        // Present every due frame, capped per invocation: a throttled driver
        // (1Hz setTimeout in a hidden tab) must still keep up, but a
        // recovering stall shouldn't machine-gun the backlog.
        let budget = 3;
        while (budget > 0 && paceBinaryCount > 0 && now >= paceNextDue) {
          budget--;
          pacePresentOne();
          // Nudge the cadence a few percent to hold the cushion at target
          // depth — imperceptible, but stops underruns from permanently
          // ratcheting latency upward (and overruns from accumulating).
          const drift = Math.max(-2, Math.min(2, paceBinaryCount - PACE_TARGET_DEPTH));
          paceNextDue += paceInterval * (1 - 0.02 * drift);
        }
      }
      if (paceQueue.length) paceSchedule();
    }

    function paceEnqueue(event) {
      const isText = typeof event.data === 'string';
      if (isText) {
        if (paceQueue.length === 0) {
          // Nothing buffered ahead of it — no ordering to preserve.
          onText(event.data);
          return;
        }
        paceQueue.push({ text: event.data });
      } else {
        const now = performance.now();
        if (!paceFirstArrival) paceFirstArrival = now;
        paceArrivals.push(now);
        if (paceArrivals.length > PACE_WINDOW) paceArrivals.shift();
        if (paceArrivals.length >= 8) {
          const span = paceArrivals[paceArrivals.length - 1] - paceArrivals[0];
          const mean = span / (paceArrivals.length - 1);
          paceInterval = Math.min(PACE_MAX_INTERVAL, Math.max(PACE_MIN_INTERVAL, mean));
        }
        paceQueue.push({ bytes: new Uint8Array(event.data) });
        paceBinaryCount++;
        if (paceBinaryCount > PACE_HARD_QUEUE) {
          // rAF isn't firing (hidden tab): drain inline to cap memory.
          paceFastForward(PACE_TARGET_DEPTH);
        }
      }
      paceSchedule();
    }

    function connect() {
      if (stopped) return;
      if (paceEnabled) paceReset();
      const ws = new WebSocket(websocketAddress(window.location.href));
      socket = ws;
      ws.binaryType = 'arraybuffer';
      onStatus('connecting');

      ws.onmessage = event => {
        if (socket !== ws) return;
        if (paceEnabled) {
          paceEnqueue(event);
        } else if (typeof event.data === 'string') {
          onText(event.data);
        } else {
          parse(new Uint8Array(event.data));
          if (onFrame) onFrame();
        }
      };

      ws.onopen = () => {
        if (socket !== ws) return;
        onStatus('open');
        reconnectDelay = 1000;
        reconnecting = false;
      };

      ws.onclose = () => {
        if (socket !== ws) return;
        socket = null;
        onStatus('closed');
        if (!stopped && !reconnecting) {
          reconnecting = true;
          setTimeout(() => {
            reconnecting = false;
            reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
            connect();
          }, reconnectDelay);
        }
      };

      ws.onerror = () => {
        if (socket !== ws) return;
        try { ws.close(); } catch (e) {}
      };
    }

    function sendPacket(bytes) {
      if (onSendPacket) {
        onSendPacket(bytes);
        return;
      }
      if (!socket || socket.readyState !== WebSocket.OPEN) return;
      socket.send(bytes);
    }

    function sendCommand(text) {
      const asciiBytes = [];
      for (let i = 0; i < text.length; i++) {
        const code = text.charCodeAt(i);
        if (code >= 32 && code < 127) asciiBytes.push(code);
      }
      if (asciiBytes.length === 0) return;
      const packet = new Uint8Array(asciiBytes.length + 3);
      packet[0] = 0x81;
      writeU16(packet, 1, asciiBytes.length);
      packet.set(asciiBytes, 3);
      sendPacket(packet);
    }

    function clickMap(mapX, mapY) {
      const ml = mapLayer();
      const layerId = ml ? ml.id : 0;
      const move = new Uint8Array(6);
      move[0] = 0x82;
      writeI16(move, 1, mapX);
      writeI16(move, 3, mapY);
      move[5] = layerId & 255;
      const down = new Uint8Array(9);
      down[0] = 0x82;
      writeI16(down, 1, mapX);
      writeI16(down, 3, mapY);
      down[5] = layerId & 255;
      down[6] = 0x83;
      down[7] = 0x01;
      down[8] = 1;
      sendPacket(down);
      const up = new Uint8Array(9);
      up[0] = 0x82;
      writeI16(up, 1, mapX);
      writeI16(up, 3, mapY);
      up[5] = layerId & 255;
      up[6] = 0x83;
      up[7] = 0x01;
      up[8] = 0;
      sendPacket(up);
    }

    function getTransform() {
      return viewSnapshot();
    }

    function setViewportFit() {
      updateNativeSize();
      computeFit();
      scheduleDraw();
    }

    function setViewportSize(width, height, dpr) {
      viewportWidth = Math.max(1, Number(width) || 1);
      viewportHeight = Math.max(1, Number(height) || 1);
      pixelRatio = Math.max(0.1, Number(dpr) || 1);
      computeFit();
      scheduleDraw();
    }

    function start() {
      updateNativeSize();
      computeFit();
      if (websocketEnabled) connect();
      else onStatus('open');
      scheduleDraw();
    }

    function ingest(bytes) {
      parse(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
      if (onFrame) onFrame();
    }

    function stop() {
      stopped = true;
      if (socket) {
        socket.close();
        socket = null;
      }
      if (rafHandle) {
        cancelFrame(rafHandle);
        rafHandle = null;
      }
      if (paceRaf) {
        cancelFrame(paceRaf);
        paceRaf = null;
      }
      if (paceTimer) {
        clearTimeout(paceTimer);
        paceTimer = null;
      }
    }

    function getPaceStats() {
      return {
        enabled: paceEnabled,
        queued: paceBinaryCount,
        presented: pacePresented,
        interval: paceInterval,
        primed: pacePrimed,
        // Total frames blitted to the canvas. The delta per second is the
        // presentation rate: ~display refresh while motion glides, ~0 on a
        // paused or end-held board.
        draws: drawCount
      };
    }

    return {
      start,
      ingest,
      sendCommand,
      clickMap,
      getTransform,
      setViewportFit,
      setViewportSize,
      getPaceStats,
      zoomAt,
      setZoom,
      panBy,
      panByMap,
      panTo,
      resetView,
      attachMinimap,
      stop
    };
  }

  window.BroadcastCore = { create: BroadcastCore };
})();
