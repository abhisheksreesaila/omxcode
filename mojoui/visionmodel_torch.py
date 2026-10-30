"""mojoui.visionmodel_torch: backend (A) of mojoui/visionmodel.mojo, PyTorch + Hugging Face transformers in the same
process (goal 39 M12 spike, D-940..). Mojo calls it through `std.python`; nothing here knows about any app or footage.

    det = Detector("google/owlv2-base-patch16-ensemble", device="cuda", half=True)
    rows = det.detect_address(addr, width, height, ["a cardboard box", "a torn package"], threshold=0.2)
    # rows: one flat list of floats, 6 per box: x, y, w, h, score, prompt index (pixels of the original frame)

    seg = Segmenter("facebook/sam2.1-hiera-tiny", device="cuda")
    seg.start(width, height)                    # a streaming video session
    seg.add_box(frame_index, obj_id, x, y, w, h)  # on a keyframe
    masks = seg.step_address(addr, width, height)  # per frame: {obj_id: (box, area)} and the masks on the GPU

Frames arrive as an address of RGBA bytes (row by row, R first, as mojoui.video gives them). `from_address` wraps it
with numpy without copying (ctypes), then ONE copy goes to the GPU (pinned staging buffer, async), and everything after
that (pad, resize, normalise) runs on the GPU. Models load from the Hugging Face cache (HF_HOME); omxconsole's model
packs can later point `name` at a local folder instead.
"""

import ctypes
import time

import numpy as np
import torch
import torch.nn.functional as F

CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)


def from_address(addr, width, height):
    """A (height, width, 4) uint8 numpy view of `addr` (no copy). The caller keeps the memory alive."""
    buf = (ctypes.c_uint8 * (width * height * 4)).from_address(int(addr))
    return np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)


class _Upload:
    """One pinned host buffer per frame size; a frame goes host -> pinned (memcpy) -> GPU (DMA)."""

    def __init__(self, device):
        self.device = torch.device(device)
        self.pinned = None
        self.last_ms = 0.0

    def __call__(self, addr, width, height):
        t0 = time.perf_counter()
        view = torch.from_numpy(from_address(addr, width, height))
        if self.device.type != "cuda":
            out = view.clone()
        else:
            if self.pinned is None or self.pinned.shape != view.shape:
                self.pinned = torch.empty(view.shape, dtype=torch.uint8, pin_memory=True)
            self.pinned.copy_(view)
            out = self.pinned.to(self.device, non_blocking=True)
            torch.cuda.synchronize()
        self.last_ms = (time.perf_counter() - t0) * 1000
        return out  # (H, W, 4) uint8 on the device


class Detector:
    """Open-vocabulary detection (OWLv2 / OWL-ViT): boxes for text prompts."""

    def __init__(self, name, device="cuda", half=True):
        from transformers import AutoProcessor, Owlv2ForObjectDetection

        t0 = time.perf_counter()
        self.device = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
        self.dtype = torch.float16 if (half and self.device.type == "cuda") else torch.float32
        self.processor = AutoProcessor.from_pretrained(name)
        self.model = Owlv2ForObjectDetection.from_pretrained(name, dtype=self.dtype).to(self.device).eval()
        self.side = int(self.processor.image_processor.size["height"])  # 960 for owlv2-base
        self.mean = torch.tensor(CLIP_MEAN, device=self.device).view(1, 3, 1, 1)
        self.std = torch.tensor(CLIP_STD, device=self.device).view(1, 3, 1, 1)
        self.upload = _Upload(self.device)
        self._prompts = None
        self._text = None
        self.load_ms = (time.perf_counter() - t0) * 1000
        self.model_ms = 0.0

    def _text_inputs(self, prompts):
        prompts = [str(p) for p in prompts]
        if prompts != self._prompts:
            t = self.processor(text=[prompts], return_tensors="pt", padding="max_length", truncation=True)
            self._text = {k: v.to(self.device) for k, v in t.items()}
            self._prompts = prompts
        return self._text

    def _pixels(self, frames):
        """(B, H, W, 4) uint8 on the device -> (B, 3, side, side) normalised, padded to a square at the bottom/right
        with grey (what Owlv2ImageProcessor does on the CPU, here on the GPU)."""
        x = frames[..., :3].permute(0, 3, 1, 2).float() / 255.0
        b, _, h, w = x.shape
        s = max(h, w)
        x = F.pad(x, (0, s - w, 0, s - h), value=0.5)
        x = F.interpolate(x, size=(self.side, self.side), mode="bilinear", align_corners=False, antialias=True)
        return ((x - self.mean) / self.std).to(self.dtype)

    @torch.inference_mode()
    def detect_frames(self, frames, prompts, threshold=0.2):
        """frames: (B, H, W, 4) uint8 tensor on the device. Returns a list (one per frame) of (N, 6) float tensors on
        the CPU: x, y, w, h, score, prompt index, in the frame's pixels."""
        text = self._text_inputs(prompts)
        b, h, w = frames.shape[0], frames.shape[1], frames.shape[2]
        t0 = time.perf_counter()
        pv = self._pixels(frames)
        ids = text["input_ids"].repeat(b, 1)
        mask = text["attention_mask"].repeat(b, 1)
        out = self.model(input_ids=ids, attention_mask=mask, pixel_values=pv)
        logits = out.logits.float()  # (B, patches, prompts)
        scores, labels = logits.sigmoid().max(dim=-1)
        boxes = out.pred_boxes.float()  # (B, patches, 4): cx, cy, w, h in [0, 1] of the padded square
        s = float(max(h, w))
        result = []
        for i in range(b):
            keep = scores[i] > threshold
            bx = boxes[i][keep] * s
            xy = bx[:, :2] - bx[:, 2:] / 2
            rows = torch.cat([xy, bx[:, 2:], scores[i][keep, None], labels[i][keep, None].float()], dim=1)
            rows = _nms(rows, 0.3)
            result.append(rows.cpu())
        torch.cuda.synchronize() if self.device.type == "cuda" else None
        self.model_ms = (time.perf_counter() - t0) * 1000
        return result

    def stage(self, addr, width, height):
        """Copies one frame to the GPU now and keeps it for the next flush() (batching: the caller's buffer can be
        reused as soon as this returns). Returns how many frames are waiting."""
        self._staged = getattr(self, "_staged", [])
        self._staged.append(self.upload(addr, width, height).clone())
        return len(self._staged)

    def flush(self, prompts, threshold=0.2):
        """Runs every staged frame in one batch; a flat list, 7 per box: slot (0 = first staged), x, y, w, h, score,
        prompt index."""
        staged = getattr(self, "_staged", [])
        self._staged = []
        if not staged:
            return []
        out = []
        for slot, rows in enumerate(self.detect_frames(torch.stack(staged), prompts, threshold)):
            for r in rows.tolist():
                out += [float(slot)] + r
        return out

    def detect_device(self, ptr, width, height, prompts, threshold=0.2):
        """One frame already on the GPU (a CUDA device pointer to RGBA bytes, e.g. a MAX DeviceBuffer), wrapped
        without a copy through __cuda_array_interface__. Only valid when both share the CUDA context (same process,
        same device: true for the primary context)."""
        t0 = time.perf_counter()
        frame = torch.as_tensor(_CudaFrame(ptr, width, height), device=self.device)
        self.upload.last_ms = (time.perf_counter() - t0) * 1000
        return self.detect_frames(frame[None], prompts, threshold)[0].flatten().tolist()

    def detect_address(self, addr, width, height, prompts, threshold=0.2):
        """One frame from a Mojo address; a flat Python list of floats, 6 per box (Mojo reads it without numpy)."""
        frame = self.upload(addr, width, height)
        rows = self.detect_frames(frame[None], prompts, threshold)[0]
        return rows.flatten().tolist()


    # ---------- find more like this: image-guided detection from example boxes ----------

    def _squares(self, h, w, tiles):
        """The square windows (x0, y0, side) the model sees. tiles = 0: the whole frame, padded to a square. tiles = n:
        squares of side min(h, w) / n on a grid that covers the frame (evenly spaced, overlapping where they must), so
        a small thing is seen n * max(h, w) / min(h, w) times bigger (16:9, n = 1: 2 windows, 1.8x; n = 2: 8, 3.6x)."""
        if tiles <= 0:
            return [(0, 0, max(h, w))]
        s = min(h, w) // tiles

        def starts(length):
            n = -(-length // s)
            return [round(i * (length - s) / max(n - 1, 1)) for i in range(n)]

        return [(x0, y0, s) for y0 in starts(h) for x0 in starts(w)]

    def _windows(self, frames, tiles):
        """(B, H, W, 4) uint8 -> (B * T, 3, side, side) model input and the T windows."""
        h, w = frames.shape[1], frames.shape[2]
        sq = self._squares(h, w, tiles)
        if tiles <= 0:
            return self._pixels(frames), sq
        pv = torch.stack([self._pixels(frames[:, y0:y0 + s, x0:x0 + s]) for x0, y0, s in sq], dim=1)  # (B, T, 3, side, side)
        return pv.flatten(0, 1), sq

    def _embed(self, pv, sq, b):
        """Model features for windows -> per frame: features (P, D) and boxes (P, 4: x, y, w, h in frame pixels)."""
        fmap = self.model.image_embedder(pixel_values=pv)[0]
        n, gh, gw, d = fmap.shape
        feats = fmap.reshape(n, gh * gw, d)
        boxes = self.model.box_predictor(feats, fmap).float()  # cx, cy, w, h in [0, 1] of the window
        t = len(sq)
        off = torch.tensor([[x0, y0] for x0, y0, _ in sq], device=pv.device, dtype=torch.float32)  # (T, 2)
        side = torch.tensor([s for _, _, s in sq], device=pv.device, dtype=torch.float32)  # (T,)
        boxes = boxes.view(b, t, gh * gw, 4) * side.view(1, t, 1, 1)
        xy = boxes[..., :2] - boxes[..., 2:] / 2 + off.view(1, t, 1, 2)
        boxes = torch.cat([xy, boxes[..., 2:]], dim=-1).view(b, t * gh * gw, 4)
        return feats.view(b, t * gh * gw, d), boxes

    @torch.inference_mode()
    def auto_tiles(self, width, height, w, h, patches=2, most=4):
        """The least zoom (tiles, see _squares) at which the example's short side spans `patches` of the model's patches:
        OWL's boxes come from patches, so a thing smaller than two of them is seen as part of its neighbourhood."""
        patch = self.model.config.vision_config.patch_size
        for n in range(most + 1):
            side = max(width, height) if n == 0 else min(width, height) // n
            if min(w, h) * self.side / side >= patches * patch:
                return n
        return most

    def add_example(self, addr, width, height, x, y, w, h, positive=True, tiles=-1):
        """An example of what to find: the box (x, y, w, h) on this frame. Its query is the class embedding of the
        model's own box that overlaps it best (the example seen at the scale and context it will be searched in).
        Several examples: positives and negatives; the first one sets `tiles` (see _squares; -1: auto_tiles). Returns that box's overlap (IoU)."""
        if not getattr(self, "_examples", None):
            self._examples = []
            self.tiles = int(tiles) if tiles >= 0 else self.auto_tiles(width, height, w, h)
        frame = self.upload(addr, width, height)[None]
        pv, sq = self._windows(frame, self.tiles)
        feats, boxes = self._embed(pv, sq, 1)
        embeds = self.model.class_predictor(feats)[1][0]  # (P, D)
        ious = _box_iou(boxes[0], torch.tensor([[x, y, w, h]], device=boxes.device, dtype=torch.float32))[:, 0]
        best = int(ious.argmax())
        self._examples.append(dict(embed=embeds[best].clone(), positive=bool(positive), feats=feats, boxes=boxes[0],
                                   box=(float(x), float(y), float(w), float(h)), iou=float(ious[best])))
        self._query = None
        return float(ious[best])

    def clear_examples(self):
        self._examples, self._query = [], None

    def _queries(self):
        if self._query is None:
            q = torch.stack([e["embed"] for e in self._examples])[None]  # (1, Q, D)
            self._query = (q, torch.ones(q.shape[:2], device=q.device),
                           torch.tensor([e["positive"] for e in self._examples], device=q.device))
        return self._query

    def _like_scores(self, feats):
        """(B, P, D) features -> (B, P) best positive score, (B, P) best negative score (0: none), (B, P) which example."""
        q, mask, pos = self._queries()
        logits = self.model.class_predictor(feats, q.expand(feats.shape[0], -1, -1), mask.expand(feats.shape[0], -1))[0]
        s = logits.float()  # logits: image-guided queries saturate the sigmoid
        sp, which = s.masked_fill(~pos, -1e9).max(dim=-1)
        sn = s.masked_fill(pos, -1e9).max(dim=-1).values if bool((~pos).any()) else torch.full_like(sp, -1e9)
        return sp, sn, which

    @torch.inference_mode()
    def add_background_negatives(self, k=64):
        """Hard negatives from the examples' own frames: the `k` model boxes that look most like the positives but touch
        no positive example's box (by tapping one thing, the user said the rest of that frame is not it). A box then
        counts only when it is closer to a positive than to all of these. Beyond a few dozen the result stops changing
        (measured: 32, 256 and 1024 give the same rows), so k is a cost bound, not a tuning knob."""
        positives = [e for e in self._examples if e["positive"] and e["feats"] is not None]
        taps = torch.tensor([e["box"] for e in positives], device=self.device, dtype=torch.float32)
        for e in positives:
            sp, _, _ = self._like_scores(e["feats"])
            touches = _box_iou(e["boxes"], taps).max(dim=1).values > 0
            s = sp[0].masked_fill(touches, -1e9)
            embeds = self.model.class_predictor(e["feats"])[1][0]
            for j in s.topk(min(k, int((~touches).sum()))).indices.tolist():
                self._examples.append(dict(embed=embeds[j].clone(), positive=False, feats=None, boxes=None, box=None, iou=0.0))
        self._query = None
        return len(self._examples)

    @torch.inference_mode()
    def like_stats(self):
        """The examples' own score distribution, for an automatic threshold: per positive example, its self-match (the
        best score of its own query on its own frame, among the model's boxes overlapping the example by IoU >= 0.5)
        and the background (the best score among boxes on that frame that do not touch the example at all). Returns
        [min self-match, max background]."""
        selfs, bgs = [], []
        for e in self._examples:
            if not e["positive"] or e["feats"] is None:
                continue
            sp, _, _ = self._like_scores(e["feats"])
            iou = _box_iou(e["boxes"], torch.tensor([e["box"]], device=sp.device))[:, 0]
            selfs.append(float(sp[0][iou >= 0.5].max()) if bool((iou >= 0.5).any()) else float(sp[0].max()))
            bg = sp[0][iou <= 0]
            bgs.append(float(bg.max()) if bg.numel() else 0.0)
        return [min(selfs), max(bgs)]

    @torch.inference_mode()
    def like_frames(self, frames, threshold):
        """(B, H, W, 4) -> per frame (N, 6) rows on the CPU: x, y, w, h, score, example index; a box counts when its best
        positive score is >= threshold and beats every negative example."""
        b = frames.shape[0]
        t0 = time.perf_counter()
        pv, sq = self._windows(frames, self.tiles)
        feats, boxes = self._embed(pv, sq, b)
        sp, sn, which = self._like_scores(feats)
        result = []
        for i in range(b):
            keep = (sp[i] >= threshold) & (sp[i] > sn[i])
            rows = torch.cat([boxes[i][keep], sp[i][keep, None], which[i][keep, None].float()], dim=1)
            if rows.shape[0]:  # NMS across examples (one thing, several examples of it)
                from torchvision.ops import nms  # noqa: PLC0415

                rows = _inside(rows[nms(torch.cat([rows[:, :2], rows[:, :2] + rows[:, 2:4]], dim=1), rows[:, 4], 0.3)])
            result.append(rows.cpu())
        if self.device.type == "cuda":
            torch.cuda.synchronize()
        self.model_ms = (time.perf_counter() - t0) * 1000
        return result

    def flush_like(self, threshold):
        """Every staged frame through like_frames in one batch; a flat list, 7 per box (slot first), as flush()."""
        staged = getattr(self, "_staged", [])
        self._staged = []
        if not staged:
            return []
        out = []
        for slot, rows in enumerate(self.like_frames(torch.stack(staged), threshold)):
            for r in rows.tolist():
                out += [float(slot)] + r
        return out

    def like_address(self, addr, width, height, threshold):
        frame = self.upload(addr, width, height)
        return self.like_frames(frame[None], threshold)[0].flatten().tolist()


def _inside(rows, cover=0.6):
    """Drops a box when at least `cover` of it lies inside a better-scoring box (rows sorted best first, as nms returns
    them): one thing, one box. IoU-based NMS keeps a small box nested in a big one (their IoU is low)."""
    keep = []
    for i in range(rows.shape[0]):
        x, y, w, h = rows[i, :4].tolist()
        ok = True
        for j in keep:
            X, Y, W, H = rows[j, :4].tolist()
            iw, ih = min(x + w, X + W) - max(x, X), min(y + h, Y + H) - max(y, Y)
            if iw > 0 and ih > 0 and iw * ih >= cover * min(w * h, W * H):
                ok = False
                break
        if ok:
            keep.append(i)
    return rows[keep]


def _box_iou(a, b):
    """IoU of (N, 4) and (M, 4) x, y, w, h boxes -> (N, M)."""
    from torchvision.ops import box_iou  # noqa: PLC0415

    xyxy = lambda t: torch.cat([t[:, :2], t[:, :2] + t[:, 2:4]], dim=1)
    return box_iou(xyxy(a.float()), xyxy(b.float()))


class _CudaFrame:
    """A raw CUDA pointer as an (H, W, 4) uint8 array torch can wrap (CUDA Array Interface v3)."""

    def __init__(self, ptr, width, height):
        self.__cuda_array_interface__ = {"shape": (int(height), int(width), 4), "typestr": "|u1",
                                         "data": (int(ptr), False), "version": 3, "strides": None, "stream": None}


def _nms(rows, iou):
    """Per-label non-maximum suppression on (N, 6) rows (x, y, w, h, score, label)."""
    if rows.shape[0] == 0:
        return rows
    from torchvision.ops import batched_nms  # noqa: PLC0415 (torchvision is optional)

    xyxy = torch.cat([rows[:, :2], rows[:, :2] + rows[:, 2:4]], dim=1)
    keep = batched_nms(xyxy, rows[:, 4], rows[:, 5].long(), iou)
    return rows[keep]


class Segmenter:
    """Promptable segmentation and video tracking (SAM 2 / 2.1): a box or points on one frame -> a mask that
    follows the object through the following frames (streaming: one frame at a time, as scan() hands them over)."""

    def __init__(self, name, device="cuda", half=True):
        from transformers import Sam2VideoModel, Sam2VideoProcessor

        t0 = time.perf_counter()
        self.device = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
        self.dtype = torch.bfloat16 if (half and self.device.type == "cuda") else torch.float32
        self.processor = Sam2VideoProcessor.from_pretrained(name)
        self.model = Sam2VideoModel.from_pretrained(name, dtype=self.dtype).to(self.device).eval()
        self.upload = _Upload(self.device)
        self.session = None
        self.size = None
        self.frame_index = 0
        self.load_ms = (time.perf_counter() - t0) * 1000
        self.model_ms = 0.0

    def start(self, width, height):
        self.session = self.processor.init_video_session(inference_device=self.device, dtype=self.dtype)
        self.size = (int(height), int(width))
        self.frame_index = 0

    def add_boxes(self, frame_index, obj_ids, boxes):
        """Several objects on one frame in ONE call (adding them one call at a time leaves the session without the
        first frame's memory for all but the last: "maskmem_features ... cannot be empty"). boxes: flat x, y, w, h."""
        b = [float(v) for v in boxes]
        xyxy = [[b[i], b[i + 1], b[i] + b[i + 2], b[i + 1] + b[i + 3]] for i in range(0, len(b), 4)]
        self.processor.add_inputs_to_inference_session(
            self.session, frame_idx=int(frame_index), obj_ids=[int(o) for o in obj_ids],
            input_boxes=[xyxy], original_size=self.size)

    def add_box(self, frame_index, obj_id, x, y, w, h):
        self.add_boxes(frame_index, [obj_id], [x, y, w, h])

    def add_points(self, frame_index, obj_id, points, labels):
        self.processor.add_inputs_to_inference_session(
            self.session, frame_idx=int(frame_index), obj_ids=int(obj_id),
            input_points=[[[list(map(float, p)) for p in points]]], input_labels=[[list(map(int, labels))]],
            original_size=self.size)

    @torch.inference_mode()
    def step_frame(self, frame):
        """frame: (H, W, 4) uint8 on the device. Runs the session on it; returns (obj_ids, masks (N, H, W) bool on
        the device)."""
        t0 = time.perf_counter()
        rgb = frame[..., :3].cpu().numpy() if self.device.type != "cuda" else frame[..., :3]
        inputs = self.processor(images=rgb, device=self.device, return_tensors="pt")
        out = self.model(inference_session=self.session, frame=inputs.pixel_values[0].to(self.dtype))
        masks = self.processor.post_process_masks([out.pred_masks], original_sizes=inputs.original_sizes, binarize=True)[0]
        masks = masks[:, 0] if masks.ndim == 4 else masks
        self.frame_index += 1
        if self.device.type == "cuda":
            torch.cuda.synchronize()
        self.model_ms = (time.perf_counter() - t0) * 1000
        return list(self.session.obj_ids), masks

    def step_address(self, addr, width, height):
        """One frame from a Mojo address; a flat list, 6 per object: obj_id, x, y, w, h, area (mask pixels)."""
        ids, masks = self.step_frame(self.upload(addr, width, height))
        return _mask_rows(ids, masks)


def _mask_rows(ids, masks):
    out = []
    for i, oid in enumerate(ids):
        m = masks[i]
        area = int(m.sum())
        if area == 0:
            out += [float(oid), 0.0, 0.0, 0.0, 0.0, 0.0]
            continue
        ys = torch.nonzero(m.any(dim=1)).flatten()
        xs = torch.nonzero(m.any(dim=0)).flatten()
        x0, x1, y0, y1 = int(xs[0]), int(xs[-1]), int(ys[0]), int(ys[-1])
        out += [float(oid), float(x0), float(y0), float(x1 - x0 + 1), float(y1 - y0 + 1), float(area)]
    return out
