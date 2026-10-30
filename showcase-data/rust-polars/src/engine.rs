//! The data side: the orders table in memory (Polars), and one query per filter state.
//!
//! Loaded once: the Parquet file is read with Polars' lazy scan, `region` and `product` become categoricals (u8
//! codes), and the rows are sorted by `day` (stable, so `id` stays ascending within a day). The sort is the one
//! layout choice: a date range becomes a zero-copy slice found by binary search, so a narrow range never touches the
//! rest. Every filter change then runs over every row in that slice: no pre-aggregation, no cached results.

use polars::prelude::*;
use std::path::Path;
use std::time::Instant;

pub const TOP: usize = 20;
pub const IDS: usize = 50;

#[derive(Clone, Debug, PartialEq)]
pub struct Filter {
    pub from: i32, // days since 1970-01-01, inclusive
    pub to: i32,   // inclusive
    pub min_amount: f64,
    pub region: String, // "all" or one region
}

#[derive(Clone, Debug)]
pub struct Row {
    pub id: i64,
    pub day: i32,
    pub region: String,
    pub product: String,
    pub amount: f64,
    pub cost: f64,
    pub paid: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Answer {
    pub rows: u64,
    pub sum_amount: f64,
    pub avg_margin: Option<f64>,
    pub top: Vec<(String, f64)>,
    pub table: Vec<Row>,
}

pub struct Data {
    df: DataFrame,      // sorted by day, then id
    day: Vec<i32>,      // the sorted day column, for the binary search
    pub regions: Vec<String>,
    pub load_ms: f64,
}

impl Data {
    pub fn load(path: &Path) -> PolarsResult<Data> {
        let t0 = Instant::now();
        let cat = |name: &str| DataType::from_categories(Categories::new(name.into(), "dash".into(), CategoricalPhysical::U8));
        let mut df = LazyFrame::scan_parquet(PlRefPath::new(path.to_str().unwrap()), ScanArgsParquet::default())?
            .with_columns([col("region").cast(cat("region")), col("product").cast(cat("product"))])
            .sort(["day"], SortMultipleOptions::default().with_maintain_order(true))
            .collect()?;
        df.rechunk_mut_par();
        let day: Vec<i32> = df.column("day")?.date()?.physical().cont_slice()?.to_vec();
        let mut regions: Vec<String> = df
            .column("region")?
            .unique()?
            .cast(&DataType::String)?
            .str()?
            .iter()
            .flatten()
            .map(String::from)
            .collect();
        regions.sort();
        Ok(Data { df, day, regions, load_ms: t0.elapsed().as_secs_f64() * 1e3 })
    }

    pub fn len(&self) -> usize {
        self.df.height()
    }

    pub fn query(&self, f: &Filter) -> PolarsResult<Answer> {
        let lo = self.day.partition_point(|&d| d < f.from);
        let hi = self.day.partition_point(|&d| d <= f.to).max(lo);
        let mut pred = col("amount").gt_eq(lit(f.min_amount));
        if f.region != "all" {
            pred = pred.and(col("region").eq(lit(f.region.as_str())));
        }
        let matched = |lo: usize, hi: usize| self.df.slice(lo as i64, hi - lo).lazy().filter(pred.clone());

        // One pass gives the bars and the KPIs: per product, the count, the sum and the margins' sum. Polars'
        // streaming engine runs it morsel by morsel across every core (about twice the in-memory engine here).
        let groups = matched(lo, hi)
            .group_by([col("product")])
            .agg([
                len().alias("n"),
                col("amount").sum().alias("s"),
                ((col("amount") - col("cost")) / col("amount")).sum().alias("m"),
            ])
            .with_column(col("product").cast(DataType::String))
            .collect_with_engine(Engine::Streaming)?
            .unwrap_single();

        // The table: a hand-written optimisation (not plain Polars; build D has an equivalent, a per-day histogram that
        // finds the cutoff day). The first 50 by day descending, then id ascending. The rows are sorted by day, so the answer
        // sits at the slice's end: find the 50 last matching rows in a growing suffix (usually the first 64K rows
        // hold them), and the day d of the earliest; then sort only the matching rows from day d on.
        let mut w = 1usize << 16;
        let last = loop {
            let start = hi.saturating_sub(w).max(lo);
            let tail = matched(start, hi).select([col("day")]).tail(IDS as IdxSize).collect()?;
            if tail.height() == IDS || start == lo {
                break if tail.height() == 0 { None } else { tail.column("day")?.date()?.physical().get(0) };
            }
            w *= 8;
        };
        let table = match last {
            None => DataFrame::empty(),
            Some(d) => {
                let from = self.day[lo..hi].partition_point(|&x| x < d) + lo;
                matched(from, hi)
                    .sort_by_exprs(
                        [col("day"), col("id")],
                        SortMultipleOptions {
                            limit: Some(IDS as IdxSize),
                            ..SortMultipleOptions::default().with_order_descending_multi([true, false])
                        },
                    )
                    .limit(IDS as IdxSize)
                    .with_columns([col("region").cast(DataType::String), col("product").cast(DataType::String)])
                    .collect()?
            }
        };

        let names = groups.column("product")?.str()?;
        let n = groups.column("n")?.idx()?;
        let s = groups.column("s")?.f64()?;
        let m = groups.column("m")?.f64()?;
        let mut a = Answer::default();
        let mut margin = 0.0;
        let mut ranked = Vec::with_capacity(groups.height());
        for i in 0..groups.height() {
            let (k, sum) = (n.get(i).unwrap() as u64, s.get(i).unwrap_or(0.0));
            a.rows += k;
            a.sum_amount += sum;
            margin += m.get(i).unwrap_or(0.0);
            ranked.push((names.get(i).unwrap().to_string(), sum));
        }
        a.avg_margin = (a.rows > 0).then(|| margin / a.rows as f64);
        ranked.sort_by(|x, y| y.1.total_cmp(&x.1).then_with(|| x.0.cmp(&y.0)));
        ranked.truncate(TOP);
        a.top = ranked;

        if table.height() == 0 {
            return Ok(a);
        }
        let id = table.column("id")?.i64()?;
        let day = table.column("day")?.date()?.physical().clone();
        let region = table.column("region")?.str()?;
        let product = table.column("product")?.str()?;
        let amount = table.column("amount")?.f64()?;
        let cost = table.column("cost")?.f64()?;
        let paid = table.column("paid")?.bool()?;
        a.table = (0..table.height())
            .map(|i| Row {
                id: id.get(i).unwrap(),
                day: day.get(i).unwrap(),
                region: region.get(i).unwrap().to_string(),
                product: product.get(i).unwrap().to_string(),
                amount: amount.get(i).unwrap(),
                cost: cost.get(i).unwrap(),
                paid: paid.get(i).unwrap(),
            })
            .collect();
        Ok(a)
    }
}

/// Days since 1970-01-01 → (year, month, day), and back (Howard Hinnant's civil calendar algorithms).
pub fn civil(z: i32) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + (m <= 2) as i32, m, d)
}

pub fn days(y: i32, m: u32, d: u32) -> i32 {
    let y = y - (m <= 2) as i32;
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) as i32 / 5 + d as i32 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn parse_date(s: &str) -> i32 {
    let p: Vec<i32> = s.split('-').map(|x| x.parse().unwrap()).collect();
    days(p[0], p[1] as u32, p[2] as u32)
}

pub fn fmt_date(z: i32) -> String {
    let (y, m, d) = civil(z);
    format!("{y:04}-{m:02}-{d:02}")
}
