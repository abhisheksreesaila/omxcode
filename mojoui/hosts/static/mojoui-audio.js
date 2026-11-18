// The page's audio (goal 72 M5, docs/web-audio.md): the browser's microphone goes to the app, the app's speaker plays here.
// One WebSocket, /audio, carries both; the page only opens it when the host says so (#mojoui-root[data-audio], never in the
// public copy). Binary frames start with a tag byte: 1 = microphone (16-bit mono, 16 kHz, up), 2 = speaker (16-bit mono,
// 24 kHz, down); 3 is kept for the camera. Text frames are JSON: {t: claim | latency | mic_fail} up, {t: mic | flush | tap |
// bumped} down.
//
// A browser plays no sound until the person has touched the page, so the first tap, key or click anywhere (the app's own
// microphone button is one) turns audio on and makes this page the one the app hears and speaks through; until then, if an
// app wants audio, a small "Tap to turn on sound" button says so. window.mojouiAudio.stats() reports what the page did (the
// checks read it).
(() => {
  const RATE_OUT = 24000;
  let ws = null, ctx = null, gain = null, analyser = null, claimed = false, bumped = false;
  let micStream = null, micNode = null, micSrc = null, micWanted = false, micBusy = false;
  let nextAt = 0, sources = [], pill = null;
  const stats = { scheduledMs: 0, flushes: [], micFrames: 0, micSamples: 0, played: 0, micError: '', frames: 0, underruns: 0 };
  const root = () => document.getElementById('mojoui-root');
  const send = o => { if (ws && ws.readyState === 1) ws.send(typeof o === 'string' ? o : JSON.stringify(o)); };

  const showPill = on => {
    if (on && !pill) {
      pill = document.createElement('button');
      pill.id = 'mojoui-audio-pill'; pill.className = 'mojoui-audio-pill'; pill.type = 'button';
      pill.textContent = 'Tap to turn on sound';
      document.body.appendChild(pill);
    }
    if (pill) pill.hidden = !on;
  };

  const ensureCtx = async () => {
    if (!ctx) {
      ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
      gain = ctx.createGain(); analyser = ctx.createAnalyser(); analyser.fftSize = 2048;
      gain.connect(analyser); analyser.connect(ctx.destination);
      try { await ctx.audioWorklet.addModule('/audio/worklet.js'); } catch (e) { stats.micError = 'worklet: ' + e; }
    }
    if (ctx.state === 'suspended') { try { await ctx.resume(); } catch (e) {} }
    send({ t: 'latency', us: Math.round(((ctx.baseLatency || 0) + (ctx.outputLatency || 0)) * 1e6) });
    return ctx.state === 'running';
  };

  // the app's speaker: each frame becomes a buffer scheduled right after the last, so nothing gaps or overlaps
  const play = bytes => {
    if (!ctx || ctx.state !== 'running') return;
    const i16 = new Int16Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)), f = new Float32Array(i16.length);
    for (let i = 0; i < i16.length; i++) f[i] = i16[i] / 32768;
    const b = ctx.createBuffer(1, f.length, RATE_OUT); b.copyToChannel(f, 0);
    const s = ctx.createBufferSource(); s.buffer = b; s.connect(gain);
    if (sources.length && nextAt < ctx.currentTime) stats.underruns += 1;  // (the queue ran dry while it was still playing: a gap)
    nextAt = Math.max(nextAt, ctx.currentTime + 0.03); s.start(nextAt); nextAt += b.duration;
    stats.scheduledMs += b.duration * 1000; stats.played += f.length; stats.frames += 1;
    sources.push(s); s.onended = () => { sources = sources.filter(x => x !== s); };
  };
  const flush = () => {
    stats.flushes.push(performance.now());
    sources.forEach(s => { try { s.stop(); } catch (e) {} });
    sources = []; nextAt = 0;
  };

  // the page's microphone, while an app has started its Microphone
  const micOn = async () => {
    if (micStream || micBusy) return;
    micBusy = true;
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return send({ t: 'mic_fail', code: 103 });
      await ensureCtx();
      micStream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
      if (!micWanted) { micStream.getTracks().forEach(t => t.stop()); micStream = null; return; }
      micSrc = ctx.createMediaStreamSource(micStream);
      micNode = new AudioWorkletNode(ctx, 'mojoui-mic');
      micNode.port.onmessage = e => {
        const out = new Uint8Array(1 + e.data.byteLength); out[0] = 1; out.set(new Uint8Array(e.data), 1);
        stats.micFrames += 1; stats.micSamples += e.data.byteLength >> 1;
        if (ws && ws.readyState === 1 && micWanted) ws.send(out);
      };
      micSrc.connect(micNode);  // (not to the speakers: the app decides what is heard)
    } catch (e) {
      stats.micError = String((e && e.name) || e);
      send({ t: 'mic_fail', code: e && e.name === 'NotAllowedError' ? 101 : (e && e.name === 'NotFoundError' ? 102 : 103) });
    } finally { micBusy = false; }
  };
  const micOff = () => {
    if (micStream) micStream.getTracks().forEach(t => t.stop());
    if (micNode) { micNode.port.onmessage = null; micNode.disconnect(); }
    if (micSrc) micSrc.disconnect();
    micStream = micNode = micSrc = null;
  };

  const control = m => {
    if (m.t === 'mic') { micWanted = !!m.on; if (micWanted) micOn(); else micOff(); }
    else if (m.t === 'flush') flush();
    else if (m.t === 'tap') showPill(!claimed || !ctx || ctx.state !== 'running');
    else if (m.t === 'bumped') { bumped = true; claimed = false; micOff(); flush(); }
  };

  const connect = () => {
    ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/audio');
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => { if (claimed) send({ t: 'claim' }); };
    ws.onmessage = e => {
      if (typeof e.data === 'string') return control(JSON.parse(e.data));
      const b = new Uint8Array(e.data);
      if (b[0] === 2) play(b.subarray(1));
    };
    ws.onclose = () => { micOff(); flush(); if (!bumped) setTimeout(connect, 1500); };
  };

  // the first touch: audio may start now, and this page is the one the app uses
  const enable = async () => {
    if (!root() || root().dataset.audio !== '1') return;
    for (const n of ['pointerdown', 'keydown', 'touchend']) document.removeEventListener(n, enable, true);
    claimed = true; bumped = false;
    send({ t: 'claim' });  // (at once: the app's own button may be what this tap is, and its answer comes next)
    await ensureCtx();
    showPill(false);
  };

  document.addEventListener('DOMContentLoaded', () => {
    if (!root() || root().dataset.audio !== '1') return;
    connect();
    for (const n of ['pointerdown', 'keydown', 'touchend']) document.addEventListener(n, enable, true);
  });
  document.addEventListener('click', e => { if (e.target && e.target.id === 'mojoui-audio-pill') enable(); });
  addEventListener('pagehide', () => { micOff(); if (ws) ws.close(); });

  window.mojouiAudio = {
    stats: () => {
      let rms = 0, hz = 0;
      if (analyser) {
        const d = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(d);
        let s = 0, crossings = 0;
        for (let i = 0; i < d.length; i++) s += d[i] * d[i];
        rms = Math.sqrt(s / d.length);
        for (let i = 1; i < d.length; i++) if ((d[i - 1] < 0) !== (d[i] < 0)) crossings++;
        hz = crossings * ctx.sampleRate / d.length / 2;
      }
      return Object.assign({}, stats, { rms, hz, ctx: ctx ? ctx.state : 'none', ahead: ctx ? Math.max(0, nextAt - ctx.currentTime) * 1000 : 0, micOn: !!micStream, claimed });
    },
    now: () => performance.now(),
  };
})();
