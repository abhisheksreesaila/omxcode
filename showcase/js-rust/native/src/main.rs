//! The particle field natively: wgpu compute step + additive point draw in a winit window.
//!
//! Interactive: `particles-native [--n N]`; the cursor is the attractor, keys 1–5 pick 1M/2M/5M/10M/20M.
//! Scripted (showcase/SPEC.md): `particles-native --scripted --n N --frames F --out DIR [--shot FILE.ppm]`
//! writes DIR/positions.bin and DIR/timings.json, then exits. `--offscreen` renders the same frames into a texture,
//! without a window (NVIDIA's Vulkan driver cannot present to an Xvfb display).

use std::sync::{mpsc, Arc};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use winit::application::ApplicationHandler;
use winit::dpi::PhysicalSize;
use winit::event::{ElementState, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

const W: u32 = 1280;
const H: u32 = 720;
const WG: u32 = 256;
const MAX_GROUPS_X: u32 = 65535;
const SIZES: [u32; 5] = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000];
const GLYPHS: &str = "0123456789. NFPSTEMWGUCA";
const TS_RING: usize = 4;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    c: [f32; 2],
    dt: f32,
    n: u32,
    groups_x: u32,
    _pad: [u32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Text {
    chars: [u32; 48],
    len: u32,
    _pad: [u32; 3],
}

struct Args {
    n: u32,
    scripted: bool,
    frames: u32,
    out: std::path::PathBuf,
    shot: Option<std::path::PathBuf>,
    offscreen: bool,
}

fn parse_args() -> Args {
    let mut a = Args { n: SIZES[0], scripted: false, frames: 600, out: ".".into(), shot: None, offscreen: false };
    let mut it = std::env::args().skip(1);
    while let Some(k) = it.next() {
        match k.as_str() {
            "--scripted" => a.scripted = true,
            "--offscreen" => a.offscreen = true,
            "--n" => a.n = it.next().and_then(|s| s.parse().ok()).expect("--n N"),
            "--frames" => a.frames = it.next().and_then(|s| s.parse().ok()).expect("--frames F"),
            "--out" => a.out = it.next().expect("--out DIR").into(),
            "--shot" => a.shot = Some(it.next().expect("--shot FILE").into()),
            other => panic!("unknown argument {other}"),
        }
    }
    a
}

/// Particle buffers and the bind group that ties them to the step.
struct Field {
    n: u32,
    pos: wgpu::Buffer,
    vel: wgpu::Buffer,
    bind: wgpu::BindGroup,
}

struct Timestamps {
    set: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    ring: Vec<(wgpu::Buffer, Option<u32>)>, // readback buffer, frame it holds (pending)
    rx: mpsc::Receiver<usize>,
    tx: mpsc::Sender<usize>,
    period_ns: f32,
}

/// Where frames go: a window's swapchain, or (no presentable display, e.g. NVIDIA under Xvfb) a texture.
enum Target {
    Window { window: Arc<Window>, surface: wgpu::Surface<'static>, config: wgpu::SurfaceConfiguration },
    Offscreen { texture: wgpu::Texture },
}

struct Gpu {
    target: Target,
    format: wgpu::TextureFormat,
    in_flight: std::collections::VecDeque<wgpu::SubmissionIndex>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    step_pipe: wgpu::ComputePipeline,
    point_pipe: wgpu::RenderPipeline,
    text_pipe: wgpu::RenderPipeline,
    params: wgpu::Buffer,
    text: wgpu::Buffer,
    text_bind: wgpu::BindGroup,
    field: Field,
    ts: Option<Timestamps>,
    steps: Vec<f64>, // GPU step ms per frame (NaN until its timestamps come back)
    adapter_info: String,
}

struct App {
    args: Args,
    t_start: Instant,
    gpu: Option<Gpu>,
    frame: u32,
    last_frame: Option<Instant>,
    totals: Vec<f64>,
    first_frame_ms: f64,
    first_frame_epoch_ms: f64,
    cursor: Option<[f32; 2]>,
    fps: f64,
    step_ms: f64,
}

fn epoch_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() * 1000.0
}

impl Gpu {
    fn new(window: Option<Arc<Window>>, n: u32, want_copy: bool) -> Gpu {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
        let surface = window.as_ref().map(|w| instance.create_surface(w.clone()).expect("surface"));
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: surface.as_ref(),
            force_fallback_adapter: false,
            ..Default::default()
        }))
        .expect("adapter");
        let info = adapter.get_info();
        let adapter_info = format!("{} ({:?}, {})", info.name, info.backend, info.driver_info);
        let has_ts = adapter.features().contains(wgpu::Features::TIMESTAMP_QUERY);
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: None,
            required_features: if has_ts { wgpu::Features::TIMESTAMP_QUERY } else { wgpu::Features::empty() },
            required_limits: adapter.limits(), // 20M particles need storage buffers past the 128 MB default
            ..Default::default()
        }))
        .expect("device");

        let target = match (window, surface) {
            (Some(window), Some(surface)) => {
                let caps = surface.get_capabilities(&adapter);
                let mut config = surface.get_default_config(&adapter, W, H).expect("surface config");
                config.format = caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
                // Uncapped presentation so frame times measure the work, not the display's vsync.
                config.present_mode = [wgpu::PresentMode::Immediate, wgpu::PresentMode::Mailbox]
                    .into_iter()
                    .find(|m| caps.present_modes.contains(m))
                    .unwrap_or(wgpu::PresentMode::Fifo);
                if want_copy && caps.usages.contains(wgpu::TextureUsages::COPY_SRC) {
                    config.usage |= wgpu::TextureUsages::COPY_SRC;
                }
                surface.configure(&device, &config);
                Target::Window { window, surface, config }
            }
            _ => Target::Offscreen {
                texture: device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("frame"),
                    size: wgpu::Extent3d { width: W, height: H, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                    view_formats: &[],
                }),
            },
        };
        let format = match &target {
            Target::Window { config, .. } => config.format,
            Target::Offscreen { .. } => wgpu::TextureFormat::Rgba8Unorm,
        };

        let module = device.create_shader_module(wgpu::include_wgsl!("shader.wgsl"));
        let step_pipe = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("step"),
            layout: None,
            module: &module,
            entry_point: Some("step"),
            compilation_options: Default::default(),
            cache: None,
        });
        let vec2 = |loc| wgpu::VertexBufferLayout {
            array_stride: 8,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: Box::leak(Box::new([wgpu::VertexAttribute { format: wgpu::VertexFormat::Float32x2, offset: 0, shader_location: loc }])),
        };
        let additive = wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add };
        let point_pipe = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("points"),
            layout: None,
            vertex: wgpu::VertexState { module: &module, entry_point: Some("vs_point"), compilation_options: Default::default(), buffers: &[Some(vec2(0)), Some(vec2(1))] },
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::PointList, ..Default::default() },
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_point"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState { color: additive, alpha: additive }),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let text_pipe = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("text"),
            layout: None,
            vertex: wgpu::VertexState { module: &module, entry_point: Some("vs_text"), compilation_options: Default::default(), buffers: &[] },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_text"),
                compilation_options: Default::default(),
                targets: &[Some(format.into())],
            }),
            multiview_mask: None,
            cache: None,
        });
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("params"),
            size: std::mem::size_of::<Params>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let text = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("text"),
            size: std::mem::size_of::<Text>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let text_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &text_pipe.get_bind_group_layout(0),
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: text.as_entire_binding() }],
        });
        let ts = has_ts.then(|| {
            let (tx, rx) = mpsc::channel();
            Timestamps {
                set: device.create_query_set(&wgpu::QuerySetDescriptor { label: None, ty: wgpu::QueryType::Timestamp, count: 2 }),
                resolve: device.create_buffer(&wgpu::BufferDescriptor {
                    label: None,
                    size: 16,
                    usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                    mapped_at_creation: false,
                }),
                ring: (0..TS_RING)
                    .map(|_| {
                        (device.create_buffer(&wgpu::BufferDescriptor {
                            label: None,
                            size: 16,
                            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                            mapped_at_creation: false,
                        }), None)
                    })
                    .collect(),
                rx,
                tx,
                period_ns: queue.get_timestamp_period(),
            }
        });
        let field = Self::make_field(&device, &step_pipe, &params, n);
        Gpu { target, format, in_flight: Default::default(), device, queue, step_pipe, point_pipe, text_pipe, params, text, text_bind, field, ts, steps: Vec::new(), adapter_info }
    }

    fn make_field(device: &wgpu::Device, step_pipe: &wgpu::ComputePipeline, params: &wgpu::Buffer, n: u32) -> Field {
        use wgpu::util::DeviceExt;
        let p = sim::initial_positions(n as usize);
        let usage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_SRC;
        let pos = device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("pos"), contents: bytemuck::cast_slice(&p), usage });
        // Velocities start at zero: a fresh buffer is zero-initialised by wgpu.
        let vel = device.create_buffer(&wgpu::BufferDescriptor { label: Some("vel"), size: n as u64 * 8, usage, mapped_at_creation: false });
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &step_pipe.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: pos.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: vel.as_entire_binding() },
            ],
        });
        Field { n, pos, vel, bind }
    }

    fn set_n(&mut self, n: u32) {
        if n != self.field.n {
            self.field = Self::make_field(&self.device, &self.step_pipe, &self.params, n);
        }
    }

    /// Collects finished step timings (ms per frame) without waiting.
    fn drain_timestamps(&mut self, wait: bool) {
        let out = &mut self.steps;
        let Some(ts) = self.ts.as_mut() else { return };
        loop {
            let pending = ts.ring.iter().any(|(_, f)| f.is_some());
            if !pending {
                return;
            }
            let _ = self.device.poll(if wait { wgpu::PollType::wait_indefinitely() } else { wgpu::PollType::Poll });
            let mut got = false;
            while let Ok(slot) = ts.rx.try_recv() {
                got = true;
                let (buf, frame) = &mut ts.ring[slot];
                let t: [u64; 2] = {
                    let view = buf.slice(..).get_mapped_range().expect("mapped");
                    let v: &[u64] = bytemuck::cast_slice(&view);
                    [v[0], v[1]]
                };
                buf.unmap();
                let f = frame.take().unwrap() as usize;
                if out.len() <= f {
                    out.resize(f + 1, f64::NAN);
                }
                out[f] = t[1].saturating_sub(t[0]) as f64 * ts.period_ns as f64 / 1e6;
            }
            if !wait || !got && !pending {
                return;
            }
        }
    }

    fn set_text(&self, s: &str) {
        let mut t = Text { chars: [11; 48], len: 0, _pad: [0; 3] };
        for (i, ch) in s.chars().take(48).enumerate() {
            t.chars[i] = GLYPHS.find(ch).unwrap_or(11) as u32;
            t.len = i as u32 + 1;
        }
        self.queue.write_buffer(&self.text, 0, bytemuck::bytes_of(&t));
    }

    /// One frame: step, draw, readout; the finished frame is written to `shot` (PPM) when asked.
    fn frame(&mut self, frame: u32, c: [f32; 2], shot: Option<&std::path::Path>) {
        let n = self.field.n;
        let groups = n.div_ceil(WG);
        let gx = groups.min(MAX_GROUPS_X);
        let gy = groups.div_ceil(gx);
        let p = Params { c, dt: sim::DT, n, groups_x: gx, _pad: [0; 3] };
        self.queue.write_buffer(&self.params, 0, bytemuck::bytes_of(&p));

        let (surface_tex, texture) = match &self.target {
            Target::Window { surface, config, .. } => match surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                    let tex = t.texture.clone();
                    (Some(t), tex)
                }
                other => {
                    eprintln!("surface: {other:?}; reconfiguring");
                    surface.configure(&self.device, config);
                    return;
                }
            },
            Target::Offscreen { texture } => (None, texture.clone()),
        };
        let view = texture.create_view(&Default::default());
        let mut enc = self.device.create_command_encoder(&Default::default());

        // Pick a free timestamp readback slot (wait for the oldest if all are busy).
        let slot = if self.ts.is_some() {
            let free = |ts: &Timestamps| ts.ring.iter().position(|(_, f)| f.is_none());
            while free(self.ts.as_ref().unwrap()).is_none() {
                self.drain_timestamps(true);
            }
            free(self.ts.as_ref().unwrap())
        } else {
            None
        };
        {
            let tw = self.ts.as_ref().map(|ts| wgpu::ComputePassTimestampWrites {
                query_set: &ts.set,
                beginning_of_pass_write_index: Some(0),
                end_of_pass_write_index: Some(1),
            });
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("step"), timestamp_writes: tw });
            pass.set_pipeline(&self.step_pipe);
            pass.set_bind_group(0, &self.field.bind, &[]);
            pass.dispatch_workgroups(gx, gy, 1);
        }
        if let (Some(ts), Some(slot)) = (self.ts.as_mut(), slot) {
            enc.resolve_query_set(&ts.set, 0..2, &ts.resolve, 0);
            enc.copy_buffer_to_buffer(&ts.resolve, 0, &ts.ring[slot].0, 0, 16);
            ts.ring[slot].1 = Some(frame);
        }
        {
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("draw"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.point_pipe);
            pass.set_vertex_buffer(0, self.field.pos.slice(..));
            pass.set_vertex_buffer(1, self.field.vel.slice(..));
            pass.draw(0..n, 0..1);
            pass.set_pipeline(&self.text_pipe);
            pass.set_bind_group(0, &self.text_bind, &[]);
            pass.draw(0..3, 0..1);
        }
        let shot_buf = shot.map(|_| {
            let bpr = (W * 4).div_ceil(256) * 256;
            let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: (bpr * H) as u64,
                usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            enc.copy_texture_to_buffer(
                texture.as_image_copy(),
                wgpu::TexelCopyBufferInfo { buffer: &buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(bpr), rows_per_image: None } },
                wgpu::Extent3d { width: W, height: H, depth_or_array_layers: 1 },
            );
            (buf, bpr)
        });
        let index = self.queue.submit([enc.finish()]);
        if let (Some(ts), Some(slot)) = (self.ts.as_ref(), slot) {
            let tx = ts.tx.clone();
            ts.ring[slot].0.slice(..).map_async(wgpu::MapMode::Read, move |r| {
                if r.is_ok() {
                    let _ = tx.send(slot);
                }
            });
        }
        if let (Some((buf, bpr)), Some(path)) = (shot_buf, shot) {
            buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
            let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
            let data = buf.slice(..).get_mapped_range().expect("mapped");
            let bgra = matches!(self.format, wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb);
            let mut ppm = format!("P6\n{W} {H}\n255\n").into_bytes();
            for y in 0..H {
                for x in 0..W {
                    let o = (y * bpr + x * 4) as usize;
                    let px = &data[o..o + 4];
                    if bgra { ppm.extend_from_slice(&[px[2], px[1], px[0]]) } else { ppm.extend_from_slice(&px[..3]) }
                }
            }
            std::fs::write(path, ppm).expect("write shot");
        }
        match (&self.target, surface_tex) {
            (Target::Window { window, .. }, Some(t)) => {
                window.pre_present_notify();
                self.queue.present(t);
            }
            _ => {
                // No swapchain to pace us: keep at most two frames in flight, as a swapchain would.
                self.in_flight.push_back(index);
                while self.in_flight.len() > 2 {
                    let i = self.in_flight.pop_front().unwrap();
                    let _ = self.device.poll(wgpu::PollType::Wait { submission_index: Some(i), timeout: None });
                }
            }
        }
    }

    fn read_positions(&self) -> Vec<u8> {
        let size = self.field.n as u64 * 8;
        let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_buffer_to_buffer(&self.field.pos, 0, &buf, 0, size);
        self.queue.submit([enc.finish()]);
        buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        let v = buf.slice(..).get_mapped_range().expect("mapped").to_vec();
        v
    }
}

impl App {
    fn attractor(&self) -> [f32; 2] {
        if let (false, Some(c)) = (self.args.scripted, self.cursor) {
            return c;
        }
        let (x, y) = sim::attractor(self.frame);
        [x, y]
    }

    /// One frame of the loop; returns true when a scripted run is complete (outputs written).
    fn tick(&mut self) -> bool {
        let c = self.attractor();
        let last = self.args.scripted && self.frame + 1 == self.args.frames;
        let shot = if last { self.args.shot.clone() } else { None };
        let gpu = self.gpu.as_mut().unwrap();
        gpu.set_text(&format!("N {}  FPS {:.0}  STEP {:.2} MS", gpu.field.n, self.fps, self.step_ms));
        let now = Instant::now();
        if let Some(prev) = self.last_frame {
            let ms = (now - prev).as_secs_f64() * 1000.0;
            self.totals.push(ms);
            self.fps = 0.9 * self.fps + 0.1 * (1000.0 / ms);
        }
        let first = self.last_frame.is_none();
        self.last_frame = Some(now);
        gpu.frame(self.frame, c, shot.as_deref());
        if first {
            // cold start ends when the first frame is drawn (its GPU work done), as in the other builds
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
            self.first_frame_ms = self.t_start.elapsed().as_secs_f64() * 1000.0;
            self.first_frame_epoch_ms = epoch_ms();
        }
        gpu.drain_timestamps(false);
        if let Some(v) = gpu.steps.iter().rev().find(|v| !v.is_nan()) {
            self.step_ms = *v;
        }
        self.frame += 1;
        if self.args.scripted && self.frame == self.args.frames {
            // the last frame's interval: until its work has finished on the GPU
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
            self.totals.push((Instant::now() - now).as_secs_f64() * 1000.0);
            self.finish();
            return true;
        }
        false
    }

    fn finish(&mut self) {
        let gpu = self.gpu.as_mut().unwrap();
        gpu.drain_timestamps(true);
        let mut steps = gpu.steps.clone();
        steps.resize(self.args.frames as usize, f64::NAN);
        std::fs::create_dir_all(&self.args.out).unwrap();
        std::fs::write(self.args.out.join("positions.bin"), gpu.read_positions()).unwrap();
        let js = |v: &[f64]| v.iter().map(|x| if x.is_nan() { "null".to_string() } else { format!("{x:.4}") }).collect::<Vec<_>>().join(",");
        let present = match &gpu.target {
            Target::Window { config, .. } => format!("{:?}", config.present_mode),
            Target::Offscreen { .. } => "offscreen".to_string(),
        };
        let json = format!(
            "{{\"row\":\"B-native\",\"n\":{},\"frames\":{},\"adapter\":{:?},\"present\":\"{present}\",\"timestamps\":{},\"first_frame_ms\":{:.2},\"first_frame_epoch_ms\":{:.1},\"total\":[{}],\"step\":[{}]}}\n",
            gpu.field.n, self.args.frames, gpu.adapter_info, gpu.ts.is_some(), self.first_frame_ms, self.first_frame_epoch_ms,
            js(&self.totals), js(&steps)
        );
        std::fs::write(self.args.out.join("timings.json"), json).unwrap();
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.gpu.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("particles · Rust + wgpu")
            .with_inner_size(PhysicalSize::new(W, H))
            .with_resizable(false);
        let window = Arc::new(el.create_window(attrs).expect("window"));
        let gpu = Gpu::new(Some(window), self.args.n, self.args.shot.is_some());
        eprintln!("adapter: {}", gpu.adapter_info);
        self.gpu = Some(gpu);
        el.set_control_flow(ControlFlow::Poll);
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _id: WindowId, ev: WindowEvent) {
        match ev {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = Some([(position.x as f32 / W as f32 * 2.0 - 1.0) * 1.6, (1.0 - position.y as f32 / H as f32 * 2.0) * 0.9]);
            }
            WindowEvent::CursorLeft { .. } => self.cursor = None,
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed && !self.args.scripted => {
                match event.logical_key {
                    Key::Named(NamedKey::Escape) => el.exit(),
                    Key::Character(ref s) => {
                        if let Some(i) = s.parse::<usize>().ok().filter(|i| (1..=5).contains(i)) {
                            self.gpu.as_mut().unwrap().set_n(SIZES[i - 1]);
                        }
                    }
                    _ => {}
                }
            }
            WindowEvent::RedrawRequested => {
                if self.tick() {
                    el.exit();
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _el: &ActiveEventLoop) {
        if let Some(Gpu { target: Target::Window { window, .. }, .. }) = &self.gpu {
            window.request_redraw();
        }
    }
}

fn main() {
    let t_start = Instant::now();
    let args = parse_args();
    let offscreen = args.offscreen;
    std::fs::create_dir_all(&args.out).expect("--out DIR");
    let mut app = App {
        args,
        t_start,
        gpu: None,
        frame: 0,
        last_frame: None,
        totals: Vec::new(),
        first_frame_ms: 0.0,
        first_frame_epoch_ms: 0.0,
        cursor: None,
        fps: 60.0,
        step_ms: 0.0,
    };
    if offscreen {
        // No window: the same GPU work into a texture (for displays the GPU can't present to).
        assert!(app.args.scripted, "--offscreen needs --scripted");
        let gpu = Gpu::new(None, app.args.n, app.args.shot.is_some());
        eprintln!("adapter: {} (offscreen)", gpu.adapter_info);
        app.gpu = Some(gpu);
        while !app.tick() {}
        return;
    }
    let el = EventLoop::new().expect("event loop");
    el.run_app(&mut app).expect("run");
}
