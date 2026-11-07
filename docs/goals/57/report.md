# Goal 57 report: SaaS building blocks in omxcode, Mojo only

**End goal (owner, 2026-11-06):** fh-saas's jobs (Google sign-in, sessions, users, tenants and roles, one SQLite per
tenant, Stripe checkout, webhooks, a paywall) as `mojoui` modules on `mojoui.serve` (Flare), with no Python in the
server and CPU only (parity, not speed). Plus a tiny native demo for the gallery. The owner added M8 mid-run: the same
on the Mac.

**Where it stands:** it works end to end against the checker's Google and Stripe stand-ins, on Linux and on the owner's
Mac. Real Google and Stripe wait for your keys (M5).

## Checker output (final tree 43982418, `docs/goals/57/check.txt`)
```
M0: PASS  own env, Mojo 1.2, serve/https/hash pass
M1: PASS  hmac, random, base64url, compare, seal
M2: PASS  PKCE + state, sealed HttpOnly cookie, one SQLite per tenant, no cross-tenant reads, roles, server-side sign-out
M3: PASS  checkout session, signed webhooks (bad/old refused, once only), Pro for ada only, cancel → free
M4: PASS  native sign-in via the system browser + loopback, an entry in ada's SQLite, upgrade → Pro; shot build/g57/m4.png
M5: BLOCKED  no ~/.config/omxcode/saas.env: the owner runs scripts/saas_keys.sh (Google OAuth client + Stripe test key)
M6: PASS  parity map, components listed, gallery card, Linux download
M7: PASS  ui thread, served, libc and decision lints
M8: PASS  on the Mac (macOS, arm64): the server passes M2 and M3; the AppKit app signs in and pays; shot build/g57/m8-mac.png
```
**Reviews:** the reviewer and the security auditor both said NEEDS WORK in round 1. I fixed what they flagged
(D-5724–D-5728) and proved the fixes on the live server (`build/g57/probe_fixes.py`):
- a callback finished in another browser gets 400;
- a cross-origin cookie write gets 401 (the same write from the site's own origin gets 201);
- a 2 MB webhook gets 413.

Both reviewers passed rounds 2 and 3. No Critical or High findings at any point.

## What was built (framework first: the app only composes)
| Piece | Does | Test |
|---|---|---|
| `mojoui.crypto` | HMAC-SHA256, OS random (getentropy), base64url, constant-time compare, seals, PKCE: plain Mojo, every host | tests/test_crypto.mojo |
| `mojoui.accounts` | Google OAuth with state and PKCE; server-side sessions in sealed HttpOnly cookies; tenants, roles and invites; one SQLite file per tenant; RFC 8252 desktop sign-in | tests/test_accounts.mojo, M2 |
| `mojoui.billing` | Stripe Checkout, signed webhooks applied once, reading the session back on return, a paywall (402) | tests/test_billing.mojo, M3 |
| `mojoui.signin` | the desktop side: a loopback listener (libc sockets, no Flare) and the PKCE verifier | M4, M8 |
| `mojoui.browser` + `App.opens` | open_url as an effect, like HTTP: GTK and AppKit | tests/test_open_url.mojo |
| AppKit host | `waitfor:` steps, offscreen test runs (`MOJOUI_OFFSCREEN=1`), `MOJOUI_REPORT_DIR`, BETWEEN rows read like GTK's | M8 |
| `examples/saas` | `server.mojo` (routes only) and `app.mojo` (native client, Liquid light) | M2–M4, M8 |

The fh-saas → mojoui parity map is in `docs/saas.md`, with honest ❌ marks: email, background jobs, migrations, logging,
the customer portal and trials. Its "Known limits" section lists what to close before real users.

## 30-second demo
```
scripts/saas_keys.sh                                   # once: your Google Desktop client + Stripe test key → ~/.config/omxcode/saas.env
scripts/saas.sh run &                                  # the Mojo server on http://127.0.0.1:8000
scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas
```
1. Press **Sign in with Google**. Your browser opens and you sign in.
2. The app shows `Signed in as <you>`.
3. Add *Coffee 4.50*. The entry lands in your tenant's own `build/saas/data/tenants/<id>.db`.
4. Press **Upgrade** and pay with 4242 4242 4242 4242 on Stripe's test page.
5. The app shows `Plan: Pro`.

Without keys, `scripts/check M4` plays the same story against the stand-ins.

![Linux: ada on Pro](goals/57/m4-linux.png)
![The Mac (AppKit): the same run on the owner's Mac](goals/57/m8-mac.png)
![Gallery: ada on Pro beside ben on Free](gallery/img/saas.png)

## Three decisions worth your second look
1. **D-5725: invites still join silently.** An invited person lands in the inviting tenant on their first sign-in,
   with no accept step, because M2's contract says so. The auditor's one open Medium: an admin of *any* tenant can
   pre-invite an address before that person signs up. Fix: an accept page ("Join X, invited by Y?"). It must close
   before real users.
2. **D-5714 / D-5727: Google and Stripe calls run under the server's one lock.** This was a parity choice. A slow
   provider stalls every request for up to 20–30 s. There are only cheap limits: body caps, and a global budget of 30
   `/billing/return` read-backs a minute. Moving these calls into jobs and adding per-IP limits is the scale-up step.
3. **D-5719 / D-5724: two edits to the checker's M4 proof, each logged before the edit.**
   - The label regex could never match GTK's `LABEL: ` lines, so no app could have passed it. Fixed.
   - The check was tightened from any label containing "Pro" to `Plan: Pro`.

   Neither edit lowered a bar.

## What needs you
- **Run `scripts/saas_keys.sh`.** It walks you through a Google "Desktop app" OAuth client and a Stripe test-mode key
  plus the Pro price, then offers to run M5. I never read that file.
- **Then sign in with Google once by hand** (D-5705: Google blocks scripted sign-ins). That first real run also
  confirms the browser-bound state cookie survives Google's redirect, which so far is proved only against the
  stand-in.
- **Optional: upload `dist/saas-linux-x86_64.tar.gz`** (the app with its server) to the `gallery-apps` release.
  The gallery card links there.

**Next step:** run the wizard and M5, then add the invite accept page.
