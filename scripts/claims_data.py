#!/usr/bin/env python3
"""Goal 41 M0: claim data with exact truth.

    pixi run python scripts/claims_data.py OUT

Writes into OUT, deterministically (fixed seeds; no analysis of any picture or PDF):
  dock.mp4          goal 39's warehouse scene (scripts/media_data.py's own generator, imported): 1280x720, 30 fps, 38 s.
                    Each pallet carries its shipment's stripe code (the 4-digit number under the bars).
  shipments.csv     shipment_id, carrier, consignee, pallets, status, claim_usd.
                    shipment_id is the integer the pallet's stripe code carries, so shipments.shipment_id joins the video
                    rows' `code` directly (no mapping table). Two shipments never reach this camera.
  forklift_log.csv  t, speed, brake: the dock forklift's log at 10 Hz on its own clock: log t = video t + log_offset_s.
                    A hard brake (brake = 1, speed dropping) lands just before each damaged pallet comes into view.
  bol/BOL-<id>.pdf  one digital one-page bill of lading (PyMuPDF, real text layer) per shipment that reached the dock
                    (status delivered or claim). Fixed metadata and no new file id, so the bytes repeat too.
  truth.json
    bols          [{file, shipment, fields: {name: {value, page, box: [x, y, w, h]}}}], fields shipment_no, date,
                  carrier, consignee, pallets, exceptions, signed_by. page is 0-based. box is in PDF points (origin top
                  left, y down) and is the value's ink box: from the cap height above the baseline (0.718 em, Helvetica)
                  to the glyph descender below it (0.207 em), across the value's advance width.
    disputed      sorted shipment ids (text, as in a CSV) whose pallet is damaged on camera and whose BOL says Exceptions: None.
    damage_frame  {shipment id: frame}: the first frame (0-based, 30 fps) on which the damaged pallet is wholly in view,
                  so its tear and its code can both be read (goal 39's `first`; the same frames as its damaged intervals).
    log_offset_s  log t = video t + log_offset_s.
    warehouse     goal 39's warehouse truth for this video (pallets, hidden_pallets, damaged intervals, code_spec...),
                  with video = dock.mp4.
"""

import csv
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import media_data as md  # noqa: E402  (goal 39's scene model: the warehouse generator and its truth)

SEED = 4101
LOG_OFFSET_S = 3.4
LOG_HZ = 10
CAP, DESC = 0.718, 0.207  # Helvetica cap height and glyph descender, in em

CARRIERS = ["Atlas Haulage", "Kite Logistics", "Polar Freight", "Ridge Carriers"]
CONSIGNEES = [c for c in md.CUSTOMERS if "'" not in c]
SIGNERS = ["Maria Lopez", "James Okafor", "Wei Chen", "Priya Nair", "Tom Becker", "Ana Silva", "Lena Novak"]
NOTED = ["Torn wrap on pallet", "Crushed corner noted"]  # damage written on the BOL
OTHER = ["Short 1 carton"]  # an exception that isn't damage
SHIP_DATE = "2026-10-14"


# --- the shipments ---------------------------------------------------------------------------------------------------

def shipments(recs, rng):
    """One row per pallet on the belt plus two that never reach the camera; truth flags kept beside each row."""
    rows = []
    damaged = [r for r in recs if r["damaged"]]
    noted = {r["code"] for r in rng.sample(damaged, 2)}  # these BOLs record the damage; the rest say None
    sound = [r for r in recs if not r["damaged"] and r["code_visible"]]
    short = {rng.choice(sound)["code"]}
    for r in recs:
        st = "claim" if r["damaged"] else "delivered"
        exc = "None"
        if r["code"] in noted:
            exc = NOTED[len([x for x in rows if x["exceptions"] in NOTED])]
        elif r["code"] in short:
            exc = OTHER[0]
        rows.append(dict(id=r["code"], status=st, exceptions=exc, damaged=r["damaged"], seen=True))
    used = {r["code"] for r in recs}
    for st in ("delivered", "in_transit"):
        c = rng.choice([c for c in range(1000, 4000) if c not in used])
        used.add(c)
        rows.append(dict(id=c, status=st, exceptions="None", damaged=False, seen=False))
    for r in rows:
        r["carrier"] = rng.choice(CARRIERS)
        r["consignee"] = rng.choice(CONSIGNEES)
        r["pallets"] = rng.randint(1, 9)
        r["signed_by"] = rng.choice(SIGNERS)
        r["claim_usd"] = f"{rng.randint(400, 9800) + rng.randint(0, 99) / 100:.2f}" if r["status"] == "claim" else "0.00"
        r["seal"] = f"SL{rng.randint(100000, 999999)}"
        r["trailer"] = f"TR-{rng.randint(100, 999)}"
        r["weight"] = str(r["pallets"] * rng.randint(380, 1450))
    rows.sort(key=lambda r: r["id"])
    return rows


def write_shipments(out, rows):
    with open(out / "shipments.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["shipment_id", "carrier", "consignee", "pallets", "status", "claim_usd"])
        for r in rows:
            w.writerow([r["id"], r["carrier"], r["consignee"], r["pallets"], r["status"], r["claim_usd"]])


# --- the forklift log ------------------------------------------------------------------------------------------------

def write_log(out, damage_frames, seconds, rng):
    """10 Hz: cruising speed with noise, a hard brake 0.8 s before each damaged pallet is wholly in view."""
    brakes = sorted(f / md.FPS - 0.8 for f in damage_frames)
    with open(out / "forklift_log.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["t", "speed", "brake"])
        for k in range(int(seconds * LOG_HZ) + 1):
            vt = k / LOG_HZ  # video time
            speed = 2.2 + 0.25 * rng.random()
            brake = 0
            for b in brakes:
                if b <= vt < b + 0.6:
                    brake = 1
                    speed = max(0.0, 2.2 - 3.5 * (vt - b))
                elif b + 0.6 <= vt < b + 1.8:
                    speed = min(speed, 0.2 + 1.7 * (vt - b - 0.6))
            w.writerow([f"{vt + LOG_OFFSET_S:.1f}", f"{speed:.2f}", brake])


# --- the bills of lading ---------------------------------------------------------------------------------------------

def bol_pdf(path, r):
    """A one-page bill of lading; returns {field: {value, page, box}} (boxes from the layout, not from reading it)."""
    import pymupdf

    doc = pymupdf.open()
    page = doc.new_page(width=612, height=792)  # US Letter, points
    fields = {}
    ink = (0.10, 0.11, 0.14)
    grey = (0.38, 0.40, 0.45)
    rule = (0.55, 0.57, 0.62)

    def text(x, y, s, size=10, font="helv", color=ink):
        page.insert_text((x, y), s, fontname=font, fontsize=size, color=color)
        return pymupdf.get_text_length(s, fontname=font, fontsize=size)

    def value(name, x, y, s, size=11):
        wdt = text(x, y, s, size)
        fields[name] = dict(value=s, page=0, box=[round(x, 3), round(y - CAP * size, 3), round(wdt, 3), round((CAP + DESC) * size, 3)])

    def cell(x0, y0, x1, y1, label):
        page.draw_rect(pymupdf.Rect(x0, y0, x1, y1), color=rule, width=0.8)
        text(x0 + 6, y0 + 12, label, 8, color=grey)

    # header
    text(48, 66, "BILL OF LADING", 20, "hebo")
    text(48, 82, "Straight bill of lading, not negotiable", 9, color=grey)
    text(372, 58, "Shipment no.", 9, color=grey)
    value("shipment_no", 446, 58, str(r["id"]))
    text(372, 78, "Date", 9, color=grey)
    value("date", 446, 78, SHIP_DATE)
    page.draw_line((48, 96), (564, 96), color=ink, width=1.2)
    # parties
    cell(48, 108, 304, 182, "Shipper")
    text(54, 138, "Harbor Point Distribution", 11)
    text(54, 154, "Dock 4, 1200 Wharf Road", 9, color=grey)
    text(54, 168, "Oakland, CA 94607", 9, color=grey)
    cell(308, 108, 564, 182, "Consignee")
    value("consignee", 314, 138, r["consignee"])
    text(314, 154, f"Receiving, Unit {10 + r['id'] % 80}", 9, color=grey)
    text(314, 168, "Sacramento, CA 95814", 9, color=grey)
    # transport
    cell(48, 188, 220, 230, "Carrier")
    value("carrier", 54, 218, r["carrier"])
    cell(224, 188, 392, 230, "Trailer no.")
    text(230, 218, r["trailer"], 11)
    cell(396, 188, 564, 230, "Seal no.")
    text(402, 218, r["seal"], 11)
    # goods
    cell(48, 236, 160, 290, "Pallets")
    value("pallets", 54, 270, str(r["pallets"]))
    cell(164, 236, 280, 290, "Weight (lb)")
    text(170, 270, r["weight"], 11)
    cell(284, 236, 564, 290, "Description of goods")
    text(290, 266, "Mixed retail goods, stretch wrapped", 10)
    text(290, 280, "Freight class 70, NMFC 156600", 9, color=grey)
    # exceptions
    cell(48, 296, 564, 350, "Exceptions")
    value("exceptions", 54, 328, r["exceptions"])
    # terms (small print)
    terms = ["Received, subject to the classifications and tariffs in effect on the date of issue, the property",
             "described above in apparent good order, except as noted, marked, consigned and destined as shown.",
             "The receiver signs below to confirm the count and the condition of the goods on arrival."]
    for i, s in enumerate(terms):
        text(48, 376 + 12 * i, s, 8, color=grey)
    # signature
    page.draw_line((48, 470), (300, 470), color=ink, width=0.8)
    sig = random.Random(r["id"])  # a scrawl over the signature line (ink, not text)
    pts = [pymupdf.Point(60 + 9 * i, 462 - sig.uniform(0, 14) * (1 if i % 2 else 0.4)) for i in range(18)]
    page.draw_polyline(pts, color=(0.12, 0.20, 0.55), width=1.1)
    text(48, 482, "Receiver signature", 8, color=grey)
    text(330, 466, "Signed by", 9, color=grey)
    value("signed_by", 382, 466, r["signed_by"])
    page.draw_line((330, 470), (564, 470), color=rule, width=0.6)
    text(48, 760, f"Harbor Point Distribution · form HPD-7 · {r['id']}", 7, color=grey)

    doc.set_metadata({"title": f"Bill of lading {r['id']}", "author": "Harbor Point Distribution", "subject": "",
                      "keywords": "", "creator": "claims_data.py", "producer": "PyMuPDF",
                      "creationDate": "D:20261014120000Z", "modDate": "D:20261014120000Z"})
    doc.del_xml_metadata()
    doc.save(path, garbage=3, deflate=True, no_new_id=True)
    doc.close()
    return fields


# --- main ------------------------------------------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: claims_data.py OUT")
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "bol").mkdir(exist_ok=True)
    rng = random.Random(SEED)

    pallets, recs, merged, checks, geom = md.build_warehouse(out)
    (out / "warehouse.mp4").replace(out / "dock.mp4")

    rows = shipments(recs, rng)
    write_shipments(out, rows)
    first = {r["code"]: r["first"] for r in recs}
    damage_frame = {str(r["id"]): first[r["id"]] for r in rows if r["damaged"]}
    write_log(out, damage_frame.values(), md.WH_SECONDS, rng)

    bols = []
    for r in rows:
        if r["status"] not in ("delivered", "claim"):
            continue
        name = f"BOL-{r['id']}.pdf"
        fields = bol_pdf(out / "bol" / name, r)
        bols.append(dict(file=name, shipment=str(r["id"]), fields=fields))
    # (shipment ids as text, as damage_frame's keys already are and as a CSV reads them back: D-1266)
    disputed = sorted(str(r["id"]) for r in rows if r["damaged"] and r["exceptions"] == "None")

    visible = [r for r in recs if r["code_visible"]]
    hidden = [r for r in recs if not r["code_visible"]]
    truth = dict(
        bols=bols,
        disputed=disputed,
        damage_frame=damage_frame,
        log_offset_s=LOG_OFFSET_S,
        log=dict(file="forklift_log.csv", hz=LOG_HZ, clock="log t = video t + log_offset_s"),
        shipments=dict(file="shipments.csv", key="shipment_id", joins="dock.mp4 rows' code (the stripe code's integer)",
                       on_camera_readable=sorted(r["code"] for r in visible), on_camera_hidden=sorted(r["code"] for r in hidden),
                       never_on_camera=sorted(r["id"] for r in rows if not r["seen"]), total=len(rows)),
        bol_box="value ink box in PDF points, origin top left: cap height (0.718 em) above the baseline to the "
                "descender (0.207 em) below, across the advance width",
        warehouse=dict(
            video="dock.mp4", size=[md.W, md.H], fps=md.FPS, frames=md.WH_SECONDS * md.FPS,
            pallets=visible, hidden_pallets=hidden,
            damaged_intervals=[[round(s / md.FPS, 6), round(e / md.FPS, 6)] for s, e in merged],
            damaged_frames=merged,
            code_spec=dict(cell_px=md.CELL, cells=19, start=[1, 0, 1], id_bits=12, parity="even over the 12 id bits",
                           stop=[1, 0, 1], label_size=[md.LABEL_W, md.LABEL_H], bars_height=34, digits=4,
                           damage_colour_rgb=list(md.TEAR)),
        ),
    )
    (out / "truth.json").write_text(json.dumps(truth, indent=1, sort_keys=True) + "\n")
    print(f"claims data: {len(bols)} BOLs, {len(disputed)} disputed, {len(rows)} shipments -> {out}")


if __name__ == "__main__":
    main()
