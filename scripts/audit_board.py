"""The haunted audit board: docs/audits/*.json -> docs/audits/board.html (one self-contained page).

Each audit JSON lists an app's features (have / partial / missing). This groups every gap into the framework
piece that would close it, so the page shows which pieces unblock the most apps. Run: python3 scripts/audit_board.py
"""
import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDITS = os.path.join(ROOT, "docs", "audits")

# Framework pieces, first match wins (feature + gap text, lower case).
PIECES = [
    ("scope", "🚫 Not omxcode's job", r"out of scope|stays in fh-saas|server side is fh-saas"),
    ("camera", "📷 Camera + on-device vision", r"camera|detector|tracking boxes"),
    ("sound", "🔊 Sound out + voice", r"sound|speaker|audio|voice|tts|tune|waveform|stanza on a tight|chipmunk|speechsynth"),
    ("auth", "🪪 Sign-in, secrets, crypto", r"sign-in|oauth|tenant|passcode|keychain|secretstore|crypto|aes|auth bridge|touch id"),
    ("https", "🔐 HTTPS + network", r"https|tls|http on uikit|libcurl|http\.download|quiltt|syncs with the server|deploy recipe"),
    ("canvas", "🖼️ Canvas objects, Markdown, mind maps", r"objectlayer|connectors|markdown|mind ?map|ink|anchor|painter\.path|svg"),
    ("charts", "📊 More charts", r"donut|sankey|flow|calendar chart|crossfilter|chartview\.lines|line chart"),
    ("motion", "🃏 Sheets, drawers, gestures, motion", r"sheet|drawer|swipe|spring|transition|pager|scrubber|slider|scroll\(reveal|zoom_to|drag a note"),
    ("phone", "📱 Phones + Mac for real", r"uikit|android|iphone|phone|pwa|manifest|home screen|deep link|touch|tab ?bar|48 px"),
    ("editing", "✏️ Editing basics", r"undo|history|commandpalette|omnibar|goal 44|icon picker|three-way|outside writ|changed outside"),
    ("hooks", "🧰 Platform hooks", r"fullscreen|keep_awake|prefs|shortcut|clipboard|notification|print|zip|process|one instance|open_url|argv|crossfade|font|pdfsource|theme|omxqua"),
    ("ship", "🚚 Shipping", r"installer|notariz|release ci|soak|bundle"),
]

# Features the keywords put in the wrong piece (feature text prefix -> piece), checked by eye against the audits.
OVERRIDES = {"Deep links": "phone", "Saves each app's state": "phone", "Server downloads the PDF": "https",
             "Big Start N": "hooks", "Cross-filter": "charts", "Personal (scrapbook)": "hooks", "Kiosk": "hooks",
             "Settings remembered per device": "hooks", "Kids talk back": "sound", "Runs on the Pixel Tablet": "phone",
             "Runs ~3 hours": "ship", "Insert pictures": "hooks", "Markdown + assets ZIP": "hooks", "Tab bar": "phone",
             "Mac: Touch ID": "phone"}

APPS = {"personalnote": ("📝", "Personal Note"), "finxplorer": ("💰", "finxplorer 2026"),
        "appcol": ("🧮", "appcol"), "halloween": ("🎃", "Pumpkin Greeter")}
ETAS = ["this week", "Nov 2026", "Dec 2026", "2027"]


def piece_of(f):
    for prefix, key in OVERRIDES.items():
        if f["feature"].startswith(prefix):
            return key
    text = (f["feature"] + " " + (f.get("gap") or "")).lower()
    for key, _, rx in PIECES:
        if re.search(rx, text):
            return key
    return "hooks"


def main():
    apps = []
    for path in sorted(glob.glob(os.path.join(AUDITS, "*.json"))):
        d = json.load(open(path))
        for f in d["features"]:
            f["piece"] = piece_of(f) if f["status"] != "have" else None
        apps.append(d)
    order = {k: i for i, k in enumerate(APPS)}
    apps.sort(key=lambda d: order.get(d["slug"], 99))
    data = {"apps": apps, "pieces": [{"key": k, "label": l} for k, l, _ in PIECES],
            "appmeta": {k: {"icon": i, "name": n} for k, (i, n) in APPS.items()}, "etas": ETAS}
    html = TEMPLATE.replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    out = os.path.join(AUDITS, "board.html")
    open(out, "w").write(html)
    print(out)


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>🎃 The Haunted Audit · omxcode</title>
<style>
:root{--bg:#150a24;--s1:#211037;--s2:#2c1748;--line:#3d2463;--ink:#f3ecff;--mute:#b6a6d3;--pump:#ff7a1a;
--have:#6fdc8c;--part:#ffb547;--miss:#ff5c7a;--a1:#ff7a1a;--a2:#5fd4c0;--a3:#b99cff;--a4:#ffd166}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(1200px 600px at 80% -10%,#3a1460 0%,transparent 60%),var(--bg);color:var(--ink);
font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1180px;margin:0 auto;padding:28px 20px 80px}
h1{font-size:34px;margin:0 0 4px;letter-spacing:-.5px}h2{font-size:21px;margin:40px 0 6px}
.sub{color:var(--mute);margin:0 0 18px}.sub b{color:var(--ink)}
.moon{position:fixed;right:-60px;top:-60px;width:220px;height:220px;border-radius:50%;background:#fff3d6;opacity:.08;pointer-events:none}
.bat{position:fixed;font-size:22px;opacity:.55;pointer-events:none;animation:fly 18s linear infinite}
@keyframes fly{0%{transform:translate(-10vw,0)}50%{transform:translate(50vw,-30px)}100%{transform:translate(110vw,10px)}}
@media (prefers-reduced-motion:reduce){.bat{display:none}.card,.bar rect{transition:none!important}}
.totals{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0 6px}
.pill{background:var(--s1);border:1px solid var(--line);border-radius:999px;padding:6px 14px;font-weight:600}
.pill i{font-style:normal;display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px}
.card{background:var(--s1);border:1px solid var(--line);border-radius:18px;padding:16px;cursor:pointer;
box-shadow:0 8px 24px rgba(0,0,0,.35);transition:transform .35s cubic-bezier(.2,.9,.3,1.3),border-color .2s}
.card:hover{transform:translateY(-3px)}.card.on{border-color:var(--pump)}
.card h3{margin:0;font-size:17px}.card .v{color:var(--mute);font-size:13px;margin:6px 0 0}
.meter{display:flex;align-items:center;gap:14px;margin-top:8px}
.meter .pct{font-size:30px;font-weight:800}.meter small{display:block;color:var(--mute);font-size:12px}
.tag{display:inline-block;font-size:11px;text-transform:uppercase;letter-spacing:.6px;padding:2px 8px;border-radius:6px;background:var(--s2);color:var(--part);margin-top:8px}
.panel{background:var(--s1);border:1px solid var(--line);border-radius:18px;padding:16px;box-shadow:0 8px 24px rgba(0,0,0,.35)}
.bar{cursor:pointer}.bar:hover text{fill:#fff}.bar.on .lab{fill:var(--pump)}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:13px;color:var(--mute);margin:4px 0 10px}
.legend i{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:5px;vertical-align:-1px}
.graves{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.grave{background:linear-gradient(#3a2f4d,#2a2238);border-radius:60px 60px 10px 10px;padding:22px 10px 14px;text-align:center;cursor:pointer;
border:1px solid #4a3d60;transition:transform .3s cubic-bezier(.2,.9,.3,1.3)}
.grave:hover{transform:translateY(-4px)}.grave.on{outline:2px solid var(--pump)}
.grave .n{font-size:34px;font-weight:800}.grave .t{color:var(--mute);font-size:13px}.grave .rip{font-size:11px;letter-spacing:2px;color:#9a8cb3}
.filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0 12px}
.chip{background:var(--s2);border:1px solid var(--line);color:var(--ink);border-radius:999px;padding:6px 12px;cursor:pointer;font:inherit;font-size:13px}
.chip.on{background:var(--pump);border-color:var(--pump);color:#1b0b00;font-weight:700}
input[type=search]{background:var(--s2);border:1px solid var(--line);color:var(--ink);border-radius:10px;padding:7px 12px;font:inherit;min-width:220px}
.active{color:var(--mute);font-size:13px}.active button{background:none;border:0;color:var(--pump);cursor:pointer;font:inherit}
table{width:100%;border-collapse:collapse}th{text-align:left;font-size:12px;color:var(--mute);font-weight:600;padding:6px 8px;border-bottom:1px solid var(--line)}
td{padding:9px 8px;border-bottom:1px solid #2a1a43;vertical-align:top}tr.row{cursor:pointer}tr.row:hover td{background:#26143f}
.st{font-weight:700;white-space:nowrap}.st.have{color:var(--have)}.st.partial{color:var(--part)}.st.missing{color:var(--miss)}
tr.det td{background:#1b0d2e;color:var(--mute);font-size:13px}tr.det b{color:var(--ink)}
.hosts span{display:inline-block;margin-right:8px;white-space:nowrap}
.treats{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.treat{background:var(--s1);border:1px solid var(--line);border-radius:14px;padding:12px 14px;font-size:14px}
.treat .e{color:var(--mute);font-size:12px;margin-top:4px}.treat .u{color:var(--part)}
.note{color:var(--mute);font-size:12px;margin-top:30px}
@media (max-width:640px){.graves{grid-template-columns:repeat(2,1fr)}h1{font-size:26px}td:nth-child(4),th:nth-child(4){display:none}}
</style></head><body>
<div class="moon"></div><div class="bat" style="top:12%">🦇</div><div class="bat" style="top:30%;animation-delay:-7s;animation-duration:24s">🦇</div>
<main>
<h1>🎃 The Haunted Audit</h1>
<p class="sub">Can omxcode build the apps we already built? Four real apps, every feature checked against the framework.
<b>Tap anything</b> to filter: an app, a bar, a tombstone.</p>
<div class="totals" id="totals"></div>
<div class="cards" id="cards"></div>

<h2>👻 The haunted backlog</h2>
<p class="sub">Framework pieces ranked by how many features they would unblock, across all four apps. Build from the top.</p>
<div class="panel"><div class="legend" id="legend"></div><svg id="chart" width="100%" role="img" aria-label="Gaps per framework piece"></svg></div>

<h2>🪦 When the ghosts get laid to rest</h2>
<p class="sub">Every partial or missing feature, by its honest ETA.</p>
<div class="graves" id="graves"></div>

<h2>📜 Every feature</h2>
<div class="filters" id="filters"></div>
<div class="active" id="active"></div>
<div class="panel" style="padding:4px 8px"><table><thead><tr><th>Status</th><th>Feature</th><th>App</th><th>omxcode piece / gap</th><th>ETA</th></tr></thead>
<tbody id="rows"></tbody></table></div>

<h2>🍬 Treats: where omxcode would beat the original</h2>
<div class="treats" id="treats"></div>
<p class="note">Generated by scripts/audit_board.py from docs/audits/*.json. The ✅/🔨/❌ marks per host come from each audit; two audits
(Pumpkin Greeter, finxplorer) read code and tests without running them. Grouping of gaps into pieces is by keyword, so a few may sit in a neighbouring piece.</p>
</main>
<script>
const D=__DATA__;
const AC={personalnote:'var(--a1)',finxplorer:'var(--a2)',appcol:'var(--a3)',halloween:'var(--a4)'};
const SL={have:'🎃 have',partial:'👻 partial',missing:'💀 missing'};
const F=[];D.apps.forEach(a=>a.features.forEach(f=>F.push({...f,app:a.slug})));
const S={app:null,piece:null,eta:null,status:null,q:''};
const pl=k=>(D.pieces.find(p=>p.key===k)||{}).label||k;
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function pumpkin(have,part){ // fill rises from the bottom: have solid, partial ghostly
  const h=56,y1=8+h*(1-have),y2=8+h*(1-have-part);
  return `<svg width="76" height="76" viewBox="0 0 76 76" aria-hidden="true"><defs><clipPath id="pc${have}${part}"><ellipse cx="38" cy="38" rx="32" ry="28"/></clipPath></defs>
  <ellipse cx="38" cy="38" rx="32" ry="28" fill="#2a1840" stroke="#ff7a1a" stroke-width="2"/>
  <g clip-path="url(#pc${have}${part})"><rect x="0" y="${y2}" width="76" height="${y1-y2}" fill="#ff7a1a" opacity=".35"/><rect x="0" y="${y1}" width="76" height="${76-y1}" fill="#ff7a1a"/></g>
  <path d="M24 14 Q38 44 52 14 M38 10 Q38 40 38 66" stroke="#150a24" stroke-width="1.5" fill="none" opacity=".35"/>
  <path d="M38 10 q2 -7 8 -8" stroke="#6fdc8c" stroke-width="4" fill="none" stroke-linecap="round"/>
  <path d="M26 32 l6 -5 l6 5z M44 32 l6 -5 l6 5z M27 46 q11 9 22 0 l-4 3 l-3 -3 l-4 3 l-4 -3 l-3 3z" fill="#150a24"/></svg>`;}
function totals(){const c={have:0,partial:0,missing:0};F.forEach(f=>c[f.status]++);
  totals_el.innerHTML=`<span class="pill">${F.length} features in 4 apps</span>`+['have','partial','missing'].map(s=>
  `<span class="pill"><i style="background:var(--${s==='have'?'have':s==='partial'?'part':'miss'})"></i>${SL[s]} ${c[s]} (${Math.round(100*c[s]/F.length)}%)</span>`).join('');}
const totals_el=document.getElementById('totals');
function cards(){document.getElementById('cards').innerHTML=D.apps.map(a=>{const n=a.features.length,c=a.counts,m=D.appmeta[a.slug]||{icon:'',name:a.app};
  return `<div class="card ${S.app===a.slug?'on':''}" data-app="${a.slug}" tabindex="0" style="border-top:4px solid ${AC[a.slug]}">
  <h3>${m.icon} ${esc(m.name)}</h3><div class="meter">${pumpkin(c.have/n,c.partial/n)}<div><span class="pct">${Math.round(100*c.have/n)}%</span>
  <small>have · ${Math.round(100*c.partial/n)}% partial · ${Math.round(100*c.missing/n)}% missing</small><small>${n} features</small></div></div>
  <p class="v">${esc(a.verdict)}</p><span class="tag">buildable today: ${esc(a.buildable_today)}</span></div>`}).join('');
  document.querySelectorAll('.card').forEach(e=>e.onclick=()=>{S.app=S.app===e.dataset.app?null:e.dataset.app;render();});}
function chart(){const gaps=F.filter(f=>f.status!=='have'&&f.piece!=='scope');
  const rows=D.pieces.filter(p=>p.key!=='scope').map(p=>{const fs=gaps.filter(f=>f.piece===p.key);
    const by={};D.apps.forEach(a=>by[a.slug]=fs.filter(f=>f.app===a.slug).length);
    const et=fs.map(f=>D.etas.indexOf(f.eta)).filter(i=>i>=0);
    return {p,n:fs.length,by,blocks:fs.filter(f=>f.blocks).length,apps:Object.values(by).filter(x=>x).length,
      eta:et.length?D.etas[Math.min(...et)]+(Math.max(...et)>Math.min(...et)?' → '+D.etas[Math.max(...et)]:''):''};}).filter(r=>r.n).sort((a,b)=>b.n-a.n);
  const W=1000,L=300,R=290,rh=34,max=Math.max(...rows.map(r=>r.n)),svg=document.getElementById('chart');
  svg.setAttribute('viewBox',`0 0 ${W} ${rows.length*rh+8}`);
  svg.innerHTML=rows.map((r,i)=>{let x=L,y=i*rh+6;const seg=D.apps.map(a=>{const w=(W-L-R)*r.by[a.slug]/max;const s=w?`<rect x="${x}" y="${y}" width="${w}" height="22" rx="4" fill="${AC[a.slug]}"><title>${D.appmeta[a.slug].name}: ${r.by[a.slug]}</title></rect>`:'';x+=w;return s;}).join('');
    return `<g class="bar ${S.piece===r.p.key?'on':''}" data-piece="${r.p.key}"><rect x="0" y="${y-4}" width="${W}" height="${rh-2}" fill="transparent"/>
    <text class="lab" x="${L-10}" y="${y+16}" text-anchor="end" fill="#f3ecff" font-size="15">${esc(r.p.label)}</text>${seg}
    <text x="${x+8}" y="${y+16}" fill="#b6a6d3" font-size="13">${r.n} · ${r.apps} app${r.apps>1?'s':''} · ${r.blocks} blocking · ${r.eta}</text></g>`}).join('');
  document.getElementById('legend').innerHTML=D.apps.map(a=>`<span><i style="background:${AC[a.slug]}"></i>${D.appmeta[a.slug].name}</span>`).join('');
  svg.querySelectorAll('.bar').forEach(e=>e.onclick=()=>{S.piece=S.piece===e.dataset.piece?null:e.dataset.piece;render();});}
function graves(){const gaps=F.filter(f=>f.status!=='have'&&f.piece!=='scope');
  document.getElementById('graves').innerHTML=D.etas.map(e=>`<div class="grave ${S.eta===e?'on':''}" data-eta="${e}"><div class="rip">R.I.P.</div><div class="n">${gaps.filter(f=>f.eta===e).length}</div><div class="t">${e}</div></div>`).join('');
  document.querySelectorAll('.grave').forEach(g=>g.onclick=()=>{S.eta=S.eta===g.dataset.eta?null:g.dataset.eta;render();});}
function filters(){const el=document.getElementById('filters');
  el.innerHTML=['have','partial','missing'].map(s=>`<button class="chip ${S.status===s?'on':''}" data-s="${s}">${SL[s]}</button>`).join('')+
  `<input type="search" placeholder="Search features, pieces, gaps…" value="${esc(S.q)}">`;
  el.querySelectorAll('.chip').forEach(c=>c.onclick=()=>{S.status=S.status===c.dataset.s?null:c.dataset.s;render();});
  const q=el.querySelector('input');q.oninput=()=>{S.q=q.value;rows();active();};}
function match(f){if(S.app&&f.app!==S.app)return false;if(S.piece&&f.piece!==S.piece)return false;if(S.eta&&f.eta!==S.eta)return false;
  if(S.status&&f.status!==S.status)return false;if(S.q){const t=(f.feature+' '+(f.gap||'')+' '+(f.omx_piece||'')+' '+f.area).toLowerCase();if(!t.includes(S.q.toLowerCase()))return false;}return true;}
function active(){const bits=[];if(S.app)bits.push(D.appmeta[S.app].name);if(S.piece)bits.push(pl(S.piece));if(S.eta)bits.push(S.eta);if(S.status)bits.push(S.status);
  const n=F.filter(match).length;document.getElementById('active').innerHTML=`${n} shown`+(bits.length?` · ${bits.map(esc).join(' · ')} <button id="clr">clear ✕</button>`:'');
  const c=document.getElementById('clr');if(c)c.onclick=()=>{Object.assign(S,{app:null,piece:null,eta:null,status:null,q:''});render();};}
function rows(){const rk={missing:0,partial:1,have:2};const fs=F.filter(match).sort((a,b)=>rk[a.status]-rk[b.status]);
  document.getElementById('rows').innerHTML=fs.map((f,i)=>`<tr class="row" data-i="${i}"><td class="st ${f.status}">${SL[f.status]}</td>
  <td><b>${esc(f.feature)}</b><div style="color:var(--mute);font-size:12px">${esc(f.area)}</div></td>
  <td style="white-space:nowrap">${D.appmeta[f.app].icon} ${esc(D.appmeta[f.app].name)}</td>
  <td>${f.status==='have'?esc(f.omx_piece||''):esc(f.gap||'')}${f.piece?`<div style="font-size:12px;color:var(--mute)">${esc(pl(f.piece))}</div>`:''}</td>
  <td style="white-space:nowrap">${esc(f.eta||'')}${f.size?` · ${f.size}`:''}${f.blocks?' ⛓':''}${f.demo?' 🎬':''}</td></tr>
  <tr class="det" hidden><td colspan="5"><b>omxcode piece:</b> ${esc(f.omx_piece||'none yet')} · <b>evidence:</b> ${esc(f.evidence||'')}<br>
  <b>app code:</b> ${esc(f.app_file||'')}<br><span class="hosts">${Object.entries(f.hosts||{}).map(([h,v])=>`<span>${h} ${v}</span>`).join('')}</span>
  ${f.gap?`<br><b>gap:</b> ${esc(f.gap)}`:''}${f.blocks?'<br>⛓ blocks a faithful rebuild':''}${f.demo?' · 🎬 good demo video':''}</td></tr>`).join('');
  document.querySelectorAll('tr.row').forEach(r=>r.onclick=()=>{const d=r.nextElementSibling;d.hidden=!d.hidden;});}
function treats(){document.getElementById('treats').innerHTML=D.apps.flatMap(a=>(a.wins||[]).filter(w=>!S.app||S.app===a.slug).map(w=>{
  const un=/unproven/i.test(w.evidence||'');return `<div class="treat" style="border-left:4px solid ${AC[a.slug]}">${D.appmeta[a.slug].icon} ${esc(w.what)}
  <div class="e ${un?'u':''}">${un?'👻 ':'✅ '}${esc(w.evidence)}</div></div>`;})).join('');}
function render(){totals();cards();chart();graves();filters();active();rows();treats();}
render();
</script></body></html>
"""

if __name__ == "__main__":
    main()
