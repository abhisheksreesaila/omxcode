# mojoui.grounding's reading of the model's words (goal 77 M6): no model needed.
#   scripts/mxbuild.sh tests/test_grounding.mojo -o build/test_grounding && build/test_grounding
from std.testing import assert_equal, assert_true
from mojoui.grounding import parse_sight, image_size, iou, Box


def near(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 0.01


def main() raises:
    # the model's own words (the shape the scene's banana came back in, inside a code fence), 0-1000 coordinates on 1280x720
    var s = parse_sight(
        'Sure:\n```json\n{"answer": "The banana is in the middle.", "objects": [{"label": "banana", "bbox_2d": [429, 306, 654, 744]},'
        ' {"label": "cup", "bbox_2d": [131, 381, 314, 665]}]}\n```',
        1280, 720,
    )
    assert_equal(s.problem, "")
    assert_equal(s.answer, "The banana is in the middle.")
    assert_equal(len(s.boxes), 2)
    assert_equal(s.boxes[0].label, "banana")
    assert_true(near(s.boxes[0].x0, 549.12) and near(s.boxes[0].y0, 220.32) and near(s.boxes[0].x1, 837.12) and near(s.boxes[0].y1, 535.68), "pixels: " + String(s.boxes[0].x0) + "," + String(s.boxes[0].y0) + "," + String(s.boxes[0].x1) + "," + String(s.boxes[0].y1))
    assert_equal(s.find("Banana"), 0)
    assert_equal(s.find("cup"), 1)
    assert_equal(s.find("a cup of tea"), 1)  # (a label held by the word asked for)
    assert_equal(s.find("spoon"), -1)
    assert_equal(s.labels(), "banana, cup")

    # a reply in pixels (a number past 1000) is read as pixels
    var px = parse_sight('{"answer": "x", "objects": [{"label": "bottle", "bbox_2d": [990, 138, 1113, 504]}]}', 1280, 720)
    assert_equal(len(px.boxes), 1)
    assert_true(near(px.boxes[0].x0, 990.0) and near(px.boxes[0].y1, 504.0), "pixels stay pixels")

    # what the model may get wrong is validated away: a missing number, an inverted box, a speck, no label, a twin, an over-long label
    var bad = parse_sight(
        '{"answer": "ok", "objects": ['
        '{"label": "a", "bbox_2d": [10, 10, 500]},'
        '{"label": "b", "bbox_2d": [500, 500, 100, 100]},'
        '{"label": "c", "bbox_2d": [10, 10, 12, 12]},'
        '{"label": "", "bbox_2d": [10, 10, 500, 500]},'
        '{"label": "d", "bbox_2d": [100, 100, 500, 500]},'
        '{"label": "D", "bbox_2d": [101, 101, 501, 501]},'
        '{"label": "an extremely long label that no person would ever say about a thing", "bbox_2d": [10, 10, 500, 500]},'
        '{"label": "e", "bbox_2d": [-50, 900, 1000, 1080]}]}',
        1000, 1000,
    )
    assert_equal(len(bad.boxes), 2)
    assert_equal(bad.boxes[0].label, "d")
    assert_equal(bad.boxes[1].label, "e")
    assert_true(near(bad.boxes[1].x0, 0.0) and near(bad.boxes[1].y1, 1000.0), "clamped into the picture")
    assert_equal(bad.dropped, 6)

    # words that aren't JSON say so; a bare list of boxes is read too
    assert_equal(parse_sight("I cannot see anything.", 100, 100).problem, "the model didn't answer in JSON")
    var bare = parse_sight('[{"label": "x", "bbox_2d": [0, 0, 500, 500]}]', 200, 100)
    assert_equal(len(bare.boxes), 1)
    assert_true(near(bare.boxes[0].x1, 100.0) and near(bare.boxes[0].y1, 50.0), "a bare list")

    assert_true(near(iou(Box("a", 0, 0, 10, 10), Box("b", 5, 5, 15, 15)), 25.0 / 175.0), "iou")
    assert_true(near(iou(Box("a", 0, 0, 10, 10), Box("b", 20, 20, 30, 30)), 0.0), "iou apart")

    # a PNG's and a JPEG's sizes from their headers
    var png = List[UInt8]()
    for b in [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 5, 0, 0, 0, 2, 208, 8, 6, 0, 0, 0]:
        png.append(UInt8(b))
    assert_equal(image_size(png)[0], 1280)
    assert_equal(image_size(png)[1], 720)
    var jpg = List[UInt8]()
    for b in [255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 255, 192, 0, 17, 8, 1, 224, 2, 128, 3, 1, 34, 0, 2, 17, 1, 3, 17, 1]:
        jpg.append(UInt8(b))
    assert_equal(image_size(jpg)[0], 640)
    assert_equal(image_size(jpg)[1], 480)
    assert_equal(image_size(List[UInt8](length=30, fill=7))[0], 0)
    print("grounding: ok")
