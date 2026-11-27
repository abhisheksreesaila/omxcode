if (location.hostname === "abhisheksreesaila.github.io") { location.replace("https://omxlabs.tech" + location.pathname + location.search + location.hash); }
// Shared by the site's pages: words that rise, sections that reveal, numbers that count, the nav's sliding pill,
// the product that unfolds, copy buttons, and scenes that play only while they're on screen (window.omx.scene).
(() => {
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  window.omx = { $, $$, reduce, esc };

  // hero words rise once, staggered
  $$("[data-words]").forEach(el => { const step = +el.dataset.step, d0 = +el.dataset.d0, cls = el.classList.contains("two") ? ' class="two"' : "";
    const html = el.textContent.trim().split(" ").map((w, i) => `<span${cls} style="animation-delay:${d0 + i * step}ms">${esc(w)}</span>`).join(" ");
    if (el.matches("h1")) el.innerHTML = html; else el.outerHTML = html; });

  // sections rise as they enter; numbers count up once (the real value is in the HTML, so no-JS readers see it)
  const count = el => $$("[data-count]", el).forEach(b => { if (reduce) return; const to = +b.dataset.count, dec = +(b.dataset.dec || 0), t0 = performance.now(), dur = 1400;
    const step = t => { const p = Math.min(1, (t - t0) / dur), v = to * (1 - Math.pow(1 - p, 3)); b.textContent = v.toFixed(dec); if (p < 1) requestAnimationFrame(step); };
    requestAnimationFrame(step); });
  const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add("in"); count(e.target); io.unobserve(e.target); } }), { threshold: .2 });
  window.omx.reveal = root => $$(".rv", root).forEach(el => reduce ? el.classList.add("in") : io.observe(el));
  window.omx.reveal(document);

  // the hero diagram builds once
  $$(".iso [data-o]").forEach(g => reduce ? g.classList.add("on") : setTimeout(() => g.classList.add("on"), 700 + 170 * +g.dataset.o));

  // a scene: an async function(step) run in a loop while its element is on screen; step(ms) resolves after ms,
  // or never while the scene is off screen (it picks up where it was when it comes back)
  window.omx.scene = (el, play) => {
    let visible = false, wake = null;
    new IntersectionObserver(es => es.forEach(e => { visible = e.isIntersecting; if (visible && wake) { const w = wake; wake = null; w(); } }), { threshold: .35 }).observe(el);
    const step = ms => new Promise(res => setTimeout(() => visible ? res() : (wake = res), ms));
    const waitVisible = () => visible ? Promise.resolve() : new Promise(res => wake = res);
    (async () => { await waitVisible(); for (;;) await play(step); })();
  };

  // the nav: the section you're in is selected; a click selects at once and holds until the scroll lands
  const ind = $(".lnav .ind"), links = $$(".lnav .pill a").filter(a => a.hash);
  let cur = null, pinned = null, pinT;
  function select(a) {
    if (!ind || a === cur) return;
    links.forEach(l => { l.classList.toggle("on", l === a); l === a ? l.setAttribute("aria-current", "location") : l.removeAttribute("aria-current"); });
    if (!a) { ind.style.opacity = 0; cur = null; return; }
    ind.classList.toggle("still", !cur || reduce);
    ind.style.width = a.offsetWidth + "px"; ind.style.transform = `translateX(${a.offsetLeft}px)`; ind.style.opacity = 1;
    if (!cur && !reduce) { void ind.offsetWidth; ind.classList.remove("still"); }
    cur = a;
  }
  links.forEach(a => a.addEventListener("click", () => { select(a); pinned = a; clearTimeout(pinT);
    pinT = setTimeout(() => { pinned = null; onScroll(); }, "onscrollend" in window ? 3000 : 1200); }));
  addEventListener("scrollend", () => { if (pinned) { clearTimeout(pinT); pinned = null; onScroll(); } });
  let raf;
  const scrollers = [];
  window.omx.onScroll = f => { scrollers.push(f); f(innerHeight); };
  function onScroll() {
    const vh = innerHeight;
    $$("[data-unfold]").forEach(s => { const r = s.getBoundingClientRect(), p = Math.min(1, Math.max(0, (vh - r.top) / r.height)), k = reduce ? 1 : Math.min(1, p * 1.6), f = $(".frame", s);
      f.style.transform = `scale(${0.82 + 0.18 * k})`; f.style.borderRadius = `${40 - 26 * k}px`; });
    scrollers.forEach(f => f(vh));
    if (!pinned && links.length) select(links.filter(a => { const t = $(a.hash); return t && t.getBoundingClientRect().top <= vh * .4; }).pop());
  }
  addEventListener("scroll", () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(onScroll); }, { passive: true });
  addEventListener("resize", () => { const a = cur; cur = null; ind?.classList.add("still"); select(a); onScroll(); }); onScroll();

  // copy buttons
  document.addEventListener("click", e => { const b = e.target.closest("[data-copy]"); if (!b) return;
    navigator.clipboard?.writeText($(b.dataset.copy).textContent).then(() => { b.textContent = "copied"; setTimeout(() => b.textContent = "copy", 1600); }); });

  // two-way switches (Today | Coming soon): the knob slides on the island spring
  window.omx.seg = (seg, onPick) => {
    const knob = $(".knob", seg), bs = $$("button", seg);
    const pick = (i, user) => { bs.forEach((b, j) => { b.classList.toggle("on", i === j); b.setAttribute("aria-pressed", i === j); });
      knob.style.width = bs[i].offsetWidth + "px"; knob.style.transform = `translateX(${bs[i].offsetLeft - 3}px)`; onPick(i, user); };
    bs.forEach((b, i) => b.addEventListener("click", () => pick(i, true)));
    addEventListener("resize", () => { const i = bs.findIndex(b => b.classList.contains("on")); if (i >= 0) pick(i, false); });
    return pick;
  };

  // Unified omxlabs suite strip across omxplorer, omxcore, omxcode, omxqua, Gallery
  if (!document.querySelector(".ox-bar")) {
    const p = location.pathname;
    const isGal = /\/gallery(\/|$)/.test(location.pathname);
  const BASE = location.pathname.startsWith("/omxcode/") ? "" : "https://omxlabs.tech";
  const items = [
    { u: BASE + "/", n: "omxplorer", r: "", c: "#30d158", on: false },
    null,
    { u: BASE + "/omxcore/", n: "omxcore", r: "Engine", c: "#4aa8ff", on: false },
    { u: BASE + "/omxcode/", n: "omxcode", r: "Framework", c: "#ff5d6c", on: !isGal },
    { u: BASE + "/omxqua/", n: "omxqua", r: "Design", c: "#c084fc", on: false },
    null,
    { u: BASE + "/omxcode/gallery/", n: "Gallery", r: "", c: "#ff9f40", on: isGal },
  ];
    const bar = document.createElement("div");
    bar.className = "ox-bar";
    bar.setAttribute("role", "navigation");
    bar.setAttribute("aria-label", "omxlabs suite");
    bar.innerHTML =
      `<a class="ox-bar-brand" href="${BASE}/"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 2v7.527a2 2 0 0 1-.211.896L4.72 20.55a1 1 0 0 0 .9 1.45h12.76a1 1 0 0 0 .9-1.45l-5.069-10.127A2 2 0 0 1 14 9.527V2"/><path d="M8.5 2h7"/><path d="M7 16h10"/></svg>omxlabs</a>` +
      `<div class="ox-bar-links">` + items.map(it => it ? `<a href="${it.u}" style="--ox:${it.c}"${it.on ? ' class="on" aria-current="page"' : ""}><i></i>${it.n}${it.r ? `<em>${it.r}</em>` : ""}</a>` : `<span class="ox-bar-sep" aria-hidden="true"></span>`).join("") + `</div>` +
      `<a class="ox-bar-gh" href="https://github.com/abhisheksreesaila/omxcode">GitHub ↗</a>`;
    document.body.prepend(bar);
  }
})();
