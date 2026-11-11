"""Goal 66 M7: an fh-saas host database made by fh-saas itself (pixi env `fhsaas`), never a real one.

    pixi run -e fhsaas python scripts/fhsaas_seed.py <folder>

Five people in three tenants (an active subscription, a Stripe trial, none), each tenant's own SQLite file with a table
of rows, through fh-saas's HostDatabase and get_or_create_tenant_db. Prints one JSON line: what it made and what a
sign-in should find after the import ({users: [{email, name, tenant, role, plan, trial_ends?}], tenants, host_db, …}).
"""
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

folder = Path(sys.argv[1]).resolve()
folder.mkdir(parents=True, exist_ok=True)
os.chdir(folder)  # (fh-saas's SQLite URLs are relative: sqlite:///app_host.db, sqlite:///<tenant>_db.db)
os.environ.update(DB_TYPE="SQLITE", DB_NAME="app_host")

import sqlite3  # noqa: E402
from importlib.metadata import version  # noqa: E402
from fh_saas.db_host import HostDatabase, GlobalUser, Membership, Subscription, gen_id, timestamp  # noqa: E402
from fh_saas.db_tenant import get_or_create_tenant_db  # noqa: E402

host = HostDatabase.from_env()
iso = lambda d: d.astimezone(timezone.utc).replace(tzinfo=None).isoformat()  # noqa: E731 (fh-saas stores naive UTC ISO)
now = datetime.now(timezone.utc)
tenants = [("Ada Household", "active", 4), ("Cy Ltd", "trialing", 3), ("Eve Free", None, 2)]
people = [("ada@example.com", "Ada", 0, "admin"), ("ben@example.com", "Ben", 0, "editor"), ("cy@example.com", "Cy", 1, "admin"),
          ("dee@example.com", "Dee", 1, "viewer"), ("eve@example.com", "Eve", 2, "admin")]
made_tenants = []
for name, status, rows in tenants:
    tid = gen_id()
    get_or_create_tenant_db(tid, name)  # (fh-saas makes the file and registers it in core_tenants)
    url = host.tenant_catalogs[tid].db_url
    with sqlite3.connect(url.removeprefix("sqlite:///")) as c:  # (the app's own rows in it)
        c.execute("CREATE TABLE IF NOT EXISTS fh_rows(id INTEGER PRIMARY KEY, note TEXT)")
        c.executemany("INSERT INTO fh_rows(note) VALUES (?)", [(f"{name} row {i}",) for i in range(rows)])
    t = host.tenant_catalogs[tid]
    t.plan_tier = "pro" if status else "free"
    host.tenant_catalogs.update(t)
    trial_end = None
    if status:
        period_end = now + timedelta(days=10 if status == "trialing" else 30)
        trial_end = iso(period_end) if status == "trialing" else None
        host.subscriptions.insert(Subscription(id=gen_id(), tenant_id=tid, stripe_sub_id="sub_" + tid[:14], stripe_cust_id="cus_" + tid[:14],
                                               plan_tier="pro", status=status, current_period_end=iso(period_end), cancel_at_period_end=False,
                                               trial_end=trial_end, created_at=timestamp()))
    made_tenants.append({"id": tid, "name": name, "status": status, "rows": rows, "trial_end": trial_end})
users = []
for email, name, ti, role in people:
    uid = gen_id()
    host.global_users.insert(GlobalUser(id=uid, email=email, oauth_id="sub-" + email, created_at=timestamp()))  # (Google's sub)
    host.memberships.insert(Membership(id=gen_id(), user_id=uid, tenant_id=made_tenants[ti]["id"], profile_id=gen_id(), role=role, created_at=timestamp()))
    t = made_tenants[ti]
    users.append({"email": email, "name": name, "tenant": t["id"], "role": {"editor": "member"}.get(role, role),
                  "plan": "pro" if t["status"] else "free", "trial_ends": t["trial_end"]})
print(json.dumps({"version": version("fh-saas"), "host_db": str(folder / "app_host.db"), "tenants_dir": str(folder),
                  "tenants": made_tenants, "users": users}))
