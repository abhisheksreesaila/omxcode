// The page's microphone, on the audio thread (mojoui-audio.js loads it as an AudioWorklet module from /audio/worklet.js):
// the browser's samples (its own rate, usually 48 kHz) averaged down to 16 kHz mono, 16-bit, in frames of 20 ms (320 samples).
class MojouiMic extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = sampleRate / 16000;   // input samples per output sample
    this.frame = new Int16Array(320);
    this.n = 0;                       // samples in the frame so far
    this.acc = 0; this.weight = 0;    // the output sample being averaged
  }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i++) {
      this.acc += ch[i]; this.weight += 1;
      if (this.weight >= this.step) {  // the box over `step` input samples is complete
        const v = Math.max(-1, Math.min(1, this.acc / this.weight));
        this.frame[this.n++] = v < 0 ? v * 32768 : v * 32767;
        this.acc = 0; this.weight = 0;
        if (this.n === 320) { this.port.postMessage(this.frame.slice().buffer); this.n = 0; }
      }
    }
    return true;
  }
}
registerProcessor('mojoui-mic', MojouiMic);
