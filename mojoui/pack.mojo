# mojoui.pack: export a pack, a PDF per item and a video clip beside it (goal 41 M10). A generic component: an app says
# what each item's pages hold (facts, words, a table, a PDF page with boxes marked, a video frame with boxes marked, a
# picture) and which clip of which video goes with it (a time range; faces blurred; a caption burned in); one job writes
# them all, off the UI thread, and wakes the UI when done. Nothing here knows what the pack is for: an insurance claim,
# an inspection report, an audit trail are the same blocks.
#
#   var p = Pack("Shipment 2417", "claim pack · dock.mp4")
#   p.page("Evidence")
#   p.facts([("Shipment", "2417"), ("Damaged at", "0:05.3")])
#   p.video_frame("dock.mp4", 5.33, [Box(500, 300, 132, 74)], "frame 160: the pallet, damaged")
#   p.page("Bill of lading")
#   p.pdf_page("bol/BOL-2417.pdf", 0, [Box(54, 320, 26, 10)], "Exceptions: None")
#   var job = PackJob(found)                     # found: the video's analysis rows (for the faces a clip blurs)
#   job.add(p^, "pack/2417.pdf"); job.clip(Clip("dock.mp4", "pack/2417.mp4", 3.8, 9.8, "Shipment 2417 · {t}", True))
#   var running = start_ui_job(job^)             # → Packed: the files written, how long it took
#
# The PDF: mojoui.packpdf (Pack, write_pack_pdf: pack_pdf.py prints it with Playwright's Chromium, as its own process). A
# clip: mojoui.videojobs.make_reel over one segment (a reel's redaction plan: faces blurred, the flagged thing outlined).

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.packpdf import Pack, write_pack_pdf
from mojoui.pdfsource import Box
from mojoui.videotable import VideoTable
from mojoui.videoexport import Caption
from mojoui.videojobs import make_reel
from mojoui.clock import now_ns


@fieldwise_init
struct Clip(Copyable, Movable):
    """A video clip beside an item: `source` from `start` to `end` seconds into `path`, the rows' faces blurred (blur),
    `caption` burned in ("{t}" in it: the frame's source time)."""

    var source: String
    var path: String
    var start: Float64
    var end: Float64
    var caption: String
    var blur: Bool


struct Packed(Movable):
    """What a pack job wrote: its PDFs and clips (paths) and how long it took."""

    var pdfs: List[String]
    var clips: List[String]
    var milliseconds: Float64

    def __init__(out self):
        self.pdfs = List[String]()
        self.clips = List[String]()
        self.milliseconds = 0


struct PackJob(JobBody):
    """Every PDF, then every clip; progress counts the items."""
    comptime Out = Packed
    var packs: List[Pack]
    var paths: List[String]
    var clips: List[Clip]
    var found: VideoTable  # the rows a clip blurs faces by (kind "face"), and whose damaged rows it outlines

    def __init__(out self, found: VideoTable):
        self.packs = List[Pack]()
        self.paths = List[String]()
        self.clips = List[Clip]()
        self.found = found.copy()

    def add(mut self, var pack: Pack, path: String):
        self.packs.append(pack^)
        self.paths.append(path)

    def clip(mut self, c: Clip):
        self.clips.append(c.copy())

    def run(mut self, ctl: JobCtl) raises -> Packed:
        var t0 = now_ns()
        var out = Packed()
        ctl.add_total(len(self.packs) + len(self.clips))
        for i in range(len(self.packs)):
            ctl.check()
            write_pack_pdf(self.packs[i], self.paths[i])
            out.pdfs.append(self.paths[i])
            ctl.advance(1)
        for ref c in self.clips:
            ctl.check()
            var fps = self.found.fps if self.found.fps > 0 else 30.0
            var captions = List[Caption]()
            if c.caption != "":
                captions.append(Caption(Int(c.start * fps), Int(c.end * fps) + 1, c.caption))
            var mark = String("")
            for r in range(self.found.rows()):
                if self.found.damaged[r]:
                    mark = self.found.kind[r]
                    break
            var segs = List[Tuple[Float64, Float64]]()
            segs.append((max(c.start, 0.0), c.end))
            _ = make_reel(c.source, c.path, self.found, segs, "face" if c.blur else "", mark, captions)
            out.clips.append(c.path)
            ctl.advance(1)
        out.milliseconds = Float64(now_ns() - t0) / 1e6
        return out^
