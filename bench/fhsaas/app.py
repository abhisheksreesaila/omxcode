"""The fh-saas baseline for goal 60's M10 (scripts/saas_bench.py): the same API as examples/saas/server.mojo, built the way
fh-saas's docs say (the standard app shape in its skill: create_auth_beforeware with setup_tenant_db=False and the
session cache, handle_login_request / handle_oauth_callback, require_tenant_access in routes that touch tenant data,
the billing orchestrator's webhook). The only change is where Google lives: GoogleAppClient's endpoints point at the
bench's OAuth stand-in (as examples/saas's SAAS_OAUTH_* do).

    cd <data dir> && pixi run -e fhsaas uvicorn --app-dir bench/fhsaas app:app --port N --workers W
env: FH_OAUTH_BASE (the stand-in), GOOGLE_CLIENT_ID/SECRET, STRIPE_*, DB_TYPE=SQLITE, DB_NAME, FH_SECRET
"""
import json
import os
import time

from fasthtml.common import FastHTML, JSONResponse, RedirectResponse
from fasthtml.oauth import GoogleAppClient
from sqlalchemy import text

from fh_saas.utils_auth import create_auth_beforeware, handle_login_request, handle_oauth_callback, require_tenant_access
from fh_saas.utils_billing import BillingConfig, register_billing_routes, _build_default_stores
from fh_saas.utils_stripe import StripeService
from starlette.responses import Response

base = os.environ["FH_OAUTH_BASE"]
GoogleAppClient.base_url = base + "/authorize"
GoogleAppClient.token_url = base + "/token"
GoogleAppClient.info_url = base + "/userinfo"

beforeware = create_auth_beforeware(setup_tenant_db=False, session_cache=True, skip=[r"/stripe/webhook", r"/auth/callback", r"/login", r"/$"])
app = FastHTML(before=beforeware, secret_key=os.environ["FH_SECRET"])
os.environ["BILLING_WEBHOOK_PATH"] = "/stripe/webhook-as-shipped"  # (fh-saas 0.9.14's own route crashes after verifying, below)
config = BillingConfig.from_env()
register_billing_routes(app, config)
stripe_service = StripeService(config.to_stripe_config(), None)
_, subscription_store = _build_default_stores()


@app.post("/stripe/webhook")
async def stripe_webhook(request):
    """fh-saas's billing_webhook (utils_billing.register_billing_routes) as shipped, with one fix: stripe-python's Event
    is no longer a dict, so the shipped route raises AttributeError on `event.get` for every verified event."""
    payload = await request.body()
    event = stripe_service.verify_signature(payload, request.headers.get("stripe-signature", ""))
    if not event:
        return Response("Invalid signature", status_code=400)
    event = event.to_dict() if hasattr(event, "to_dict") else event
    event_id, event_type = event.get("id", ""), event.get("type", "")
    if subscription_store.has_processed_event(event_id):
        return Response("OK", status_code=200)
    result = stripe_service.handle_event(event)
    subscription_store.record_event(event_id, event_type, "processed" if result.get("status") != "error" else "failed", json.dumps({"result": result}))
    if result.get("status") == "error":
        return Response(result["message"], status_code=500)
    return Response("OK", status_code=200)

_ready = set()


def tenant(request):
    db = require_tenant_access(request)
    tid = request.state.user["tenant_id"]
    if tid not in _ready:
        db.conn.execute(text("CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, text TEXT NOT NULL, amount_cents INTEGER NOT NULL, by TEXT, at INTEGER)"))
        db.conn.commit()
        _ready.add(tid)
    return db


@app.get("/")
def home():
    return "fh-saas baseline"


@app.get("/login")
def login(request, session):
    return RedirectResponse(handle_login_request(request, session), status_code=303)


@app.get("/auth/callback")
def auth_callback(code: str, state: str, request, session):
    return handle_oauth_callback(code, state, request, session)


@app.get("/api/me")
def me(request):
    u = request.state.user
    return JSONResponse({"email": u.get("email"), "tenant": u.get("tenant_id"), "role": u.get("tenant_role") or u.get("role"), "plan": "free"})


@app.get("/api/entries")
def entries(request):
    db = tenant(request)
    try:
        rows = db.conn.execute(text("SELECT text, amount_cents, by FROM entries ORDER BY id")).fetchall()
        return JSONResponse({"entries": [{"text": r[0], "amount_cents": r[1], "by": r[2]} for r in rows]})
    finally:
        db.conn.close()


@app.post("/api/entries")
async def add_entry(request):
    body = await request.json()
    db = tenant(request)
    try:
        db.conn.execute(text("INSERT INTO entries(text, amount_cents, by, at) VALUES (:t, :c, :b, :a)"),
                        {"t": body["text"], "c": int(body["amount_cents"]), "b": request.state.user.get("email"), "a": int(time.time())})
        db.conn.commit()
        return JSONResponse({"ok": True}, status_code=201)
    finally:
        db.conn.close()
