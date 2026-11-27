# mojoui.mediafiles (goal 82 M3): content-addressed pictures and data URLs by Personal Note's rules (media_store.py): the
# same bytes the same name, written once; names that aren't <sha256>.<ext> are never read; data URLs both ways (base64 and
# percent-encoded SVG), sizes and types refused as the web refuses them. mediafiles: ok
from std.testing import assert_true, assert_equal
from std.os import makedirs
from mojoui.mediafiles import put_media, read_media, data_url, decode_data_url, sniff_image, media_name_ok, b64_decode, MAX_MEDIA_BYTES
from mojoui.files import remove_tree
from mojoui.hash import sha256_hex


def main() raises:
    var dir = String("build/test_mediafiles/media")
    remove_tree("build/test_mediafiles")
    var png = List[UInt8]()
    for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 250]:
        png.append(UInt8(b))
    assert_equal(sniff_image(png), "png")
    var name = put_media(dir, png, "png")
    assert_true(name.startswith("media/") and name.endswith(".png") and name.byte_length() == 6 + 64 + 4, name)
    assert_equal(put_media(dir, png, "png"), name, "the same bytes, the same name")
    var back = read_media(dir, name)
    assert_true(back and back.value() == png, "read back")
    assert_true(not read_media(dir, "media/../../etc/passwd"), "not a media name")
    assert_true(not media_name_ok("abc.png") and not media_name_ok(String("a") * 64 + ".exe"), "names")
    # data URLs
    var url = data_url(png, "png")
    assert_true(url.startswith("data:image/png;base64,"), url)
    var d = decode_data_url(url)
    assert_true(d and d.value()[0] == png and d.value()[1] == "png", "base64 both ways")
    var svg = decode_data_url("data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns%3D%22x%22%2F%3E")
    assert_true(svg and String(from_utf8_lossy=Span(svg.value()[0])) == '<svg xmlns="x"/>' and svg.value()[1] == "svg", "percent-encoded svg")
    assert_true(decode_data_url("data:image/jpeg;base64,/9j/") and decode_data_url("data:image/jpeg;base64,/9j/").value()[1] == "jpg", "jpeg is jpg")
    assert_true(not decode_data_url("data:text/html;base64,PGI+"), "not a picture")
    assert_true(not decode_data_url("data:image/png;base64,@@@="), "not base64")
    assert_true(not decode_data_url("data:image/png;base64,"), "empty")
    var b = b64_decode("aGVsbG8=")
    assert_true(b and String(from_utf8_lossy=Span(b.value())) == "hello", "base64")
    assert_true(not b64_decode("aGVsbG8"), "unpadded is refused, as Python's validate=True")
    print("mediafiles: ok", flush=True)
