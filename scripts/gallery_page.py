# Writes docs/gallery/index.html: a gallery of photos, one card per app (a picture, what it does, what it proves,
# where it runs, what's next). omxplorer and omxconsole are the two flagships (STARS). Owner, 2026-10-31: "a card with an image and some details
# around it… the same theme as the cover page". Edit APPS below and run: pixi run python scripts/gallery_page.py
import html, pathlib

GH = "https://github.com/abhisheksreesaila/omxcode/tree/main/"
REL = "https://github.com/abhisheksreesaila/omxcode/releases/download/"
# goal 53 (owner, 2026-11-05: "it goes into the galleries so you have to provide a link"; no web version): every card in
# the grid links its downloads, each one run before it's listed (Linux: unpacked and started with no Mojo or pixi,
# scripts/bare_run.py; Mac: on GitHub's Mac runners, scripts/mac-ci). An app with no download waits under Coming next.
GET = {"Linux": ("gallery-apps", "{app}-linux-x86_64.tar.gz"), "Mac": ("gallery-apps", "{app}-mac-arm64.zip")}


def download_url(app, plat):
    tag, name = GET[plat]
    return REL + tag + "/" + name.format(app=app)

STAR = dict(
    name="omxplorer", kind="The product · data explorer",
    line="A spreadsheet, the video behind every row and the documents that explain it, on one page, on your own GPU.",
    video="../img/clip-robots.mp4", poster="../img/clip-robots.jpg",
    shots=[("img/robots-drop.jpg", "The drop: F00118's video beside its gripper and joint telemetry"),
           ("img/robots-fleet.jpg", "63,344 episodes as one sheet"),
           ("img/robots-by-lab.jpg", "Success by lab, from the chart's sentence"),
           ("img/robots-ask.jpg", "Asked in words: 2,997 regrasped failures, the DROID paper linked")],
    src="examples/omxplorer", page="../omxplorer.html", cta="See omxplorer",
    get=[("Linux", REL + "linux-app/omxplorer-linux-x86_64.tar.gz", "x86_64 · GTK 4"),
         ("Mac", REL + "mac-app/omxplorer-mac-gpu.zip", "Apple Silicon · macOS 26")])
# the second flagship (owner, 2026-11-06: "it needs to have its own cover page… this is 2nd flagship product"): a desktop
# app around Modular's max serve, all omxcode; downloads from gallery-apps, each run before it's listed (goal 55 M5, M6).
# No speed in its pictures or captions (docs/lessons.md, D-4762).
CONSOLE = dict(
    name="omxconsole", app="omxconsole", kind="The second flagship · local models on MAX",
    line="Find a model on Hugging Face, download it and serve it on your own GPU through Modular's MAX: one OpenAI-style endpoint with a key per app, and benchmarks. All omxcode.",
    shots=[("img/omxconsole-find.png", "Add a model: the MAX catalog and Hugging Face, each result checked against this GPU's memory"),
           ("img/omxconsole-ready.png", "Ready after the model answered a first question: its endpoint and a curl line"),
           ("img/omxconsole-models.png", "My models"),
           ("img/omxconsole-keys.png", "Keys: one per app, shown by prefix")],
    src="examples/console", page="../omxconsole.html", cta="See omxconsole",
    needs="Needs MAX installed (docs.modular.com/max/packages). Mac: it opens and starts its service on GitHub's Mac runners; no model has been served on a Mac yet.",
    get=[("Linux", download_url("omxconsole", "Linux"), "x86_64 · GTK 4"),
         ("Mac", download_url("omxconsole", "Mac"), "Apple Silicon · macOS 15 or later")])
STARS = [STAR, CONSOLE]

APPS = [
    dict(name="Sketch", app="sketch", kind="Drawing",
         line="Pressure ink with pan and zoom. Strokes taper with the pen; panning moves the kept ink, never redraws it.",
         runs=[("Linux", "ok"), ("Mac", "ci")], get=["Linux", "Mac"],
         shots=[("img/sketch-gtk.png", "Linux")], src="examples/sketch"),
    dict(name="Jot", app="jot", kind="Notes in a database",
         line="Notes in a SQLite file, searched as you type, still there tomorrow. Quit mid-sentence and the words are saved.",
         runs=[("Linux", "ok"), ("Mac", "ci")], get=["Linux", "Mac"],
         shots=[("img/jot-gtk.png", "Linux")], src="examples/jot"),
    dict(name="Keeper", app="keeper", kind="Works when closed",
         line="Keeps a folder searchable with its window shut: a tray item, notifications, and a watcher on its own thread.",
         # (Mac: its FSEvents watcher fails to start on GitHub's Macs and there's no menu-bar item yet, so it
         # doesn't keep working when closed there; goal 45's Mac half, unfinished)
         runs=[("Linux", "ok"), ("Mac", "soon")], get=["Linux"],
         shots=[("img/keeper-gtk.png", "Linux: found with the window closed")], src="examples/keeper"),
    dict(name="Data Lens", app="lens", kind="20 million points",
         line="A canvas the app paints itself, around native controls: how map and photo apps are built.",
         runs=[("Linux", "ok"), ("Mac", "ci"), ("Android", "emu")], get=["Linux", "Mac"],
         shots=[("img/lens-linux.jpg", "Linux, 59 fps"), ("img/android-lens.jpg", "Android (CPU)")], src="examples/lens"),
    dict(name="Native controls", app="todo", kind="Every platform's own widgets",
         line="A to-do list in GTK, AppKit, UIKit and Android's own controls, driven by Mojo: no Swift, no Kotlin.",
         # (Mac: runs on GitHub's Macs, but the title wraps a letter short ("Tod / o"): its download after that fix)
         runs=[("Linux", "ok"), ("Mac", "soon"), ("Android", "emu"), ("iPhone", "builds")], get=["Linux"],
         shots=[("img/android-todo.png", "Android"), ("img/android-gallery.png", "Android: the component gallery")],
         src="examples/todo"),
    dict(name="JS widgets", app="widgets", kind="JavaScript, first class",
         line="CodeMirror and ECharts from npm inside a native Mojo app: the JS draws, Mojo keeps every line of state, the theme restyles them live and agents can read and set them.",
         runs=[("Linux", "ok"), ("Mac", "ci")], get=["Linux", "Mac"], needs="Linux: needs WebKitGTK 6.0",
         shots=[("img/widgets-gtk-dark.png", "Linux, dark"), ("img/widgets-gtk-light.png", "Linux, light")],
         src="examples/widgets"),
]

# no web builds in the showcase (owner, 2026-11-05); these come into the grid once they have a download
SOON = [("Agent chat", "Ask for a map, get a map: an agent answers with native screens. A download once it carries its agent inside."),
        ("Dictate", "Talk, and words appear, Whisper on the GPU in the app's own process. A download once the model ships with it."),
        ("Ask your data", "Type a question; a model writes the chart and the query; the GPU runs it; omxcode draws it.")]

RUN = {"soon": ("coming", "am"), "ok": ("runs", "ok"), "ci": ("runs on CI Macs", "ok"), "emu": ("emulator", "am"), "builds": ("builds", "bl")}
e = html.escape


def chips(runs):
    return "".join(f'<span class="{RUN[s][1]}"><i></i><b>{e(p)}</b> {RUN[s][0]}</span>' for p, s in runs)


def thumbs(shots):
    if len(shots) < 2:
        return ""
    return '<div class="th">' + "".join(
        f'<button type="button" aria-label="{e(c)}"{" class=on" if i == 0 else ""} data-src="{e(s)}" data-cap="{e(c)}">'
        f'<img src="{e(s)}" alt="" loading="lazy"></button>' for i, (s, c) in enumerate(shots)) + "</div>"


def gets(a):
    """The card's download buttons: (platform, url, note) for the star, platform names for the rest."""
    items = [(g, download_url(a["app"], g), "") if isinstance(g, str) else g for g in a["get"]]
    return '<div class="get">' + "".join(
        f'<a class="dl" href="{e(u)}" download><b>Download for {e(pl)}</b>{f"<span>{e(n)}</span>" if n else ""}</a>'
        for pl, u, n in items) + "</div>"


def card(a):
    s0, c0 = a["shots"][0]
    return f'''<article class="card" id="{e(a["name"].lower().replace(" ", "-"))}">
  <figure class="pic"><img src="{e(s0)}" alt="{e(a["name"])}: {e(c0)}" loading="lazy"></figure>
  <div class="info">
    <div class="kind">{e(a["kind"])}</div>
    <h3>{e(a["name"])}</h3>
    <p class="line">{e(a["line"])}</p>
    <div class="plats">{chips(a["runs"])}</div>
    {gets(a)}{f'<p class="needs">{e(a["needs"])}</p>' if a.get("needs") else ""}
    <a class="src" href="{GH}{a["src"]}">{e(a["src"])}</a>
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
    # an introduction only: the app's own page carries the details and the downloads (owner, 2026-11-02)
    src = "" if a["page"] == GH + a["src"] else f'<a class="src" href="{GH}{a["src"]}">{e(a["src"])}</a>'
    needs = f'<p class="needs">{e(a["needs"])}</p>' if a.get("needs") else ""
    links = gets(a) + needs + f'<div class="links"><a class="cta" href="{a["page"]}">{e(a["cta"])}</a>{src}</div>'
    return f'''<article class="card star" id="{e(a["name"])}">
  <div class="media">
    <figure class="pic">{pic}</figure>
    {th}
  </div>
  <div class="info">
    <div class="kind">{e(a["kind"])}</div>
    <h3>{e(a["name"])}</h3>
    <p class="line">{e(a["line"])}</p>
    {links}
  </div>
</article>'''


PAGE = '''<!doctype html>
<html lang="en" class="oq-root oq-night oq-family-dev">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>omxcode · gallery</title>
<meta name="description" content="What omxcode builds today: omxplorer and the apps built with omxcode, each with a picture, where it runs and its Linux and Mac downloads.">
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
.get { display: flex; flex-wrap: wrap; gap: 8px; margin-top: auto; }
.dl { display: inline-flex; flex-direction: column; gap: 1px; padding: 8px 14px; border-radius: 12px; text-decoration: none; color: var(--ink); background: rgb(var(--oq-state) / .06); box-shadow: inset 0 0 0 1px var(--line); transition: background .15s; }
.dl:hover { background: rgb(var(--oq-state) / .12); } .dl b { font: 600 13.5px var(--sans); } .dl b::before { content: "↓ "; color: var(--word); }
.dl span { font: 11.5px var(--mono); color: var(--ink2); }
.needs { margin: 0; font: 12px var(--mono); color: var(--ink2); }
.src { font: 12px var(--mono); color: var(--ink2); text-decoration: none; } .src:hover { color: var(--ink); text-decoration: underline; }
.src::before { content: "↳ "; opacity: .6; }
.star { grid-column: 1 / -1; display: grid; grid-template-columns: minmax(0, 7fr) minmax(0, 4fr); box-shadow: 0 0 0 1px color-mix(in srgb, var(--word) 45%, var(--line)), var(--oq-shadow-2); }
.star .media { display: flex; flex-direction: column; padding-bottom: 14px; min-width: 0; }
.star .pic { aspect-ratio: 16 / 10; }
.star .info { padding: 28px 28px 26px; gap: 14px; }
.star h3 { font-size: 34px; letter-spacing: -.035em; }
.star .line { font-size: 17px; color: var(--ink); }
.links { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; margin-top: auto; } .links .src { margin-top: 0; }
.more2 { margin-top: 64px; } .sub { margin: 10px 0 0; color: var(--ink2); font-size: 16px; max-width: 640px; }
.photos { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; margin-top: 24px; }
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
  <div class="right"><a class="cta" href="../#get">Build your own</a></div>
</nav>
<main>
<section><div class="wrap">
  <div class="head">
    <div class="eyebrow">Gallery</div>
    <h1>omxplorer, and what else it builds.</h1>
    <p class="lede">Two flagships: omxplorer, the data explorer, and omxconsole, local models on Modular's MAX. The rest are smaller apps, each one Mojo codebase, that show what the framework can do. Every one downloads for Linux; most for the Mac too.</p>
  </div>
  <div class="grid">
STAR_CARD
  </div>
  <div class="more2">
    <div class="eyebrow">More, built from the same parts</div>
    <p class="sub">Ink, a database, a background app, a GPU canvas, every platform's own controls, JavaScript libraries as guests. Native apps, no web builds.</p>
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
<footer><div class="wrap">Numbers from scripts on one Linux machine with an RTX 3090; Mac results from GitHub's macOS runners. "Runs" means a script drives the app there today. Downloads are pre-releases: the Mac apps aren't notarised yet (if macOS refuses one, run <code>xattr -dr com.apple.quarantine</code> on it). <a href="https://github.com/abhisheksreesaila/omxcode/blob/main/docs/benchmarks.md">How we measured</a> · <a href="../">Back to omxcode</a></div></footer>
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

out = (PAGE.replace("STAR_CARD", "\n".join(star(x) for x in STARS)).replace("CARDS", "\n".join(card(a) for a in APPS))
       .replace("SOON", "".join(f"<div><i>soon</i><b>{e(t)}</b><p>{e(p)}</p></div>" for t, p in SOON)))
p = pathlib.Path(__file__).resolve().parent.parent / "docs/gallery/index.html"
p.write_text(out)
print("wrote", p)
