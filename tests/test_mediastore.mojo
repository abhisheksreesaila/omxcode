# mojoui.mediastore (goal 82 M2): the web's picture rules (media_store.py, media.js) and a picture's node in a canvas document.
#   pixi run mojo run -I . -I vendor tests/test_mediastore.mojo <scratch-dir>
from mojoui.mediastore import (sniff_image, image_size, fit_image, storage_plan, MediaStore, prepare_picture, prepare_bytes, place_picture,
    media_name_ok, shrink, encode_png_small, read_file)
from mojoui.png import encode_png
from mojoui.jpeg import encode_jpeg
from mojoui.hash import sha256, hex
from mojoui.objectlayer import ObjectLayer, export_json_canvas, import_json_canvas, PICTURE
from std.sys import argv


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("FAIL: " + what)
    print("ok  " + what)


def picture(w: Int, h: Int, alpha: Bool) -> List[UInt32]:
    var px = List[UInt32](capacity=w * h)
    for y in range(h):
        for x in range(w):
            var a = UInt32(255) if not alpha or x > 4 else UInt32(80)
            px.append(UInt32((x * 7) % 256) | (UInt32((y * 3) % 256) << 8) | (UInt32((x + y) % 256) << 16) | (a << 24))
    return px^


def write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(data))


def main() raises:
    var dir = String(argv()[1]) if len(argv()) > 1 else String("/tmp")
    var png = encode_png(picture(40, 30, False), 40, 30)
    var jpg = encode_jpeg(picture(64, 48, False), 64, 48, 85)
    check(sniff_image(png) == "png" and sniff_image(jpg) == "jpg", "a picture's kind from its own bytes")
    var gif: List[UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 3, 0, 2, 0, 0, 0, 0]
    check(sniff_image(gif) == "gif" and image_size(gif)[0] == 3 and image_size(gif)[1] == 2, "a GIF's kind and size")
    var svg = List[UInt8]()
    for b in String("<svg xmlns='http://www.w3.org/2000/svg'/>").as_bytes():
        svg.append(b)
    check(sniff_image(svg) == "", "SVG is never a picture from outside (it can carry script)")
    check(image_size(png)[0] == 40 and image_size(png)[1] == 30 and image_size(jpg)[0] == 64 and image_size(jpg)[1] == 48, "sizes from the first bytes")
    check(fit_image(2000, 1000)[0] == 1400 and fit_image(2000, 1000)[1] == 700, "2000x1000 fits as 1400x700")
    check(fit_image(1401, 3)[1] == 3 and fit_image(3, 1401)[0] == 3, "Math.round: 2.997 is 3")
    check(fit_image(1400, 900)[0] == 1400, "1400 stays")
    check(storage_plan(40, 30, len(png), "png").keep, "a small PNG is stored as it came")
    check(not storage_plan(40, 30, 400 * 1024, "png").keep, "over 300 KB: written again")
    check(not storage_plan(40, 30, 100, "gif").keep, "a GIF is always written again (frozen)")
    check(storage_plan(20000, 6000, 100, "png").too_big, "over 100 megapixels: refused")
    check(media_name_ok("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.png") and not media_name_ok("../x.png") and not media_name_ok("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg.png"), "only <sha256>.<ext> names reach the disk")
    var store = MediaStore(dir + "/media")
    var name = store.put(png, "png")
    check(name == "media/" + hex(sha256(Span(png))) + ".png", "stored under media/<sha256>.<ext>")
    check(store.put(png, "png") == name, "the same bytes: the same file, once")
    var back = read_file(store.file(name))
    check(len(back) == len(png) and hex(sha256(Span(back))) == hex(sha256(Span(png))), "the file holds the bytes")
    # prepared by the rules: a small PNG as it came; a big opaque picture as a 1400 JPEG; a big see-through one as a 1400 PNG
    write(dir + "/small.png", png)
    var p1 = prepare_picture(dir + "/small.png")
    check(p1.ext == "png" and len(p1.bytes) == len(png) and p1.width == 40, "small PNG kept byte for byte")
    write(dir + "/big.png", encode_png_small(picture(2000, 1500, False), 2000, 1500))
    var p2 = prepare_picture(dir + "/big.png")
    check(p2.ext == "jpg" and p2.width == 1400 and p2.height == 1050 and sniff_image(p2.bytes) == "jpg", "a big opaque picture: 1400x1050 JPEG")
    write(dir + "/bigalpha.png", encode_png_small(picture(1600, 800, True), 1600, 800))
    var p3 = prepare_picture(dir + "/bigalpha.png")
    check(p3.ext == "png" and p3.width == 1400 and p3.height == 700, "see-through stays PNG: 1400x700")
    write(dir + "/notes.txt", List[UInt8](length=10, fill=65))
    var refused = False
    try:
        _ = prepare_picture(dir + "/notes.txt")
    except e:
        refused = String(e) == "That is not a PNG, JPEG, WebP or GIF picture"
    check(refused, "not a picture: the web's words")
    var sh = shrink(picture(4, 4, False), 4, 4, 2, 2)
    check(len(sh) == 4, "shrink by area")
    # placed: 520 at most, centred, the next 28 on
    var pl = place_picture(1400, 1050, 500, 400, 0)
    check(abs(pl.scale - 520.0 / 1400.0) < 1e-9 and abs(pl.x - (500 - 700)) < 1e-9 and abs(pl.y - (400 - 525)) < 1e-9, "placed as the web's newImage: the unscaled box's corner, scale 520/1400")
    var pl2 = place_picture(100, 50, 500, 400, 1)
    check(pl2.scale == 1 and abs(pl2.x - (500 + 28 - 50)) < 1e-9, "a small one isn't enlarged; the second 28 down and right")
    # a picture's node, as the web writes it, read and written back
    var l = ObjectLayer()
    var sw = 1400.0 * pl.scale
    var shh = 1050.0 * pl.scale
    _ = l.add_stored_picture(pl.x + 700 - sw / 2, pl.y + 525 - shh / 2, sw, shh, List[UInt32](), 1400, 1050, name)
    var doc = export_json_canvas(l)
    check(doc.find('"type":"file"') >= 0 and doc.find('"file":"' + name + '"') >= 0 and doc.find('"pn":{"type":"image"') >= 0 and doc.find('"width":1400') >= 0, "written as a file node with pn.type image, natural size")
    var l2 = import_json_canvas(doc)
    check(len(l2.objs) == 1 and l2.objs[0].kind == PICTURE and l2.objs[0].file == name and l2.objs[0].pw == 1400 and abs(l2.objs[0].w - sw) < 0.01, "read back: the same picture, the same box")
    var web = '{"nodes":[{"id":"img1","type":"file","x":-200,"y":-125,"width":1400,"height":1050,"file":"' + name + '","pn":{"type":"image","geometry":{"x":-200,"y":-125,"width":1400,"height":1050,"scaleX":0.37142857142857144,"scaleY":0.37142857142857144,"rotation":0,"flipX":false,"flipY":false,"skewX":0,"skewY":0},"extras":{}}}],"edges":[]}'
    var l3 = import_json_canvas(web)
    check(len(l3.objs) == 1 and l3.objs[0].kind == PICTURE and abs(l3.objs[0].x - (500 - 260)) < 0.01 and abs(l3.objs[0].w - 520) < 0.01, "the web's own node: shown at 520 about its centre")
    l3.selected = [l3.objs[0].id]
    l3.move_by(10, 0)
    var moved = export_json_canvas(l3)
    check(moved.find('"x":-190') >= 0 and moved.find('"width":1400') >= 0 and moved.find('"scaleX":0.37142857142857144') >= 0, "moved: its corner moves, its natural size and scale stay")
    print("test_mediastore: all passed")
