# Writes docs/gallery/index.html: a gallery of photos, one card per app (a picture, what it does, what it proves,
# where it runs, what's next). omxplorer is the star. Owner, 2026-10-31: "a card with an image and some details
# around it… the same theme as the cover page". Edit APPS below and run: pixi run python scripts/gallery_page.py
import html, pathlib

GH = "https://github.com/abhisheksreesaila/omxcode/tree/main/"

STAR = dict(
    name="omxplorer", kind="The product · data explorer",
    line="A spreadsheet, the video behind every row and the documents that explain it, on one page, on your own GPU.",
    proves=["63,344 real robot episodes (DROID, 13 labs) with 16.8M telemetry rows under them",
            "A question in words over every telemetry row in about 40 ms (JOIN LINKED)",
            "Video and telemetry on one time cursor; the window never waits"],
    runs=[("Linux", "ok"), ("Mac", "ci"), ("Web", "ok")], next="The web on WebGPU, so the work runs on the visitor's GPU",
    video="../img/clip-robots.mp4", poster="../img/clip-robots.jpg",
    shots=[("img/robots-drop.jpg", "The drop: F00118's video beside its gripper and joint telemetry"),
           ("img/robots-fleet.jpg", "63,344 episodes as one sheet"),
           ("img/robots-by-lab.jpg", "Success by lab, from the chart's sentence"),
           ("img/robots-ask.jpg", "Asked in words: 2,997 regrasped failures, the DROID paper linked")],
    src="examples/omxplorer", page="../omxplorer.html")

STAR2 = dict(
    name="omxconsole", kind="The second app · local AI",
    line="Your GPU as a private model server, with its admin console rebuilt in omxcode from framework parts only.",
    proves=["A 4,400-line JavaScript console rebuilt with no app CSS and no pixel nudges",
            "At least 99 % of the web's pixels equal the original, on all ten screens",
            "The same file draws native Linux and Mac windows"],
    runs=[("Linux", "ok"), ("Web", "ok"), ("Mac", "ci")], next="Real Mac hardware, then phones",
    shots=[("img/console-models-web.png", "Web: my models"), ("img/console-models-gtk.png", "Linux: the same screen, native widgets"),
           ("img/console-models-mac.png", "Mac, on GitHub's macOS runner"), ("img/console-overview-gtk.png", "A model's overview, live numbers"),
           ("img/console-overview-web-phone.png", "Web at phone size")],
    src="examples/console", page="https://omxlabs.tech/omxconsole/", cta="See omxconsole")

APPS = [
    dict(name="Dictate", kind="Speech to text",
         line="Talk, and words appear. Whisper runs on the GPU inside the app's own process: no file, no socket, no server.",
         proves="Final text 134 ms after the audio went in (median)", runs=[("Linux", "ok")],
         next="The Mac, then phones", shots=[("img/dictate-gtk.png", "Linux: five sentences, each timed")], src="examples/dictate"),
    dict(name="Sketch", kind="Drawing",
         line="Pressure ink with pan and zoom. Strokes taper with the pen; panning moves the kept ink, never redraws it.",
         proves="1,000 strokes, 3 ms per frame while panning (p95)", runs=[("Linux", "ok"), ("Web", "ok")],
         next="Tried with a real pen; the Mac", shots=[("img/sketch-gtk.png", "Linux"), ("img/sketch-web.png", "Web")], src="examples/sketch"),
    dict(name="Jot", kind="Notes in a database",
         line="Notes in a SQLite file, searched as you type, still there tomorrow. Quit mid-sentence and the words are saved.",
         proves="Search over 1M notes 2.6× faster than SQLite in the browser", runs=[("Linux", "ok"), ("Web", "ok")],
         next="The Mac's save dialog and file drop", shots=[("img/jot-gtk.png", "Linux"), ("img/jot-web.png", "Web")], src="examples/jot"),
    dict(name="Keeper", kind="Works when closed",
         line="Keeps a folder searchable with its window shut: a tray item, notifications, and a watcher on its own thread.",
         proves="New files searchable 2.5 ms after they're written, window closed", runs=[("Linux", "ok")],
         next="The Mac's menu bar", shots=[("img/keeper-gtk.png", "Linux: found with the window closed")], src="examples/keeper"),
    dict(name="JS widgets", kind="Bring your libraries",
         line="CodeMirror and ECharts from npm, inside a native app, restyled live by the theme. Agents can read and set them.",
         proves="0 content-policy violations; one mount per widget across rebuilds", runs=[("Linux", "ok"), ("Web", "ok")],
         next="JS canvases: Excalidraw-style editors", shots=[("img/widgets-web-dark.png", "Web, dark"), ("img/widgets-gtk-dark.png", "Linux, dark")],
         src="examples/widgets"),
    dict(name="Data Lens", kind="20 million points",
         line="A canvas the app paints itself, around native controls: how map and photo apps are built.",
         proves="20M points per 1080p frame in 1.5 ms on the GPU", runs=[("Linux", "ok"), ("Web", "ok"), ("Android", "emu")],
         next="Apple's GPU", shots=[("img/lens-linux.jpg", "Linux, 59 fps"), ("img/lens-web.jpg", "Web, streamed"),
                                    ("img/android-lens.jpg", "Android (CPU)")], src="examples/lens"),
    dict(name="Native controls", kind="Every platform's own widgets",
         line="Mojo drives GTK, AppKit, UIKit and Android views directly: no Swift, no Kotlin, the platform's own keyboard and screen reader.",
         proves="The same taps on Android and Linux end in the same state", runs=[("Linux", "ok"), ("Android", "emu"), ("iPhone", "builds")],
         next="Real phones", shots=[("img/android-todo.png", "Android"), ("img/android-gallery.png", "Android: the component gallery")],
         src="examples/todo"),
]

SOON = [("Ask your data", "Type a question; a model writes the chart and the query; the GPU runs it; omxcode draws it."),
        ("A JS canvas editor", "An Excalidraw-style editor as a widget on the web and in a native web view, the page logic in Mojo."),
        ("The web on WebGPU", "The same app in a browser with the work on the visitor's GPU.")]

RUN = {"ok": ("runs", "ok"), "ci": ("runs on CI Macs", "ok"), "emu": ("emulator", "am"), "builds": ("builds", "bl")}
e = html.escape


def chips(runs):
    return "".join(f'<span class="{RUN[s][1]}"><i></i><b>{e(p)}</b> {RUN[s][0]}</span>' for p, s in runs)


def thumbs(shots):
    if len(shots) < 2:
        return ""
    return '<div class="th">' + "".join(
        f'<button type="button" aria-label="{e(c)}"{" class=on" if i == 0 else ""} data-src="{e(s)}" data-cap="{e(c)}">'
        f'<img src="{e(s)}" alt="" loading="lazy"></button>' for i, (s, c) in enumerate(shots)) + "</div>"


def card(a):
    s0, c0 = a["shots"][0]
    return f'''<article class="card">
  <figure class="pic"><img src="{e(s0)}" alt="{e(a["name"])}: {e(c0)}" loading="lazy"></figure>
  <div class="info">
    <div class="kind">{e(a["kind"])}</div>
    <h3>{e(a["name"])}</h3>
    <p class="line">{e(a["line"])}</p>
    <div class="plats">{chips(a["runs"])}</div>
  </div>
</article>'''


def star(a):
    vid = "video" in a
    first = f'<button type="button" class="on" data-video aria-label="Play the story"><img src="{e(a["poster"])}" alt=""><em>▶</em></button>' if vid else ""
    th = '<div class="th">' + first + "".join(
        f'<button type="button" aria-label="{e(c)}"{" class=on" if (not vid and i == 0) else ""} data-src="{e(s)}" data-cap="{e(c)}"><img src="{e(s)}" alt="" loading="lazy"></button>'
        for i, (s, c) in enumerate(a["shots"])) + "</div>"
    if vid:
        pic = f'''<video src="{e(a["video"])}" poster="{e(a["poster"])}" muted loop playsinline autoplay preload="metadata" aria-label="omxplorer: why did the robot drop it?"></video>
      <img hidden alt=""><figcaption>Why did the robot drop it? · real DROID data, Liquid dark</figcaption>'''
    else:
        s0, c0 = a["shots"][0]
        pic = f'<img src="{e(s0)}" alt="{e(a["name"])}: {e(c0)}"><figcaption>{e(c0)}</figcaption>'
    proves = "".join(f"<li>{e(p)}</li>" for p in a["proves"])
    return f'''<article class="card star">
  <div class="media">
    <figure class="pic">{pic}</figure>
    {th}
  </div>
  <div class="info">
    <div class="kind">{e(a["kind"])}</div>
    <h3>{e(a["name"])}</h3>
    <p class="line">{e(a["line"])}</p>
    <ul class="pl">{proves}</ul>
    <div class="plats">{chips(a["runs"])}</div>
    <p class="next"><span>Next</span>{e(a["next"])}</p>
    <div class="links"><a class="cta" href="{a["page"]}">{e(a.get("cta", "See omxplorer"))}</a><a class="src" href="{GH}{a["src"]}">{e(a["src"])}</a></div>
  </div>
</article>'''


PAGE = '''<!doctype html>
<html lang="en" class="oq-root oq-night oq-family-dev">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>omxcode · gallery</title>
<meta name="description" content="What omxcode builds today: omxplorer and ten apps, each with a picture, what it proves, where it runs and what's next.">
<meta name="theme-color" content="#000000">
<link rel="icon" href="../img/logo.svg" type="image/svg+xml">
<!-- generated by scripts/gallery_page.py; edit it there -->
<link rel="stylesheet" href="../omxqua/src/fonts.css">
<link rel="stylesheet" href="../omxqua/src/tokens.css">
<link rel="stylesheet" href="../omxqua/src/components.css">
<link rel="stylesheet" href="../site.css">
<style>
:root { --h2: clamp(30px, 3.6vw, 46px); --lede: clamp(17px, 1.6vw, 20px); }
section { padding: 64px 24px 96px; }
.lnav .links { display: flex; gap: 4px; justify-self: center; padding: 4px; border-radius: 999px; background: var(--oq-surface-1); box-shadow: 0 0 0 1px var(--line); }
.lnav .links a { color: var(--ink2); text-decoration: none; font: 500 13.5px var(--sans); padding: 8px 13px; border-radius: 999px; }
.lnav .links a:hover, .lnav .links a.on { color: var(--ink); background: rgb(var(--oq-state) / .1); }
.cta { height: 44px; padding: 0 22px; font-size: 15.5px; }
.head h1 { font-size: clamp(32px, 3.5vw, 48px); line-height: 1.02; letter-spacing: -.045em; }
.head .lede { max-width: 640px; }
.grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; margin-top: 40px; }
.card { background: var(--oq-surface-1); border-radius: 22px; overflow: hidden; box-shadow: 0 0 0 1px var(--line); display: flex; flex-direction: column; min-width: 0; }
.pic { position: relative; margin: 0; aspect-ratio: 16 / 10; background: var(--oq-surface-2); overflow: hidden; }
.pic img, .pic video { width: 100%; height: 100%; object-fit: cover; object-position: top left; display: block; }
.pic figcaption { position: absolute; left: 10px; bottom: 10px; font: 500 12px var(--mono); color: #fff; background: rgb(0 0 0 / .62); padding: 4px 9px; border-radius: 999px; max-width: calc(100% - 20px); }
.th { display: flex; gap: 6px; padding: 10px 14px 0; overflow-x: auto; }
.th button { position: relative; flex: none; width: 64px; height: 44px; padding: 0; border: 0; border-radius: 8px; overflow: hidden; cursor: pointer; background: var(--oq-surface-2); box-shadow: 0 0 0 1px var(--line); opacity: .6; transition: opacity .15s, box-shadow .15s; }
.th button img { width: 100%; height: 100%; object-fit: cover; object-position: top left; display: block; }
.th button em { position: absolute; inset: 0; display: grid; place-items: center; font-style: normal; color: #fff; text-shadow: 0 1px 4px #000; }
.th button:hover { opacity: .9; } .th button.on { opacity: 1; box-shadow: 0 0 0 2px var(--word); }
.info { padding: 18px 20px 20px; display: flex; flex-direction: column; gap: 10px; flex: 1; }
.kind { font: 600 11.5px var(--mono); letter-spacing: .12em; text-transform: uppercase; color: var(--word); }
.info h3 { font-size: 22px; }
.line { margin: 0; font-size: 15.5px; line-height: 1.5; color: var(--ink2); }
.proves, .next { margin: 0; font-size: 14.5px; line-height: 1.45; color: var(--ink); display: flex; gap: 10px; }
.proves span, .next span { flex: none; width: 52px; font: 600 11px/1.9 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--ink2); }
.next { color: var(--ink2); }
.plats { display: flex; flex-wrap: wrap; gap: 6px; }
.plats span { display: inline-flex; align-items: center; gap: 6px; font: 500 12px var(--mono); color: var(--ink2); padding: 4px 10px; border-radius: 999px; box-shadow: inset 0 0 0 1px var(--line); }
.plats b { color: var(--ink); font-weight: 600; font-family: var(--sans); }
.plats i { width: 7px; height: 7px; border-radius: 50%; background: var(--oq-ok); } .plats .bl i { background: var(--oq-info); } .plats .am i { background: var(--soon); }
.src { margin-top: auto; font: 12px var(--mono); color: var(--ink2); text-decoration: none; } .src:hover { color: var(--ink); text-decoration: underline; }
.src::before { content: "↳ "; opacity: .6; }
.star { grid-column: 1 / -1; display: grid; grid-template-columns: minmax(0, 7fr) minmax(0, 4fr); box-shadow: 0 0 0 1px color-mix(in srgb, var(--word) 45%, var(--line)), var(--oq-shadow-2); }
.star .media { display: flex; flex-direction: column; padding-bottom: 14px; min-width: 0; }
.star .pic { aspect-ratio: 16 / 10; }
.star .info { padding: 28px 28px 26px; gap: 14px; }
.star h3 { font-size: 34px; letter-spacing: -.035em; }
.star .line { font-size: 17px; color: var(--ink); }
.pl { margin: 0; padding: 0; list-style: none; display: grid; gap: 8px; }
.pl li { font-size: 14.5px; line-height: 1.45; color: var(--ink2); padding-left: 18px; position: relative; }
.pl li::before { content: ""; position: absolute; left: 0; top: .55em; width: 7px; height: 7px; border-radius: 50%; background: var(--oq-ok); }
.links { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; margin-top: auto; } .links .src { margin-top: 0; }
.more2 { margin-top: 64px; } .sub { margin: 10px 0 0; color: var(--ink2); font-size: 16px; max-width: 640px; }
.photos { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; margin-top: 24px; }
.mini .pic { aspect-ratio: 4 / 3; } .mini .info { padding: 14px 16px 16px; gap: 6px; } .mini h3 { font-size: 18px; }
.mini .line { font-size: 14px; } .mini .kind { font-size: 10.5px; }
.card.star + .card.star { margin-top: 0; }
.soon { margin-top: 56px; } .soon h2 { font-size: 26px; letter-spacing: -.03em; }
.sgrid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px; margin-top: 18px; }
.sgrid div { border-radius: 18px; padding: 18px 20px; border: 1.5px dashed color-mix(in srgb, var(--soon) 55%, transparent); }
.sgrid b { display: block; font-size: 16px; } .sgrid p { margin: 6px 0 0; font-size: 14px; line-height: 1.5; color: var(--ink2); }
.sgrid i { font: 600 11px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--soon); font-style: normal; }
footer { padding: 32px 24px 48px; box-shadow: 0 -1px 0 var(--line); font: 13px var(--mono); color: var(--ink2); }
footer a { color: var(--ink2); }
@media (max-width: 860px) {
  .lnav .links { display: none; } .lnav { grid-template-columns: 1fr auto; }
  .grid, .sgrid { grid-template-columns: minmax(0, 1fr); } .photos { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .star { grid-template-columns: minmax(0, 1fr); } .star .info { padding: 20px; } .star h3 { font-size: 28px; }
}
</style>
</head>
<body>
<nav class="lnav">
  <a class="brand" href="../"><span class="mark" aria-hidden="true"><svg class="snap" viewBox="0 0 24 24"><path class="p1" d="m6 8-4 4 4 4"/><path class="p2" d="m14.5 4-5 16"/><path class="p3" d="m18 16 4-4-4-4"/><circle class="k" cx="8" cy="12" r="1"/><circle class="k" cx="16" cy="12" r="1"/></svg></span>omxcode</a>
  <div class="links"><a href="../#vision">Vision</a><a href="../#roadmap">Roadmap</a><a class="on" href="./">Gallery</a><a href="../components.html">Components</a><a href="../#numbers">Numbers</a></div>
  <div class="right"><a class="cta" href="../#get">Download</a></div>
</nav>
<main>
<section><div class="wrap">
  <div class="head">
    <div class="eyebrow">Gallery</div>
    <h1>Two apps, and what else it builds.</h1>
    <p class="lede">omxplorer and omxconsole are the products. The rest are smaller apps, each one Mojo codebase, that show what the framework can do.</p>
  </div>
  <div class="grid">
STAR_CARD
  </div>
  <div class="more2">
    <div class="eyebrow">More, built from the same parts</div>
    <p class="sub">Smaller apps that show it can be done: speech, ink, a database, a background app, JavaScript libraries, a GPU canvas, phone controls.</p>
    <div class="photos">
CARDS
    </div>
  </div>
  <div class="soon">
    <div class="eyebrow">Coming next</div>
    <div class="sgrid">SOON</div>
  </div>
</div></section>
</main>
<footer><div class="wrap">Numbers from scripts on one Linux machine with an RTX 3090; Mac results from GitHub's macOS runners. "Runs" means a script drives the app there today. <a href="https://github.com/abhisheksreesaila/omxcode/blob/main/docs/benchmarks.md">How we measured</a> · <a href="../">Back to omxcode</a></div></footer>
<script>
document.querySelectorAll(".card").forEach(card => {
  const pic = card.querySelector(".pic"), img = pic.querySelector("img"), vid = pic.querySelector("video"), cap = pic.querySelector("figcaption");
  if (!cap) return;
  const first = cap.textContent;
  card.querySelectorAll(".th button").forEach(b => b.addEventListener("click", () => {
    card.querySelectorAll(".th button").forEach(x => x.classList.toggle("on", x === b));
    if (b.hasAttribute("data-video")) { img.hidden = true; vid.hidden = false; vid.play().catch(() => {}); cap.textContent = first; return; }
    if (vid) { vid.pause(); vid.hidden = true; img.hidden = false; }
    img.src = b.dataset.src; img.alt = b.dataset.cap; cap.textContent = b.dataset.cap;
  }));
});
if (matchMedia("(prefers-reduced-motion: reduce)").matches) document.querySelectorAll("video[autoplay]").forEach(v => { v.removeAttribute("autoplay"); v.pause(); });
</script>
</body>
</html>
'''

out = (PAGE.replace("STAR_CARD", star(STAR) + "\n" + star(STAR2)).replace("CARDS", "\n".join(card(a) for a in APPS))
       .replace("SOON", "".join(f"<div><i>soon</i><b>{e(t)}</b><p>{e(p)}</p></div>" for t, p in SOON)))
p = pathlib.Path(__file__).resolve().parent.parent / "docs/gallery/index.html"
p.write_text(out)
print("wrote", p)
