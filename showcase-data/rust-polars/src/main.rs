//! The orders dashboard: Polars (lazy API) for the data, egui/eframe (glow) for the window.
//!
//! The data lives on a worker thread; the UI thread only draws. Every control change sends the full filter state to
//! the worker (newest wins: the worker drops requests that a later one replaced), which answers and wakes the UI.
//!
//! Interactive:  dash --rows 10M
//! Scripted:     dash --scripted --rows 100M [--steps S] [--out DIR] [--shot FILE.png]
//!   shows step 0, applies steps 1..S of showcase-data/steps.json one at a time, and per step records compute time
//!   (the worker's query) and input-to-pixels (the change → the end of the first frame that shows its numbers: the
//!   frame after it starts, so the showing frame was painted and swapped); writes answers.json and timings.json.

mod engine;

use eframe::egui::{self, Color32, RichText};
use engine::{Answer, Data, Filter, fmt_date, parse_date};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Instant;

struct Args {
    scripted: bool,
    rows: String,
    steps: Option<usize>,
    root: PathBuf,
    out: PathBuf,
    shot: Option<PathBuf>,
}

fn args() -> Args {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut a = Args { scripted: false, rows: "10M".into(), steps: None, root: root.clone(), out: PathBuf::from("."), shot: None };
    let mut it = std::env::args().skip(1);
    while let Some(k) = it.next() {
        match k.as_str() {
            "--scripted" => a.scripted = true,
            "--rows" => a.rows = it.next().expect("--rows 10M|100M"),
            "--steps" => a.steps = Some(it.next().unwrap().parse().expect("--steps S")),
            "--root" => a.root = it.next().unwrap().into(),
            "--out" => a.out = it.next().unwrap().into(),
            "--shot" => a.shot = Some(it.next().unwrap().into()),
            other => panic!("unknown argument {other}"),
        }
    }
    assert!(a.rows == "10M" || a.rows == "100M", "--rows takes 10M or 100M");
    a
}

/// steps.json: the opening state, then each step's full state and the control it changed.
fn load_states(root: &PathBuf) -> Vec<(usize, String, Filter)> {
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(root.join("showcase-data/steps.json")).unwrap()).unwrap();
    let f = |s: &serde_json::Value| Filter {
        from: parse_date(s["from"].as_str().unwrap()),
        to: parse_date(s["to"].as_str().unwrap()),
        min_amount: s["min_amount"].as_f64().unwrap(),
        region: s["region"].as_str().unwrap().to_string(),
    };
    let mut out = vec![(0, "opening".to_string(), f(&v["opening"]))];
    for s in v["steps"].as_array().unwrap() {
        out.push((s["step"].as_u64().unwrap() as usize, s["change"].as_str().unwrap().to_string(), f(s)));
    }
    out
}

// ---------------------------------------------------------------------------------------------------------------------
// The worker: loads the file once, then answers filter states.
// ---------------------------------------------------------------------------------------------------------------------

struct Req {
    generation: u64,
    filter: Filter,
}

enum Msg {
    Loaded { rows: usize, load_ms: f64, regions: Vec<String> },
    Done { generation: u64, compute_ms: f64, answer: Answer },
    Failed(String),
}

fn spawn_worker(path: PathBuf, ctx: egui::Context) -> (Sender<Req>, Receiver<Msg>) {
    let (req_tx, req_rx) = channel::<Req>();
    let (msg_tx, msg_rx) = channel::<Msg>();
    std::thread::Builder::new()
        .name("data".into())
        .spawn(move || {
            let send = |m: Msg| {
                let _ = msg_tx.send(m);
                ctx.request_repaint();
            };
            let data = match Data::load(&path) {
                Ok(d) => d,
                Err(e) => return send(Msg::Failed(format!("load {}: {e}", path.display()))),
            };
            send(Msg::Loaded { rows: data.len(), load_ms: data.load_ms, regions: data.regions.clone() });
            while let Ok(mut r) = req_rx.recv() {
                while let Ok(newer) = req_rx.try_recv() {
                    r = newer; // newest wins: a slider drag never queues stale work
                }
                let t0 = Instant::now();
                match data.query(&r.filter) {
                    Ok(answer) => send(Msg::Done {
                        generation: r.generation,
                        compute_ms: t0.elapsed().as_secs_f64() * 1e3,
                        answer,
                    }),
                    Err(e) => send(Msg::Failed(format!("query: {e}"))),
                }
            }
        })
        .unwrap();
    (req_tx, msg_rx)
}

// ---------------------------------------------------------------------------------------------------------------------
// The app
// ---------------------------------------------------------------------------------------------------------------------

#[derive(PartialEq)]
enum Phase {
    Waiting,       // a change went out; its numbers aren't on screen yet
    Drawn(f64),    // this frame drew them (compute ms); the next frame's start stamps the pixels
    Idle,
}

struct StepRecord {
    step: usize,
    change: String,
    compute_ms: f64,
    input_to_pixels_ms: f64,
}

struct Script {
    states: Vec<(usize, String, Filter)>,
    k: usize,
    t_change: Instant,
    phase: Phase,
    records: Vec<StepRecord>,
    answers: Vec<serde_json::Value>,
    cold_start_ms: f64,
    shot: Option<Arc<Mutex<Option<Arc<egui::ColorImage>>>>>,
    finished: bool,
}

struct Dash {
    t_main: Instant,
    args: Args,
    req: Sender<Req>,
    msgs: Receiver<Msg>,
    // the controls
    from: jiff::civil::Date,
    to: jiff::civil::Date,
    min_amount: f64,
    region: String,
    regions: Vec<String>,
    // the data side
    rows_total: usize,
    load_ms: f64,
    sent: Option<Filter>,
    generation: u64,
    shown: Option<Answer>,
    shown_compute_ms: f64,
    error: Option<String>,
    script: Option<Script>,
}

fn to_jiff(z: i32) -> jiff::civil::Date {
    let (y, m, d) = engine::civil(z);
    jiff::civil::Date::new(y as i16, m as i8, d as i8).unwrap()
}

fn from_jiff(d: jiff::civil::Date) -> i32 {
    engine::days(d.year() as i32, d.month() as u32, d.day() as u32)
}

impl Dash {
    fn new(cc: &eframe::CreationContext<'_>, t_main: Instant, args: Args) -> Self {
        cc.egui_ctx.set_theme(egui::Theme::Light);
        let path = args.root.join(format!("data/orders-{}.parquet", args.rows));
        let (req, msgs) = spawn_worker(path, cc.egui_ctx.clone());
        let states = load_states(&args.root);
        let open = states[0].2.clone();
        let script = args.scripted.then(|| {
            let s = args.steps.unwrap_or(states.len() - 1).min(states.len() - 1);
            Script {
                states: states[..=s].to_vec(),
                k: 0,
                t_change: Instant::now(),
                phase: Phase::Idle,
                records: vec![],
                answers: vec![],
                cold_start_ms: 0.0,
                shot: None,
                finished: false,
            }
        });
        Dash {
            t_main,
            args,
            req,
            msgs,
            from: to_jiff(open.from),
            to: to_jiff(open.to),
            min_amount: open.min_amount,
            region: open.region,
            regions: vec![],
            rows_total: 0,
            load_ms: 0.0,
            sent: None,
            generation: 0,
            shown: None,
            shown_compute_ms: 0.0,
            error: None,
            script,
        }
    }

    fn filter(&self) -> Filter {
        Filter { from: from_jiff(self.from), to: from_jiff(self.to), min_amount: self.min_amount, region: self.region.clone() }
    }

    /// Script: move the controls to state k (as a user would), stamping the change.
    fn apply(&mut self, k: usize) {
        let f = self.script.as_ref().unwrap().states[k].2.clone();
        self.from = to_jiff(f.from);
        self.to = to_jiff(f.to);
        self.min_amount = f.min_amount;
        self.region = f.region;
        let s = self.script.as_mut().unwrap();
        s.k = k;
        s.t_change = Instant::now();
        s.phase = Phase::Waiting;
    }

    fn drive_script(&mut self, ctx: &egui::Context) {
        let Some(s) = self.script.as_mut() else { return };
        if let Phase::Drawn(compute_ms) = s.phase {
            // The frame that showed step k's numbers has been painted and swapped.
            let ms = s.t_change.elapsed().as_secs_f64() * 1e3;
            let (step, change, _) = s.states[s.k].clone();
            if step == 0 {
                s.cold_start_ms = self.t_main.elapsed().as_secs_f64() * 1e3;
            }
            s.records.push(StepRecord { step, change, compute_ms, input_to_pixels_ms: ms });
            s.answers.push(answer_json(step, self.shown.as_ref().unwrap()));
            s.phase = Phase::Idle;
            if s.k + 1 < s.states.len() {
                let k = s.k + 1;
                self.apply(k);
            } else if let Some(path) = self.args.shot.clone() {
                let slot = Arc::new(Mutex::new(None));
                let put = slot.clone();
                ctx.request_screenshot(move |img| *put.lock().unwrap() = Some(img));
                s.shot = Some(slot);
                let _ = path;
            } else {
                s.finished = true;
            }
        }
        let s = self.script.as_mut().unwrap();
        if let Some(slot) = &s.shot {
            if let Some(img) = slot.lock().unwrap().take() {
                save_png(&img, self.args.shot.as_ref().unwrap());
                s.finished = true;
            }
            ctx.request_repaint();
        }
        if s.finished {
            self.write_results();
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    fn write_results(&mut self) {
        let s = self.script.as_mut().unwrap();
        if s.k == usize::MAX {
            return;
        }
        s.k = usize::MAX;
        std::fs::create_dir_all(&self.args.out).unwrap();
        let answers = serde_json::json!({ "steps": s.answers });
        std::fs::write(self.args.out.join("answers.json"), serde_json::to_string(&answers).unwrap()).unwrap();
        let steps: Vec<_> = s
            .records
            .iter()
            .map(|r| serde_json::json!({"step": r.step, "change": r.change, "compute_ms": r.compute_ms,
                                        "input_to_pixels_ms": r.input_to_pixels_ms}))
            .collect();
        let timings = serde_json::json!({
            "build": "C: Rust + Polars (lazy) + egui/eframe (glow)",
            "rows": self.rows_total, "file": format!("orders-{}.parquet", self.args.rows),
            "load_ms": self.load_ms, "cold_start_ms": s.cold_start_ms,
            "polars_threads": std::thread::available_parallelism().map_or(0, |n| n.get()),
            "steps": steps,
        });
        std::fs::write(self.args.out.join("timings.json"), serde_json::to_string_pretty(&timings).unwrap()).unwrap();
    }

    fn receive(&mut self) {
        while let Ok(m) = self.msgs.try_recv() {
            match m {
                Msg::Loaded { rows, load_ms, regions } => {
                    self.rows_total = rows;
                    self.load_ms = load_ms;
                    self.regions = regions;
                    if self.script.is_some() {
                        self.apply(0);
                    }
                }
                Msg::Done { generation, compute_ms, answer } => {
                    if generation == self.generation {
                        self.shown = Some(answer);
                        self.shown_compute_ms = compute_ms;
                        if let Some(s) = self.script.as_mut() {
                            if s.phase == Phase::Waiting {
                                s.phase = Phase::Drawn(compute_ms);
                            }
                        }
                    }
                }
                Msg::Failed(e) => self.error = Some(e),
            }
        }
    }

    /// Any change to the controls (a user's or the script's) sends the new state to the worker.
    fn send_if_changed(&mut self) {
        if self.rows_total == 0 {
            return;
        }
        let f = self.filter();
        if self.sent.as_ref() != Some(&f) {
            self.generation += 1;
            let _ = self.req.send(Req { generation: self.generation, filter: f.clone() });
            self.sent = Some(f);
        }
    }
}

fn answer_json(step: usize, a: &Answer) -> serde_json::Value {
    serde_json::json!({
        "step": step, "rows": a.rows, "sum_amount": a.sum_amount, "avg_margin": a.avg_margin,
        "top": a.top.iter().map(|(p, s)| serde_json::json!([p, s])).collect::<Vec<_>>(),
        "ids": a.table.iter().map(|r| r.id).collect::<Vec<_>>(),
    })
}

fn save_png(img: &egui::ColorImage, path: &PathBuf) {
    let [w, h] = img.size;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).unwrap();
    }
    let bytes: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_array()).collect();
    image::save_buffer(path, &bytes, w as u32, h as u32, image::ExtendedColorType::Rgba8).unwrap();
}

fn thousands(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn money(x: f64) -> String {
    let whole = x.trunc() as u64;
    format!("{}.{:02}", thousands(whole), ((x - whole as f64) * 100.0).round().min(99.0) as u64)
}

fn compact(x: f64) -> String {
    if x >= 1e9 {
        format!("{:.2} B", x / 1e9)
    } else if x >= 1e6 {
        format!("{:.2} M", x / 1e6)
    } else if x >= 1e3 {
        format!("{:.1} K", x / 1e3)
    } else {
        format!("{x:.0}")
    }
}

const ACCENT: Color32 = Color32::from_rgb(0x2f, 0x6f, 0xeb);
const MUTED: Color32 = Color32::from_rgb(0x6b, 0x72, 0x80);
const CARD: Color32 = Color32::from_rgb(0xf6, 0xf7, 0xf9);

fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::new()
        .fill(CARD)
        .corner_radius(10.0)
        .inner_margin(egui::Margin::symmetric(14, 10))
        .show(ui, add)
        .inner
}

fn kpi(ui: &mut egui::Ui, width: f32, label: &str, value: String) {
    ui.allocate_ui_with_layout(egui::vec2(width, 64.0), egui::Layout::top_down(egui::Align::LEFT), |ui| {
        card(ui, |ui| {
            ui.set_width(width - 28.0);
            ui.label(RichText::new(label).color(MUTED).size(13.0));
            ui.label(RichText::new(value).size(24.0).strong());
        });
    });
}

fn bars(ui: &mut egui::Ui, top: &[(String, f64)]) {
    let rect = ui.available_rect_before_wrap();
    ui.allocate_rect(rect, egui::Sense::hover());
    let p = ui.painter_at(rect);
    if top.is_empty() {
        p.text(rect.center(), egui::Align2::CENTER_CENTER, "No orders match", egui::FontId::proportional(15.0), MUTED);
        return;
    }
    let max = top[0].1.max(f64::MIN_POSITIVE);
    let row_h = (rect.height() / engine::TOP as f32).min(28.0);
    let (label_w, value_w) = (96.0, 78.0);
    for (i, (name, sum)) in top.iter().enumerate() {
        let y = rect.top() + i as f32 * row_h;
        let mid = y + row_h / 2.0;
        p.text(egui::pos2(rect.left(), mid), egui::Align2::LEFT_CENTER, name, egui::FontId::proportional(13.0), Color32::from_gray(40));
        let x0 = rect.left() + label_w;
        let w = ((rect.width() - label_w - value_w) as f64 * (sum / max)).max(1.0) as f32;
        let bar = egui::Rect::from_min_size(egui::pos2(x0, y + row_h * 0.18), egui::vec2(w, row_h * 0.64));
        p.rect_filled(bar, 4.0, ACCENT);
        p.text(egui::pos2(bar.right() + 6.0, mid), egui::Align2::LEFT_CENTER, compact(*sum), egui::FontId::proportional(12.0), MUTED);
    }
}

fn table(ui: &mut egui::Ui, rows: &[engine::Row]) {
    use egui_extras::{Column, TableBuilder};
    TableBuilder::new(ui)
        .striped(true)
        .cell_layout(egui::Layout::left_to_right(egui::Align::Center))
        .column(Column::exact(82.0))
        .column(Column::exact(84.0))
        .column(Column::exact(82.0))
        .column(Column::exact(96.0))
        .column(Column::exact(84.0))
        .column(Column::exact(84.0))
        .column(Column::remainder())
        .header(22.0, |mut h| {
            for t in ["id", "day", "region", "product", "amount", "cost", "paid"] {
                h.col(|ui| {
                    ui.label(RichText::new(t).strong().color(MUTED));
                });
            }
        })
        .body(|body| {
            body.rows(20.0, rows.len(), |mut row| {
                let r = &rows[row.index()];
                row.col(|ui| { ui.label(r.id.to_string()); });
                row.col(|ui| { ui.label(fmt_date(r.day)); });
                row.col(|ui| { ui.label(&r.region); });
                row.col(|ui| { ui.label(&r.product); });
                row.col(|ui| { ui.label(money(r.amount)); });
                row.col(|ui| { ui.label(money(r.cost)); });
                row.col(|ui| { ui.label(if r.paid { "yes" } else { "no" }); });
            });
        });
}

impl eframe::App for Dash {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.drive_script(&ctx);
        self.receive();

        egui::Panel::top("controls").show(ui, |ui| {
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                ui.heading(RichText::new("Orders").strong());
                ui.label(RichText::new(format!("{} rows · Polars + egui", thousands(self.rows_total as u64))).color(MUTED));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if self.rows_total > 0 {
                        ui.label(RichText::new(format!("query {:.1} ms", self.shown_compute_ms)).color(MUTED));
                    }
                });
            });
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.label("From");
                ui.add(egui_extras::DatePickerButton::new(&mut self.from).id_salt("from").calendar_week(false).show_icon(false));
                ui.label("To");
                ui.add(egui_extras::DatePickerButton::new(&mut self.to).id_salt("to").calendar_week(false).show_icon(false));
                ui.add_space(12.0);
                ui.label("Min amount");
                ui.spacing_mut().slider_width = 260.0;
                ui.add(egui::Slider::new(&mut self.min_amount, 1.0..=5000.0).logarithmic(true).fixed_decimals(0));
                ui.add_space(12.0);
                ui.label("Region");
                egui::ComboBox::from_id_salt("region").selected_text(self.region.clone()).width(130.0).show_ui(ui, |ui| {
                    ui.selectable_value(&mut self.region, "all".to_string(), "all");
                    for r in self.regions.clone() {
                        ui.selectable_value(&mut self.region, r.clone(), r);
                    }
                });
            });
            ui.add_space(8.0);
        });

        egui::CentralPanel::default_margins().show(ui, |ui| {
            if let Some(e) = &self.error {
                ui.colored_label(Color32::RED, e);
                return;
            }
            let Some(a) = self.shown.clone() else {
                ui.centered_and_justified(|ui| {
                    ui.spinner();
                });
                return;
            };
            let w = (ui.available_width() - 2.0 * ui.spacing().item_spacing.x) / 3.0;
            ui.horizontal(|ui| {
                kpi(ui, w, "Rows matched", thousands(a.rows));
                kpi(ui, w, "Sum of amount", money(a.sum_amount));
                kpi(ui, w, "Average margin", a.avg_margin.map_or("–".into(), |m| format!("{:.2} %", m * 100.0)));
            });
            ui.add_space(8.0);
            let h = ui.available_height();
            ui.horizontal_top(|ui| {
                let down = egui::Layout::top_down(egui::Align::LEFT);
                ui.allocate_ui_with_layout(egui::vec2(470.0, h), down, |ui| {
                    card(ui, |ui| {
                        ui.set_min_size(egui::vec2(442.0, h - 20.0));
                        ui.label(RichText::new("Sum of amount by product · top 20").color(MUTED));
                        ui.add_space(4.0);
                        bars(ui, &a.top);
                    });
                });
                ui.allocate_ui_with_layout(egui::vec2(ui.available_width(), h), down, |ui| {
                    card(ui, |ui| {
                        ui.set_min_size(egui::vec2(ui.available_width(), h - 20.0));
                        ui.label(RichText::new("First 50 orders · newest first").color(MUTED));
                        ui.add_space(4.0);
                        table(ui, &a.table);
                    });
                });
            });
        });

        self.send_if_changed();
        if matches!(self.script.as_ref().map(|s| &s.phase), Some(Phase::Drawn(_))) {
            ctx.request_repaint(); // the next frame's start stamps this one's pixels
        }
    }
}

fn main() -> eframe::Result {
    let t_main = Instant::now();
    let args = args();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1280.0, 800.0]).with_title("Orders"),
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };
    eframe::run_native("Orders", options, Box::new(move |cc| Ok(Box::new(Dash::new(cc, t_main, args)))))
}
