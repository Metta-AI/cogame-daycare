#!/usr/bin/env node
// Static replay viewer LOAD test -- the gate that actually executes the viewer.
//
// Goes to:  tools/ci/viewer_smoke.mjs  in the coworld repo (no substitutions).
// Runs in:  ci.yml's `wasm-viewer` job, and coworld-builder's
//           .github/workflows/viewer-check.yml (phase 60 check 8).
//
// WHY THIS EXISTS
// ---------------
// Until 2026-08-23 nothing anywhere EXECUTED the replay viewer. ci.yml's
// wasm-viewer job asserted that index.html and a .wasm existed; phase 60
// check 8 asserted that every asset returned 200 and that static_replay.js
// contained `tell("ready")`. Both passed for cogame-lantern, whose viewer
// deadlocked forever: config.nims linked the wasm with
// `-s MODULARIZE=1 -s EXPORT_NAME=LanternReplayModule` (copied from the babel
// starter) while static_replay_worker.js kept paintbot's NON-modularized
// bootstrap (`Module.onRuntimeInitialized = ...; importScripts(...)`) and never
// called the factory. No error was thrown, `data-replay-loaded` was never set,
// and softmax.com showed "Loading replay..." forever. A file-presence check
// cannot see that. Opening the page in a real browser can.
//
// USAGE
// -----
//   node tools/ci/viewer_smoke.mjs --bundle <dir> --replay <file> [--timeout 60]
//   node tools/ci/viewer_smoke.mjs --url <full viewer url with ?replay=> [--timeout 90]
//
//   --bundle <dir>    a built static-replay-viewer bundle. Served over a local
//                     HTTP server (the python3 -m http.server equivalent, in
//                     Node, so no extra dependency); the page is opened at
//                     index.html?replay=http://127.0.0.1:<port>/<replay name>.
//                     file:// is deliberately NOT used: wasm streaming
//                     compilation and fetch() both behave differently there,
//                     so a file:// pass would not be evidence about the
//                     hosted bundle.
//   --replay <file>   the replay to load. Required with --bundle.
//   --url <url>       a live viewer URL instead (must already carry ?replay=).
//   --timeout <s>     seconds to wait for the load signal (default 60).
//   --soak <s>        after the load signal, watch the viewer PLAY for this
//                     many seconds (default 0 = off). See "SOAK" below.
//   --strict-text-bounds
//                     fail if the viewer drew any text outside its canvas.
//                     Use it for a FIXED arena; leave it off for a pannable
//                     board. See "TEXT BOUNDS" below.
//   --out <dir>       where viewer-smoke.png / viewer-smoke.json land
//                     (default: cwd).
//   --headed          run headful (local debugging only).
//
// EXIT CODES
//   0  the viewer loaded and drew a frame; JSON line on stdout, png + json saved.
//   1  the viewer reported an error, or never signalled within the timeout.
//      The last 30 console messages and the on-screen readouts are printed.
//   2  bad arguments / missing Playwright.
//
// PLAYWRIGHT PIN
// --------------
// Chromium via Playwright **1.55.0**. Both the module and the browser are
// pinned; bumping one without the other is how a browser download 404s in CI.
//
//   npm install --no-save playwright@1.55.0
//   npx --yes playwright@1.55.0 install --with-deps chromium
//
// (ci.yml and coworld-builder's viewer-check.yml both carry this pin verbatim.
// Set PLAYWRIGHT_MODULE to an absolute path to load it from somewhere else.)
//
// THE TWO SIGNALS
// ---------------
// A viewer is "loaded" when EITHER of these arrives:
//
//   (a) `document.documentElement` carries `data-replay-loaded="true"` -- the
//       marker the acceptance checklist (prompts/30-review-loop.md item 13)
//       requires every new shell to set on its first drawn frame; or
//   (b) the `coworld-replay` postMessage bridge posts `{type:"ready"}`.
//
// (b) is accepted because the bridge predates the attribute and bundles built
// before 2026-08-23 (bullwhip, lighthouse) only have the bridge. New shells
// must set the attribute -- it is the signal that survives being loaded
// top-level, in a worker-less shell, or with the bridge stripped.
//
// Catching (b) needs a trick. The shell posts to `window.parent` and returns
// early when `window.parent === window`, which is exactly the case here: the
// harness loads the viewer as the TOP-LEVEL document, not in an iframe (an
// iframe would add a cross-origin variable that has nothing to do with whether
// the viewer works). `parent` is a [Replaceable] attribute on Window, so a
// plain assignment in an init script shadows it with a stub whose postMessage
// forwards into Node. window.postMessage and a `message` listener are hooked
// too, so a shell that posts to itself is caught as well.
//
// FAILURE IS EITHER SIGNAL SAYING NO, OR NEITHER SAYING ANYTHING
// --------------------------------------------------------------
// `data-replay-error` (or a bridge `{type:"error"}`) fails immediately and the
// message is printed. Silence until the timeout is ALSO a failure -- that is
// the lantern deadlock, and it is the whole point of this file.
//
// SOAK -- LOADING IS NOT PLAYING (added after cogball 0.1.4, 2026-08-23)
// ---------------------------------------------------------
// `--soak <seconds>`: after the load signal it watches the clock / tick / scorebug for
// that long and fails if none of them moved, or if an uncaught page error
// arrived. cogball 0.1.4 loaded, drew one frame, set data-replay-loaded and
// then threw inside that frame's feed render; static_replay.js caught the
// throw, latched `failed` and ignored every later Worker message, so the board
// froze on tick 2 looking entirely healthy. The load signal said yes and the
// scrub readouts said yes too -- seeking clears the feed queue and skips the
// frame that did the killing. Only uninterrupted playback shows it.
//
// TEXT BOUNDS -- DRAWN IS NOT THE SAME AS VISIBLE (added after cogchemists,
// 2026-08-24)
// ---------------------------------------------------------------
// A canvas silently accepts a draw at a negative coordinate. cogchemists drew
// each seat's speech bubble UPWARD from the top of its cog, and the cog sat at
// the top of the arena: every bubble body landed at a negative y and the
// viewer showed four white slivers where four sentences should have been.
// Nothing errored, the load signal said yes, the soak said yes, and the
// screenshot looked like a working viewer to anything that was not reading it.
//
// So `CanvasRenderingContext2D.prototype.fillText` / `strokeText` are hooked
// in the init script and every drawn string is measured against its canvas.
// The summary carries
// `canvas_text: {total, outside, never_inside, ellipsized, samples}`:
//
//   outside       DRAWS whose measured box crossed a canvas edge. Reported,
//                 never gated: an animation that slides a card on from
//                 off-frame is outside for a few frames by design
//                 (cogchemists' own lab bench does exactly that).
//   never_inside  distinct STRINGS that crossed an edge on every single draw
//                 and never once landed inside. That is the defect -- a
//                 caption anchored where there is no room exists off-frame
//                 for its whole life, while a sliding card settles. For a
//                 FIXED arena (the whole board fits the frame) this must be
//                 0, and `--strict-text-bounds` makes a nonzero count exit 1.
//                 A pannable board parks text off-frame legitimately, so the
//                 flag is dropped there and the number is read, not gated.
//   ellipsized    draws the renderer itself cut with an ellipsis. Card labels
//                 and nameplates do this on purpose; a sentence doing it
//                 means the text has outgrown the box it was given. Never a
//                 failure, always worth a look when a caption reads short.
//
// Strings are tallied by their text, capped at 4000 distinct
// (`distinct_capped` says when that cap was hit).
//
// Only main-thread 2D contexts are seen. A viewer that draws into an
// OffscreenCanvas inside a worker reports total: 0 -- which is itself the
// signal that this check did not cover it.

import { createServer } from "node:http";
import { createReadStream, existsSync, statSync, writeFileSync } from "node:fs";
import { basename, extname, join, resolve, sep } from "node:path";
import process from "node:process";

// --------------------------------------------------------------------------
// Arguments.
// --------------------------------------------------------------------------
function die(code, message) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const out = { timeout: 60, soak: 0, outDir: process.cwd(), headed: false, strictTextBounds: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (value === undefined) die(2, `missing value for ${arg}`);
      i += 1;
      return value;
    };
    switch (arg) {
      case "--bundle": out.bundle = resolve(next()); break;
      case "--replay": out.replay = resolve(next()); break;
      case "--url": out.url = next(); break;
      case "--timeout": out.timeout = Number(next()); break;
      case "--soak": out.soak = Number(next()); break;
      case "--strict-text-bounds": out.strictTextBounds = true; break;
      case "--out": out.outDir = resolve(next()); break;
      case "--headed": out.headed = true; break;
      case "-h":
      case "--help":
        die(0, "usage: viewer_smoke.mjs (--bundle <dir> --replay <file> | --url <url>) [--timeout 60] [--soak 0] [--strict-text-bounds] [--out dir]");
        break;
      default: die(2, `unknown argument: ${arg}`);
    }
  }
  if (!out.url && !out.bundle) die(2, "one of --bundle or --url is required");
  if (out.url && out.bundle) die(2, "--bundle and --url are mutually exclusive");
  if (out.bundle && !out.replay) die(2, "--bundle requires --replay");
  if (!Number.isFinite(out.timeout) || out.timeout <= 0) die(2, "--timeout must be a positive number of seconds");
  if (!Number.isFinite(out.soak) || out.soak < 0) die(2, "--soak must be a non-negative number of seconds");
  return out;
}

const args = parseArgs(process.argv.slice(2));

// --------------------------------------------------------------------------
// Playwright, pinned. Resolved late so --help works without it installed.
// --------------------------------------------------------------------------
async function loadChromium() {
  const candidates = [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"].filter(Boolean);
  const errors = [];
  for (const candidate of candidates) {
    try {
      const mod = await import(candidate);
      if (mod.chromium) return mod.chromium;
      if (mod.default && mod.default.chromium) return mod.default.chromium;
    } catch (error) {
      errors.push(`${candidate}: ${error && error.message}`);
    }
  }
  die(2,
    "could not load Playwright. Install the pinned version:\n" +
    "  npm install --no-save playwright@1.55.0\n" +
    "  npx --yes playwright@1.55.0 install --with-deps chromium\n" +
    "(or point PLAYWRIGHT_MODULE at an installed copy)\n" +
    errors.map((e) => `  tried ${e}`).join("\n"));
}

// --------------------------------------------------------------------------
// Static file server for --bundle mode.
// --------------------------------------------------------------------------
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".replay": "application/octet-stream",
  ".map": "application/json; charset=utf-8",
};

function serveBundle(bundleDir, replayPath) {
  if (!existsSync(bundleDir) || !statSync(bundleDir).isDirectory()) {
    die(2, `bundle directory not found: ${bundleDir}`);
  }
  if (!existsSync(join(bundleDir, "index.html"))) {
    die(2, `bundle has no index.html: ${bundleDir}`);
  }
  if (!existsSync(replayPath) || !statSync(replayPath).isFile()) {
    die(2, `replay file not found: ${replayPath}`);
  }
  const replayName = basename(replayPath);
  const root = resolve(bundleDir);
  const served = [];

  const server = createServer((req, res) => {
    let pathname;
    try {
      pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
    } catch {
      res.writeHead(400).end("bad url");
      return;
    }
    if (pathname === "/") pathname = "/index.html";
    // The replay is mounted by name at the root whether or not it lives inside
    // the bundle, so the ?replay= URL is the same in both cases.
    const target = pathname === `/${replayName}`
      ? replayPath
      : resolve(join(root, pathname));
    if (target !== replayPath && !(target === root || target.startsWith(root + sep))) {
      res.writeHead(403).end("forbidden");
      return;
    }
    if (!existsSync(target) || !statSync(target).isFile()) {
      served.push({ path: pathname, status: 404, bytes: 0 });
      res.writeHead(404).end("not found");
      return;
    }
    const size = statSync(target).size;
    served.push({ path: pathname, status: 200, bytes: size });
    res.writeHead(200, {
      "content-type": MIME[extname(target).toLowerCase()] || "application/octet-stream",
      "content-length": String(size),
      // Cross-origin isolation headers are NOT set: the hosted bundle is not
      // served with them either, so a viewer that needs SharedArrayBuffer must
      // fail here exactly as it fails in production.
      "cache-control": "no-store",
    });
    createReadStream(target).pipe(res);
  });

  return new Promise((resolveServer) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolveServer({
        server,
        served,
        port,
        url: `http://127.0.0.1:${port}/index.html?replay=${encodeURIComponent(`http://127.0.0.1:${port}/${replayName}`)}`,
      });
    });
  });
}

// --------------------------------------------------------------------------
// Page-side instrumentation. See "THE TWO SIGNALS" in the header.
// --------------------------------------------------------------------------
const INIT_SCRIPT = `(() => {
  const relay = (data) => {
    if (!data || typeof data !== "object") return;
    if (data.src !== "coworld-replay") return;
    try {
      window.__coworldSmokeBridge({ type: String(data.type || ""), message: data.message ? String(data.message) : "" });
    } catch (ignore) {}
  };
  // \`parent\` is [Replaceable] on Window: assignment shadows it. The shell's
  // \`if (window.parent === window) return;\` guard then passes.
  try { window.parent = { postMessage: (data) => relay(data) }; } catch (ignore) {}
  try {
    const original = window.postMessage.bind(window);
    window.postMessage = function (data, ...rest) { relay(data); return original(data, ...rest); };
  } catch (ignore) {}
  window.addEventListener("message", (event) => relay(event.data));

  // ---- Text bounds. See "TEXT BOUNDS" in the header. -------------------
  // Every fillText/strokeText is measured against its own canvas. A draw
  // that crosses an edge is invisible to the viewer and to a screenshot
  // diff, but it is exactly what a bubble or a caption with nowhere to go
  // looks like.
  const seen = { total: 0, outside: 0, ellipsized: 0, samples: [] };
  // Per drawn STRING: how many of its draws landed inside the canvas and how
  // many crossed an edge. A card that slides on from off-frame is outside for
  // a few frames and inside for the rest; a caption anchored where there is no
  // room is outside for every frame it exists. Only the second is a defect,
  // so the gate is "never once inside", not "ever outside".
  const byText = new Map();
  const TEXT_CAP = 4000;
  const TOL = 1;
  const SAMPLE_CAP = 12;
  const note = (entry) => {
    if (seen.samples.length < SAMPLE_CAP) seen.samples.push(entry);
  };
  seen.report = () => {
    const never = [];
    for (const [text, tally] of byText) {
      if (tally.out > 0 && tally.in === 0) never.push({ text, ...tally });
    }
    return {
      total: seen.total,
      outside: seen.outside,
      ellipsized: seen.ellipsized,
      never_inside: never.length,
      never_inside_samples: never.slice(0, SAMPLE_CAP).map((n) => ({
        kind: "never-inside", edges: n.edges, text: n.text.slice(0, 60),
        box: n.box, canvas: n.canvas, draws: n.out,
      })),
      distinct_capped: byText.size >= TEXT_CAP,
      samples: seen.samples,
    };
  };
  window.__coworldTextBounds = seen;
  const wrap = (name) => {
    const proto = window.CanvasRenderingContext2D && window.CanvasRenderingContext2D.prototype;
    if (!proto || typeof proto[name] !== "function") return;
    const real = proto[name];
    proto[name] = function (text, x, y, ...rest) {
      const out = real.call(this, text, x, y, ...rest);
      try {
        const str = String(text);
        seen.total += 1;
        if (/\u2026\s*$/.test(str)) {
          seen.ellipsized += 1;
          note({ kind: "ellipsized", text: str.slice(0, 60) });
        }
        const canvas = this.canvas;
        if (!canvas || !canvas.width || !canvas.height) return out;
        const m = this.measureText(str);
        const align = this.textAlign;
        let left = x;
        if (align === "center") left = x - m.width / 2;
        else if (align === "right" || align === "end") left = x - m.width;
        const right = left + m.width;
        // Chromium's actualBoundingBox* are measured from the alignment
        // point and already account for textBaseline.
        const asc = Number.isFinite(m.actualBoundingBoxAscent) ? m.actualBoundingBoxAscent : 0;
        const desc = Number.isFinite(m.actualBoundingBoxDescent) ? m.actualBoundingBoxDescent : 0;
        const top = y - asc;
        const bottom = y + desc;
        const edges = [];
        if (top < -TOL) edges.push("top");
        if (left < -TOL) edges.push("left");
        if (bottom > canvas.height + TOL) edges.push("bottom");
        if (right > canvas.width + TOL) edges.push("right");
        let tally = byText.get(str);
        if (!tally && byText.size < TEXT_CAP) {
          tally = { in: 0, out: 0, edges: "", box: null, canvas: null };
          byText.set(str, tally);
        }
        if (edges.length) {
          seen.outside += 1;
          const box = [Math.round(left), Math.round(top), Math.round(right), Math.round(bottom)];
          const size = [canvas.width, canvas.height];
          if (tally) {
            tally.out += 1;
            tally.edges = edges.join("+");
            tally.box = box;
            tally.canvas = size;
          }
          note({ kind: "outside", edges: edges.join("+"), text: str.slice(0, 60), box, canvas: size });
        } else if (tally) {
          tally.in += 1;
        }
      } catch (ignore) {}
      return out;
    };
  };
  wrap("fillText");
  wrap("strokeText");
})();`;

const READOUT_SCRIPT = `(() => {
  const text = (selector) => {
    const node = document.querySelector(selector);
    if (!node) return null;
    return (node.innerText || node.textContent || "").replace(/\\s+/g, " ").trim();
  };
  const statusNode = document.querySelector("#statuschip, #status, .statuschip, [data-status]");
  const feed = document.querySelector("#feed, .feed, #log");
  return {
    clock: text("#clock"),
    tick: text("#tick-clock, #tick, .tick-clock"),
    scorebug: text("#scorebug"),
    status: statusNode ? (statusNode.innerText || statusNode.textContent || "").replace(/\\s+/g, " ").trim() : null,
    loading: text("#loading"),
    feed_lines: feed ? feed.querySelectorAll("*").length : 0,
    loaded_attr: document.documentElement.getAttribute("data-replay-loaded"),
    error_attr: document.documentElement.getAttribute("data-replay-error"),
    has_scrub: !!document.querySelector("#scrub"),
  };
})();`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const chromium = await loadChromium();

  let hosted = null;
  let target = args.url;
  if (args.bundle) {
    hosted = await serveBundle(args.bundle, args.replay);
    target = hosted.url;
  }

  const consoleLog = [];
  const pageErrors = [];
  const bridge = [];
  const record = (line) => {
    consoleLog.push(line);
    if (consoleLog.length > 400) consoleLog.shift();
  };

  const browser = await chromium.launch({ headless: !args.headed });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  await context.exposeFunction("__coworldSmokeBridge", (event) => {
    bridge.push({ ...event, at: Date.now() });
    record(`[bridge] ${event.type}${event.message ? " " + event.message : ""}`);
  });
  await context.addInitScript(INIT_SCRIPT);

  page.on("console", (msg) => record(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => {
    pageErrors.push(String(err && err.message));
    record(`[pageerror] ${err && err.message}`);
  });
  page.on("requestfailed", (req) => {
    const failure = req.failure();
    record(`[requestfailed] ${req.url()} ${failure ? failure.errorText : ""}`);
  });
  page.on("response", (res) => {
    if (res.status() >= 400) record(`[http ${res.status()}] ${res.url()}`);
  });

  const started = Date.now();
  const deadline = started + args.timeout * 1000;
  let navError = null;
  try {
    await page.goto(target, { waitUntil: "commit", timeout: Math.min(args.timeout * 1000, 60000) });
  } catch (error) {
    navError = String(error && error.message || error);
    record(`[navigation] ${navError}`);
  }

  let loaded = false;
  let failure = navError;
  let readout = null;
  while (Date.now() < deadline) {
    try {
      readout = await page.evaluate(READOUT_SCRIPT);
    } catch {
      readout = readout || null;   // mid-navigation; retry on the next tick
    }
    const bridgeError = bridge.find((e) => e.type === "error");
    if (bridgeError) { failure = `bridge error: ${bridgeError.message || "(no message)"}`; break; }
    if (readout && readout.error_attr) { failure = `data-replay-error: ${readout.error_attr}`; break; }
    if (readout && readout.loaded_attr === "true") { loaded = true; break; }
    if (bridge.some((e) => e.type === "ready")) { loaded = true; break; }
    await sleep(250);
  }
  const elapsedMs = Date.now() - started;
  if (!loaded && !failure) {
    failure = `timeout: no data-replay-loaded="true" and no coworld-replay "ready" within ${args.timeout}s`;
  }
  try { readout = await page.evaluate(READOUT_SCRIPT); } catch { /* keep the last good readout */ }

  // ------------------------------------------------------------------
  // SOAK (--soak). LOADING IS NOT PLAYING. cogball 0.1.4 loaded, drew its
  // first frame, set data-replay-loaded -- and then threw inside that frame's
  // feed render. static_replay.js caught the throw, latched `failed` and
  // dropped every later Worker message, so the board sat frozen on tick 2 with
  // a full scorebug and a screenshot that looks like a working viewer. No load
  // signal can see that; watching the readouts move can. Seeking cannot
  // replace it either -- a scrub clears the feed queue and skips the very
  // frame that killed this one.
  // ------------------------------------------------------------------
  let soak = null;
  let playFailure = null;
  if (loaded && args.soak > 0) {
    // THREE samples, not two. A viewer that dies mid-boot still advances a
    // tick or two first (cogball 0.1.4 froze on tick 2), so "it moved at some
    // point during the soak" passes a corpse. The LAST interval is the one
    // that has to move: still advancing at the end means still playing.
    const tail = Math.min(2, args.soak / 2);
    const before = readout;
    await sleep(Math.max(0, args.soak - tail) * 1000);
    let middle = before;
    try { middle = await page.evaluate(READOUT_SCRIPT); } catch { /* keep the last good readout */ }
    await sleep(tail * 1000);
    let after = middle;
    try { after = await page.evaluate(READOUT_SCRIPT); } catch { /* keep the last good readout */ }
    const advanced = (a, b) => ["clock", "tick", "scorebug"].some(
      (key) => a && b && a[key] !== b[key]);
    const moved = advanced(before, middle) && advanced(middle, after);
    soak = {
      seconds: args.soak,
      moved,
      before: before ? { clock: before.clock, tick: before.tick } : null,
      middle: middle ? { clock: middle.clock, tick: middle.tick } : null,
      after: after ? { clock: after.clock, tick: after.tick } : null,
      status: after ? after.status : null,
      page_errors: pageErrors.slice(),
    };
    readout = after;
    if (!moved) {
      playFailure = `frozen: playback stopped advancing within ${args.soak}s ` +
        `(tick ${JSON.stringify(soak.before && soak.before.tick)} -> ` +
        `${JSON.stringify(soak.middle && soak.middle.tick)} -> ` +
        `${JSON.stringify(soak.after && soak.after.tick)}, ` +
        `status ${JSON.stringify(soak.status)})`;
    } else if (pageErrors.length) {
      playFailure = `uncaught page error: ${pageErrors[0]}`;
    }
    if (playFailure) failure = failure || playFailure;
  }

  // ------------------------------------------------------------------
  // Scrub readouts. A replay that renders one frame and never advances is
  // as broken as one that never renders, so the clock is read at 0 %, 50 %
  // and 100 % and the three must differ.
  // ------------------------------------------------------------------
  const scrub = [];
  if (loaded && readout && readout.has_scrub) {
    scrub.push({ at: "0%", clock: readout.clock });
    for (const fraction of [0.5, 1.0]) {
      try {
        const box = await page.locator("#scrub").first().boundingBox();
        if (!box) break;
        const x = box.x + Math.max(1, Math.min(box.width - 1, box.width * fraction));
        await page.mouse.click(x, box.y + box.height / 2);
        await sleep(700);
        const now = await page.evaluate(READOUT_SCRIPT);
        scrub.push({ at: `${Math.round(fraction * 100)}%`, clock: now.clock });
      } catch (error) {
        scrub.push({ at: `${Math.round(fraction * 100)}%`, clock: null, error: String(error && error.message) });
      }
    }
  }

  // ------------------------------------------------------------------
  // Text bounds. See "TEXT BOUNDS" in the header. Read after the soak and
  // the scrub, so it covers every frame the run actually drew.
  // ------------------------------------------------------------------
  let canvasText = null;
  try {
    canvasText = await page.evaluate(`(() => {
      const t = window.__coworldTextBounds;
      return t && t.report ? t.report() : null;
    })()`);
  } catch (error) {
    record(`[text-bounds] ${error && error.message}`);
  }
  let boundsFailure = "";
  if (args.strictTextBounds && canvasText && canvasText.never_inside > 0) {
    boundsFailure = `${canvasText.never_inside} string(s) were NEVER drawn inside the ` +
      `canvas (--strict-text-bounds)`;
  }

  const pngPath = join(args.outDir, "viewer-smoke.png");
  const jsonPath = join(args.outDir, "viewer-smoke.json");
  try { await page.screenshot({ path: pngPath, fullPage: false }); } catch (error) {
    record(`[screenshot] ${error && error.message}`);
  }

  const summary = {
    loaded,
    ms: elapsedMs,
    url: target,
    bundle: args.bundle || null,
    replay: args.replay || null,
    clock: readout ? readout.clock : null,
    scorebug: readout ? readout.scorebug : null,
    status: readout ? readout.status : null,
    loading_text: readout ? readout.loading : null,
    feed_lines: readout ? readout.feed_lines : 0,
    signals: {
      data_replay_loaded: readout ? readout.loaded_attr : null,
      data_replay_error: readout ? readout.error_attr : null,
      bridge: bridge.map((e) => e.type),
      bridge_ready: bridge.some((e) => e.type === "ready"),
      bridge_error: bridge.filter((e) => e.type === "error").map((e) => e.message),
    },
    scrub,
    soak,
    canvas_text: canvasText,
    failure: failure || boundsFailure || null,
    console_tail: consoleLog.slice(-30),
    screenshot: pngPath,
  };
  writeFileSync(jsonPath, JSON.stringify(summary, null, 2) + "\n");

  await browser.close().catch(() => {});
  if (hosted) await new Promise((r) => hosted.server.close(r));

  if (!loaded || playFailure || boundsFailure) {
    console.error(`VIEWER SMOKE FAILED: ${failure || boundsFailure}`);
    if (boundsFailure && canvasText) {
      console.error("  never drawn inside the canvas -- no room was reserved for these:");
      for (const sample of canvasText.never_inside_samples) {
        console.error(`    ${sample.edges} [${sample.box.join(",")}] in ` +
          `${sample.canvas.join("x")}, ${sample.draws} draws: ${JSON.stringify(sample.text)}`);
      }
    }
    console.error(`  url        : ${target}`);
    console.error(`  elapsed    : ${elapsedMs} ms`);
    console.error(`  signals    : data-replay-loaded=${summary.signals.data_replay_loaded} ` +
      `data-replay-error=${summary.signals.data_replay_error} ` +
      `bridge=[${summary.signals.bridge.join(",") || "none"}]`);
    console.error(`  #clock     : ${JSON.stringify(summary.clock)}`);
    console.error(`  #scorebug  : ${JSON.stringify(summary.scorebug)}`);
    console.error(`  status     : ${JSON.stringify(summary.status)}`);
    console.error(`  #loading   : ${JSON.stringify(summary.loading_text)}`);
    if (hosted) {
      console.error("  served     :");
      for (const entry of hosted.served) {
        console.error(`    ${entry.status} ${entry.bytes}B ${entry.path}`);
      }
    }
    console.error("  last 30 console messages:");
    for (const line of summary.console_tail) console.error(`    ${line}`);
    console.error(`  artifacts  : ${pngPath} ${jsonPath}`);
    process.exit(1);
  }

  console.log(JSON.stringify({
    loaded: true,
    ms: elapsedMs,
    clock: summary.clock,
    scorebug: summary.scorebug,
    feed_lines: summary.feed_lines,
  }));
  if (soak) {
    console.log(`soak: ${soak.seconds}s of playback kept advancing ` +
      `(${JSON.stringify(soak.before && soak.before.tick)} -> ` +
      `${JSON.stringify(soak.middle && soak.middle.tick)} -> ` +
      `${JSON.stringify(soak.after && soak.after.tick)})`);
  }
  if (scrub.length) {
    console.log("scrub readouts: " + scrub.map((s) => `${s.at}=${JSON.stringify(s.clock)}`).join("  "));
  }
  if (canvasText) {
    console.log(`canvas text: ${canvasText.total} drawn, ${canvasText.never_inside} never inside ` +
      `the canvas (${canvasText.outside} draws crossed an edge), ` +
      `${canvasText.ellipsized} ellipsized` +
      (args.strictTextBounds ? " (--strict-text-bounds)" : ""));
    for (const sample of canvasText.never_inside_samples) {
      console.log(`  never-inside ${sample.edges}: ${JSON.stringify(sample.text)}`);
    }
    for (const sample of canvasText.samples.filter((x) => x.kind === "ellipsized")) {
      console.log(`  ellipsized: ${JSON.stringify(sample.text)}`);
    }
  } else {
    console.log("canvas text: no main-thread 2D text seen -- this check covered nothing " +
      "(worker/OffscreenCanvas renderer, or a WebGL viewer)");
  }
  console.log(`artifacts: ${pngPath} ${jsonPath}`);
}

main().catch((error) => {
  console.error(`VIEWER SMOKE CRASHED: ${error && error.stack || error}`);
  process.exit(1);
});
