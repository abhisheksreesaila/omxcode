# Big boards: how others keep 5,000+ objects smooth (goal 79, 2026-11-20)

The question: a whiteboard with 5,296 objects must pan, zoom and drag in under 8.3 ms a frame on the GPU 2D renderer
(mojoui.gpu2d, GL and Metal). Today every pan frame draws every visible object again, and a drag or an undo rebuilds
the whole board's batches (D-7933). What do the renderers we measure against do?

## What each one does
- **Chromium (cc/), the yardstick the web app runs on.** Content is recorded once as a display list (a paint record);
  the compositor rasterizes it into fixed tiles (~256–512 device px) at a *raster scale*, keeps them in GPU memory and
  composites them as textured quads under the scroll and zoom transform. A pan only composites; tiles that newly enter
  the view (and a prefetch ring around it) are rasterized by priority (NOW bin first, then SOON, EVENTUALLY), with a
  per-frame budget, so a frame never waits for raster. An edit is an *invalidation rect*: only tiles meeting it are
  rasterized again (and only the rect inside them: partial raster). During a pinch the raster scale is held and the
  kept tiles are stretched; when the gesture ends the scale snaps to the ideal one and tiles are rasterized again at
  the right density (content looks slightly soft mid-gesture). Scroll offsets are snapped to device pixels so a tile is
  drawn 1:1.
  - https://chromium.googlesource.com/chromium/src/+/refs/tags/59.0.3038.2/cc/tiles/picture_layer_tiling_set.cc
  - https://grida.co/docs/wg/research/chromium/tiling-deep-dive
  - https://grida.co/docs/wg/research/chromium/interaction-and-quality
  - https://chromium.googlesource.com/chromium/src/+/a753229/cc/tiles/tile_manager_unittest.cc (SMOOTHNESS_TAKES_PRIORITY)
- **Figma.** A C++ renderer on WebGL (now WebGPU) that bypasses the browser's paint; tile-based caching of the canvas
  is its widely described model (render only tiles that come into view; an edit re-renders only its tiles).
  - https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/
  - https://www.figma.com/blog/figma-rendering-powered-by-webgpu/
  - Penpot's new renderer copies the same idea (visible tiles plus a cache of tiles likely to become visible):
    https://penpot.app/blog/penpots-new-rendering-system/
- **tldraw.** DOM shapes; the lever is *culling* (off-screen shapes get display: none; 10,000 shapes, ~50 drawn) and
  since 4.4 an R-tree for shape queries; simpler geometry at low zoom.
  - https://tldraw.dev/sdk-features/culling, https://tldraw.dev/sdk-features/performance, https://tldraw.dev/releases/v4.4.0
- **Excalidraw.** Two canvases: a *static* one (the elements, redrawn only when the scene changes) and an
  *interactive* one (selection, handles, the element being dragged), plus a per-element cache of drawn shapes
  (ShapeCache) so an unchanged element is a drawImage. Dragging moves elements on the static canvas, so it is
  re-rendered (throttled), which is why big Excalidraw scenes drag slowly.
  - https://cdn.jsdelivr.net/npm/@zsviczian/excalidraw@0.18.0-88/types/element/src/shape.d.ts
  - https://instagit.com/excalidraw/excalidraw/optimize-excalidraw-performance-large-drawings/ (secondary)
- **Zed GPUI.** Immediate mode: the whole scene is rebuilt and drawn every frame from a few instanced pipelines (what
  gpu2d copied, docs/research/rendering.md). It has no raster cache because an editor window holds hundreds of
  primitives, not tens of thousands; it is the wrong model past a few thousand objects per frame.
- **Fabric.js (Personal Note's canvas engine) and Leafer.** Per-object caching to an offscreen canvas
  (objectCaching), redrawn when the object changes or the zoom moves far enough.
  - https://fabricjs.com/demos/svg-caching
- **A design note that states the zoom trade-off plainly:** stretch on the GPU during the gesture, one re-raster after
  it settles; tile caches pay off for multi-MB documents. https://jwmcglynn.github.io/donner/md_docs_2design__docs_20033-2-editor__design__tool__responsiveness.html

## What mojoui takes from them
1. **Raster tiles per layer, in the backend-free core** (Chromium/Figma): a layer that says it may be cached
   (`Painter.layer_tiles()`) is rasterized into device-pixel tiles at its zoom and composited as textured quads under
   its transform. The plan (which tiles, which zoom, which are stale, which to rasterize this frame under a budget) is
   shared by GL and Metal; a backend only rasterizes a tile and draws tile quads.
2. **Invalidation rects, not version bumps** (Chromium): drawing code says what changed (`Painter.layer_damage`), and
   only tiles meeting it are rasterized again; no rect means the whole layer.
3. **Translation snapped to device pixels** for a tiled layer (Chromium), so a composited tile is 1:1 and the frame
   equals a direct render.
4. **Zoom: stretch during the gesture, re-raster after** (Chromium/Donner), progressively, nearest tiles first; text is
   never left scaled once the zoom settles (M1's rule).
5. **The thing being dragged in its own layer** (Excalidraw's interactive canvas, but unlike Excalidraw the board
   beneath isn't re-rendered during the drag): lift on press, drop on release, invalidating only the rects it left and
   reached.
6. **Culling by a spatial index** (tldraw's R-tree): ObjectLayer.query already does this.
