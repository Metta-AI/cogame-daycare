(function () {
  'use strict';

  var failed = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js', scriptUrl || location.href);

  function showFailure(error) {
    // First failure wins: an OOM abort reports once from the Worker (with the
    // stage note), then may also surface as an error event. Keep the specific
    // diagnostic instead of overwriting it with the generic one.
    if (failed) return;
    failed = true;
    console.error(error);
    // The signal tools/ci/viewer_smoke.mjs and phase 60's viewer-check.yml
    // read on failure (the load signal is data-replay-loaded, set below).
    document.documentElement.setAttribute('data-replay-error', error.message || String(error));
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + (error.message || String(error));
      status.classList.add('show');
    }
  }

  function setMismatchTick(tick) {
    if (tick >= 0) {
      document.documentElement.setAttribute(
        'data-replay-mismatch-tick', String(tick));
    }
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var lastFrame = 0;
    var accumulator = 0;
    var frameMs = 1000 / 24;
    var workerDraws = 0;
    // Same shape the in-process core reports, so the page's view controls read
    // one object either way. These are the pre-stream values: fitted, whole
    // board, nothing to pan — which is exactly the state the board opens in.
    var transform = {
      scale: 1,
      offsetX: 0,
      offsetY: 0,
      nativeW: 1,
      nativeH: 1,
      zoom: 1,
      minZoom: 1,
      maxZoom: 12,
      fitScale: 1,
      focusX: 0,
      focusY: 0,
      visW: 1,
      visH: 1
    };
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;
    var pendingMinimap = null;
    var minimapSent = false;

    // transferControlToOffscreen is one-way and one-shot: the canvas is dead to
    // the main thread afterwards, so this must happen exactly once, and only
    // once the Worker exists to receive it.
    function sendMinimap() {
      if (!worker || !pendingMinimap || minimapSent) return;
      if (typeof pendingMinimap.transferControlToOffscreen !== 'function') return;
      try {
        var surface = pendingMinimap.transferControlToOffscreen();
        minimapSent = true;
        pendingMinimap = null;
        worker.postMessage({ type: 'minimap', canvas: surface }, [surface]);
      } catch (error) {
        console.warn('Minimap unavailable', error);
        pendingMinimap = null;
      }
    }

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize',
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      if (!advanceInFlight && accumulator >= frameMs) {
        var frames = Math.min(6, Math.floor(accumulator / frameMs));
        accumulator -= frames * frameMs;
        advanceInFlight = true;
        worker.postMessage({ type: 'advance', frames: frames });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'text') {
          if (config.onText) config.onText(message.text);
        } else if (message.type === 'status') {
          if (config.onStatus) config.onStatus(message.status);
        } else if (message.type === 'firstFrame') {
          if (config.onFirstFrame) config.onFirstFrame();
        } else if (message.type === 'transform') {
          transform = message.transform;
          // The view lives a thread away, so the page's controls can only learn
          // about a zoom/pan when the Worker says so — same callback the
          // in-process core fires, so the page has one code path.
          if (config.onTransform) config.onTransform(transform);
        } else if (message.type === 'loaded') {
          setMismatchTick(message.mismatchTick);
          loaded = true;
          document.documentElement.setAttribute('data-replay-loaded', 'true');
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          setMismatchTick(message.mismatchTick);
          advanceInFlight = false;
          if (typeof message.draws === 'number') workerDraws = message.draws;
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      var replayUrl = new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('Missing required replay URL'));
        return;
      }
      readViewport();
      if (config.onStatus) config.onStatus('connecting');
      try {
        worker = new Worker(workerUrl, { name: 'daycare-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          showFailure(new Error(event.message || 'Replay Worker crashed'));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init',
          replayUrl: replayUrl,
          canvas: offscreen,
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        }, [offscreen]);
        sendMinimap();
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      sendCommand: function (text) {
        if (worker) worker.postMessage({ type: 'command', text: text });
      },
      clickMap: function (mapX, mapY) {
        if (worker) worker.postMessage({ type: 'click', x: mapX, y: mapY });
      },
      // Zoom/pan forwarded to the worker that owns the OffscreenCanvas. Same
      // signatures as the in-process core, so the page drives one API whether
      // it renders here or in a worker.
      zoomAt: function (factor, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'zoom', factor: factor, x: x, y: y });
      },
      setZoom: function (level, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'setZoom', level: level, x: x, y: y });
      },
      panBy: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'pan', dx: dx, dy: dy });
      },
      panByMap: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'panMap', dx: dx, dy: dy });
      },
      panTo: function (x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'panTo', x: x, y: y });
      },
      resetView: function () {
        if (worker) worker.postMessage({ type: 'view', action: 'reset' });
      },
      // The board pixels the minimap shrinks live in the Worker, so the Worker
      // has to draw it: hand over control of the page's minimap canvas exactly
      // once and let the core keep it in sync from there.
      attachMinimap: function (surface) {
        // The page wires its controls before start(), so hold the surface until
        // there is a Worker to hand it to.
        pendingMinimap = surface || null;
        sendMinimap();
      },
      getTransform: function () { return transform; },
      setViewportFit: postViewport,
      getPaceStats: function () {
        // `draws` mirrors the Worker core's blit count (refreshed on every
        // 'advanced' ack), so the page can observe the real presentation
        // rate even though drawing happens a thread away.
        return {
          enabled: false,
          queued: 0,
          presented: 0,
          interval: frameMs,
          draws: workerDraws
        };
      }
    };
  }

  window.CtfStaticReplay = {
    createCore: createCore
  };
})();
