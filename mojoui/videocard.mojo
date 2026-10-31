# mojoui.videocard: a video card's work, Analyze / Make a reel / Edit (goal 41 M4), taken out of omxplorer so any app
# with MediaCards (mojoui.mediacard) gets the same flow: one analysis at a time over a card's video (mojoui.videojobs, a
# job that wakes the UI), its progress on the card, its rows kept (found) and its boxes on the card's player; a reel of
# the frames where a table's flag is true, cut in a job; an editor opened from the card's player (MediaTimeline.open_with)
# given the rows as lanes, or the analysis started for it and the chips shown meanwhile. The app only places what lands
# (where the rows' table goes, the reel's new card) and says it.
#
#   var video = VideoWork()
#   video.analyze(media, k, which, log)                 # False: one runs already, or it needs a log (video.problem says)
#   on App.jobs_message / frames:
#       var p = video.progress(media)                  # (share, words) while a job runs, for the app's island; the card shows it too
#       var a = video.take_analysis(media)             # Optional[Analyzed]: rows kept in video.found, marks on the player
#       var r = video.take_reel(media)                 # Optional[Reel]
#   video.reel(media, k, sheet, flag, captions, blur, reel_path)   # the frames where `flag` is true in `sheet` (a frame column)
#   var ed = MediaTimeline.open_with(card's player.info, msg_base, canvas_base, at=t, log=log, room_w=w, room_h=h)
#   video.prepare_editor(ed, media, k, log)             # its rows as lanes, or its analysis started (chips meanwhile)
#   video.feed_editor(ed)                              # rows that landed while the editor was open become its lanes

from omxcore import Job, JobProgress, JOB_RUNNING
from mojoui.charts import grouped
from mojoui.files import file_name
from mojoui.mediacard import MediaCards
from mojoui.mediatimeline import MediaTimeline
from mojoui.sheet import Sheet
from mojoui.timeseries import TimeSeries
from mojoui.videoexport import Caption
from mojoui.videojobs import (Analyzed, Reel, analyze_job, reel_job, analyzer_names, analyzer_needs_log, use_analysis, expect_analysis,
                              marks_of, flag_frames, segments_of, INSPECTION)
from mojoui.videotable import VideoTable


struct VideoWork(Movable):
    """The page's video work: one analysis and one reel at a time, and the last analysis' rows."""

    var analyzing: Optional[Job[Analyzed]]
    var analyzing_path: String
    var analyzing_which: Int
    var reeling: Optional[Job[Reel]]
    var reeling_path: String
    var found: VideoTable  # the last analysis' rows
    var found_path: String  # its video ("": none yet)
    var found_which: Int  # its analyzer
    var problem: String  # why the last ask was refused or a job failed ("": none)

    def __init__(out self):
        self.analyzing = None
        self.analyzing_path = ""
        self.analyzing_which = 0
        self.reeling = None
        self.reeling_path = ""
        self.found = VideoTable()
        self.found_path = ""
        self.found_which = 0
        self.problem = ""

    def busy(self) -> Bool:
        return Bool(self.analyzing) or Bool(self.reeling)

    def forget(mut self):
        """A new page: the rows go (a running job's answer still lands; the app may ignore it)."""
        self.found = VideoTable()
        self.found_path = ""

    def has_rows(self, path: String) -> Bool:
        return self.found_path == path and self.found.rows() > 0

    # ---------- analyze ----------

    def analyze(mut self, mut media: MediaCards, k: Int, which: Int, var log: Optional[TimeSeries] = None) -> Bool:
        """Analyzer `which` (videojobs.ANALYZERS) over card k's video as a job; the card says "Analyzing" and how far.
        False (problem says why): one runs already, or the analyzer needs the recording's log and there is none."""
        if self.analyzing:
            self.problem = "Already analyzing " + file_name(self.analyzing_path) + ": one video at a time"
            return False
        if k < 0 or k >= len(media):
            return False
        ref c = media.cards[k]
        if analyzer_needs_log(which) and not log:
            self.problem = analyzer_names()[which] + " needs the flight's log: insert a CSV with t, lat and lon beside " + file_name(c.path)
            return False
        self.analyzing = analyze_job(c.path, which, log^)
        self.analyzing_path = c.path
        self.analyzing_which = which
        c.status = "Analyzing"
        c.progress = 0
        return True

    def progress(mut self, mut media: MediaCards) -> Tuple[Float64, String]:
        """How far the running job is (share 0–1 and words: "42% · 365 of 870 frames"); the card's percent follows.
        (-1, "") when nothing runs."""
        if self.analyzing and self.analyzing.value().poll() == JOB_RUNNING:
            return self._progress(media, self.analyzing.value().progress(), self.analyzing_path)
        if self.reeling and self.reeling.value().poll() == JOB_RUNNING:
            return self._progress(media, self.reeling.value().progress(), self.reeling_path)
        return (-1.0, String(""))

    def _progress(self, mut media: MediaCards, p: JobProgress, path: String) -> Tuple[Float64, String]:
        var share = min(Float64(p.done) / Float64(p.total), 1.0) if p.total > 0 else 0.0
        var k = media.card_of(path)
        if k >= 0:
            media.cards[k].progress = Int(share * 100)
        return (share, String(Int(share * 100)) + "% · " + grouped(p.done) + " of " + grouped(p.total) + " frames")

    def take_analysis(mut self, mut media: MediaCards) -> Optional[Analyzed]:
        """The analysis' answer once its job has ended: its rows kept (found), the card's status cleared and its player
        marking what was found (faces left unmarked: they're blurred, not boxed). None while it runs, or when it failed
        (problem says why)."""
        if not self.analyzing or self.analyzing.value().poll() == JOB_RUNNING:
            return None
        var job = self.analyzing.take()
        var k = media.card_of(self.analyzing_path)
        if k >= 0:
            media.cards[k].status = ""
        try:
            var a = job.result()
            self.found = a.take_found()
            self.found_path = self.analyzing_path
            self.found_which = a.analyzer
            if k >= 0 and media.cards[k].player:
                media.cards[k].player.value().set_marks(marks_of(self.found, "face"))
            return a^
        except e:
            self.problem = "Couldn't analyze " + file_name(self.analyzing_path) + ": " + String(e)
            return None

    # ---------- reels ----------

    def reel(mut self, mut media: MediaCards, k: Int, sheet: Sheet, flag: Int, captions: List[Caption], blur: Bool, reel_path: String) -> Bool:
        """A reel of card k's video: the frames where `flag` is true in `sheet` (its frame column), the analysis' faces
        blurred (blur), its flagged kind outlined, the captions burned in, written to `reel_path` by a job. False (problem
        says why): one runs already, no rows for this video, or no frame has the flag."""
        if self.reeling:
            self.problem = "Already making a reel of " + file_name(self.reeling_path)
            return False
        ref c = media.cards[k]
        if not self.has_rows(c.path):
            self.problem = "Analyze " + file_name(c.path) + " first: a reel keeps the frames where a column of its rows is true"
            return False
        var runs = flag_frames(sheet, flag, sheet.index("frame"))
        if len(runs) == 0:
            self.problem = "No frame has " + sheet.name(flag) + ": nothing to cut"
            return False
        var mark = String("")
        for i in range(self.found.rows()):
            if self.found.damaged[i]:
                mark = self.found.kind[i]
                break
        self.reeling = reel_job(c.path, reel_path, self.found, segments_of(runs, self.found.fps), "face" if blur else "", mark, captions)
        self.reeling_path = c.path
        c.status = "Making a reel"
        c.progress = 0
        return True

    def flagged_kind(self) -> String:
        """The kind a flag marks: the first flagged row's (else the first row's, else "object")."""
        for i in range(self.found.rows()):
            if self.found.damaged[i]:
                return self.found.kind[i]
        return self.found.kind[0] if self.found.rows() > 0 else String("object")

    def take_reel(mut self, mut media: MediaCards) -> Optional[Reel]:
        if not self.reeling or self.reeling.value().poll() == JOB_RUNNING:
            return None
        var job = self.reeling.take()
        var k = media.card_of(self.reeling_path)
        if k >= 0:
            media.cards[k].status = ""
        try:
            return job.result()
        except e:
            self.problem = "Couldn't make the reel: " + String(e)
            return None

    # ---------- the editor ----------

    def prepare_editor(mut self, mut ed: MediaTimeline, mut media: MediaCards, k: Int, var log: Optional[TimeSeries] = None):
        """An editor the app just opened on card k's video (MediaTimeline.open_with from its player's info): the rows as
        lanes when this video was analyzed, else its analysis started now (the warehouse preset, or the inspection when
        it has a log) with the chips shown meanwhile. The card's player pauses (the editor plays now)."""
        ref c = media.cards[k]
        if c.player:
            c.player.value().state.pause()
        var path = c.path
        if self.has_rows(path):
            use_analysis(ed, self.found, self.found_which)
        elif not self.analyzing or self.analyzing_path == path:
            var which = INSPECTION if Bool(log) else 0
            if not self.analyzing:
                _ = self.analyze(media, k, which, log^)
            else:
                which = self.analyzing_which
            expect_analysis(ed, which)

    def feed_editor(self, mut ed: MediaTimeline):
        """Rows that landed for the editor's video while it was open: its lanes and chips."""
        if self.has_rows(ed.path()) and not ed.table:
            use_analysis(ed, self.found, self.found_which)
