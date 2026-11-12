"""Leaving fh-saas (goal 66 M7): move an fh-saas host database (SQLite) into omxcode's host.db and copy its tenants' files.

    pixi run python scripts/fhsaas_import.py --from <fh host .db> --tenants <folder of fh tenant files> --to <SAAS_DATA> --dry-run
    pixi run python scripts/fhsaas_import.py --from … --tenants … --to …          # then for real (run it again: nothing changes)

Start the omxcode server once on SAAS_DATA first (it makes and migrates host.db), stop it, import, start it again.
What moves (fh-saas → omxcode):
  core_users (email, oauth_id = Google's sub, created_at)          → users (email, sub, provider 'google', created)
  core_tenants (id, name, plan_tier, created_at; active only)      → tenants (the same id, name, plan, created)
  core_memberships (active; admin, editor, member, viewer)         → members (admin; editor and member → member; viewer;
                                                                       anything else → viewer, the least, and a warning)
  core_subscriptions (status, Stripe customer and subscription ids, current_period_end, cancel_at_period_end, trial_end)
                                                                    → billing (+ tenants.plan, customer, subscription):
                                                                       a trial's end is its period end (/api/me's trial_ends)
  each tenant's file (core_tenants.db_url, sqlite:///…)             → tenants/<id>.db (SQLite's backup: a consistent copy),
                                                                       skipped when it is there already
Identity (D-6021): a person is their Google sub. Someone whose email host.db already has under another sub, or whose sub
host.db already has under another email, is not imported, nor are their memberships (a warning names their fh-saas id).
Idempotent and never rolls omxcode back: rows that exist (people, tenants, members, billing) are left as they are, only
new ones are written, so running it again after go-live can't undo a role change, a cancellation or a Stripe event.
Nothing is deleted.
Never reads anything but the two databases and the tenant files it is pointed at; prints counts, never people's data.
"""
import argparse
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

ROLES = {"admin": "admin", "editor": "member", "member": "member", "viewer": "viewer"}
PRO = {"active", "trialing", "past_due"}


def epoch(iso):
    if not iso:
        return None
    try:
        d = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)  # (fh-saas writes naive UTC: datetime.utcnow().isoformat())
    return int(d.timestamp())


def read_fh(path):
    src = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    need = {"core_users", "core_tenants", "core_memberships", "core_subscriptions"}
    have = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if not need <= have:
        sys.exit(f"not an fh-saas host database: missing {sorted(need - have)}")
    users = [dict(r) for r in src.execute("SELECT id, email, oauth_id, created_at FROM core_users")]
    tenants = [dict(r) for r in src.execute("SELECT id, name, db_url, is_active, plan_tier, created_at FROM core_tenants")]
    members = [dict(r) for r in src.execute("SELECT user_id, tenant_id, role, is_active, created_at FROM core_memberships")]
    subs = [dict(r) for r in src.execute("SELECT tenant_id, stripe_sub_id, stripe_cust_id, status, current_period_end, cancel_at_period_end,"
                                         " trial_end, payment_type, created_at FROM core_subscriptions ORDER BY created_at")]
    src.close()
    return users, tenants, members, subs


def person(host, u):
    """(host.db's user id, or None to leave this person out; a warning or ""). Matches by sub first, then email."""
    email = (u["email"] or "").strip().lower()
    sub = u["oauth_id"] or None
    if not email or "@" not in email:
        return None, f"user {u['id']}: no usable email: left out"
    by_sub = host.execute("SELECT id, email FROM users WHERE provider = 'google' AND sub = ?", (sub,)).fetchone() if sub else None
    by_email = host.execute("SELECT id, sub FROM users WHERE email = ?", (email,)).fetchone()
    if by_sub and by_sub[1] != email:
        return None, f"user {u['id']}: their Google sign-in already belongs to another address in host.db: left out with their memberships"
    if by_email and by_email[1] and sub and by_email[1] != sub:
        return None, f"user {u['id']}: host.db has this address under another Google sign-in: left out with their memberships"
    if by_email:
        if not by_email[1] and sub:
            host.execute("UPDATE users SET sub = ?, provider = 'google' WHERE id = ?", (sub, by_email[0]))
        return by_email[0], ""
    host.execute("INSERT INTO users(email, name, sub, provider, created) VALUES (?, ?, ?, ?, ?)",
                 (email, email.split("@")[0], sub, "google" if sub else None, epoch(u["created_at"])))
    return host.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()[0], ""


def tenant_ok(tid):
    return isinstance(tid, str) and 0 < len(tid) <= 64 and all(c.isalnum() or c in "-_" for c in tid) and tid.isascii()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--tenants", required=True, help="the folder fh-saas's sqlite:/// tenant URLs are relative to")
    ap.add_argument("--to", required=True, help="omxcode's SAAS_DATA (host.db, tenants/)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    data = Path(a.to)
    host_path = data / "host.db"
    if not host_path.exists():
        sys.exit(f"{host_path} doesn't exist: start the omxcode server once on {data} (it makes and migrates host.db), then import")
    users, tenants, members, subs = read_fh(a.src)
    warnings = []
    live = [t for t in tenants if t["is_active"] in (1, True, None)]
    for t in live:
        if not tenant_ok(t["id"]):
            sys.exit(f"a tenant id omxcode can't use as a file name: {t['id']!r}")
    sub_by_tenant = {}
    for s in subs:  # (the newest row per tenant, subscriptions before one-time payments)
        if s["payment_type"] in (None, "subscription"):
            sub_by_tenant[s["tenant_id"]] = s
    plan = {"users": len(users), "tenants": len(live), "inactive_tenants": len(tenants) - len(live),
            "members": sum(1 for m in members if m["is_active"] in (1, True, None)), "subscriptions": len(sub_by_tenant)}
    files = []
    for t in live:
        url = t["db_url"] or ""
        if not url.startswith("sqlite:///"):
            warnings.append(f"tenant {t['id']}: its database isn't SQLite ({url.split(':')[0]}): not copied")
            continue
        rel = url.removeprefix("sqlite:///")
        src = Path(rel) if Path(rel).is_absolute() else Path(a.tenants) / rel
        dst = data / "tenants" / f"{t['id']}.db"
        files.append((t["id"], src, dst))
    plan["tenant_files"] = sum(1 for _, s, d in files if s.exists() and not d.exists())
    plan["tenant_files_present"] = sum(1 for _, s, d in files if d.exists())
    plan["tenant_files_missing"] = sum(1 for _, s, d in files if not s.exists())
    print(("dry run: would import " if a.dry_run else "importing ") + ", ".join(f"{k} {v}" for k, v in plan.items()))
    if a.dry_run:
        host = sqlite3.connect(f"file:{host_path}?mode=ro", uri=True)
        known = {r[0] for r in host.execute("SELECT email FROM users")}
        print(f"dry run: {sum(1 for u in users if u['email'].lower() in known)} of {len(users)} people already in host.db")
        clashes = 0
        for u in users:
            sub, email = u["oauth_id"], (u["email"] or "").strip().lower()
            a = host.execute("SELECT 1 FROM users WHERE provider = 'google' AND sub = ? AND email != ?", (sub, email)).fetchone() if sub else None
            b = host.execute("SELECT 1 FROM users WHERE email = ? AND sub IS NOT NULL AND sub != ?", (email, sub)).fetchone() if sub else None
            if a or b:
                clashes += 1
                warnings.append(f"user {u['id']}: their address or Google sign-in belongs to someone else in host.db: would be left out")
        print(f"dry run: {clashes} identity clashes")
        for w in warnings:
            print("warning: " + w)
        return
    host = sqlite3.connect(host_path, timeout=30)
    host.execute("PRAGMA foreign_keys = ON")
    with host:  # (one transaction: all or nothing)
        uid = {}
        for u in users:
            ok, why = person(host, u)
            if why:
                warnings.append(why)
            if ok is not None:
                uid[u["id"]] = ok
        for t in live:
            s = sub_by_tenant.get(t["id"])
            status = (s["status"] or "none") if s else "none"
            pro = status in PRO
            host.execute("INSERT INTO tenants(id, name, plan, customer, subscription, created) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING",
                         (t["id"], t["name"], "pro" if pro else "free", s["stripe_cust_id"] if s else None, s["stripe_sub_id"] if s else None, epoch(t["created_at"])))
            if s:
                end = epoch(s["trial_end"]) if status == "trialing" and s["trial_end"] else epoch(s["current_period_end"])
                host.execute("INSERT INTO billing(tenant, status, customer, subscription, period_end, cancel_at_period_end, past_due_since, event_at)"
                             " VALUES (?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(tenant) DO NOTHING",
                             (t["id"], status, s["stripe_cust_id"], s["stripe_sub_id"], end, 1 if s["cancel_at_period_end"] else 0,
                              epoch(s["current_period_end"]) if status == "past_due" else None))
        tids = {t["id"] for t in live}
        for m in members:
            if m["is_active"] not in (1, True, None) or m["tenant_id"] not in tids or m["user_id"] not in uid:
                continue
            role = ROLES.get((m["role"] or "").lower())
            if role is None:
                warnings.append(f"a membership with role {m['role']!r}: imported as viewer")
                role = "viewer"
            host.execute("INSERT INTO members(user_id, tenant, role, joined) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, tenant) DO NOTHING",
                         (uid[m["user_id"]], m["tenant_id"], role, epoch(m["created_at"])))
    (data / "tenants").mkdir(exist_ok=True)
    copied = 0
    for tid, src, dst in files:
        if dst.exists():
            continue
        if not src.exists():
            warnings.append(f"tenant {tid}: no file at {src}")
            continue
        tmp = dst.with_suffix(".importing")
        tmp.unlink(missing_ok=True)
        s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        d = sqlite3.connect(tmp)
        s.backup(d)
        d.close()
        s.close()
        tmp.rename(dst)
        copied += 1
    print(f"imported: {len(uid)} people, {len(live)} tenants, {copied} tenant files copied")
    for w in warnings:
        print("warning: " + w)


if __name__ == "__main__":
    main()
