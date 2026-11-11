// finance_min's front end: plain JavaScript over the JSON API (no framework). Reads /api/me, /api/spending and
// /api/transactions; the CSV export is a plain download link.
const $ = (s) => document.querySelector(s);
const money = (n) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toFixed(2);
function cell(text, cls) { const td = document.createElement("td"); td.textContent = text; if (cls) td.className = cls; return td; }
async function load() {
  const me = await fetch("/api/me").then((r) => (r.ok ? r.json() : null));
  if (!me) { location.href = "/login?next=/app"; return; }
  $("#who").textContent = me.email + " · " + me.plan;
  const sp = await fetch("/api/spending").then((r) => r.json());
  const body = $("#spending"); body.replaceChildren();
  for (const c of sp.categories) { const tr = document.createElement("tr"); tr.append(cell(c.category), cell(money(c.total), "n")); body.append(tr); }
  const tx = await fetch("/api/transactions").then((r) => r.json());
  $("#status").textContent = tx.transactions.length + " transactions";
}
load();
