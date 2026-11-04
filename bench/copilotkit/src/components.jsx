// Plain React components for the render_ui catalog. Every prop may be missing while the args stream.
const arr = (v) => (Array.isArray(v) ? v : []);
const nums = (v) => arr(v).filter((x) => typeof x === "number" && Number.isFinite(x));
const str = (v) => (v == null ? "" : String(v));

function Kids({ node }) {
  return arr(node.children).map((c, i) => <Node key={i} node={c} />);
}

function Spark({ values, width = 100, height = 24 }) {
  const v = nums(values);
  if (v.length < 2) return <svg className="spark" width={width} height={height} />;
  const lo = Math.min(...v), hi = Math.max(...v), span = hi - lo || 1;
  const pts = v.map((y, i) => `${((i / (v.length - 1)) * width).toFixed(1)},${(height - 2 - ((y - lo) / span) * (height - 4)).toFixed(1)}`);
  return (
    <svg className="spark" width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      <polyline points={pts.join(" ")} fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

const GAP = { s: 6, m: 12, l: 20 };
const gap = (g) => (typeof g === "number" ? g : GAP[g] ?? 12);

const C = {
  VStack: (n) => <div className="vstack" style={{ gap: gap(n.gap) }}><Kids node={n} /></div>,
  HStack: (n) => <div className="hstack" style={{ gap: gap(n.gap) }}><Kids node={n} /></div>,
  Grid: (n) => (
    <div className="grid" style={{ gridTemplateColumns: `repeat(${Math.max(1, Number(n.columns) || 2)}, minmax(0, 1fr))` }}>
      <Kids node={n} />
    </div>
  ),
  Card: (n) => (
    <div className="card">
      {n.title && <div className="card-title">{str(n.title)}</div>}
      {n.subtitle && <div className="card-subtitle">{str(n.subtitle)}</div>}
      <Kids node={n} />
    </div>
  ),
  Text: (n) => <div className={`text text-${n.style || "body"}`}>{str(n.text)}</div>,
  KpiView: (n) => (
    <div className="card kpi">
      <div className="kpi-label">{str(n.label)}</div>
      <div className="kpi-value">{str(n.value)}</div>
      <div className="kpi-row">
        <span className="kpi-note">{str(n.note)}</span>
        <Spark values={n.spark} width={64} height={20} />
      </div>
    </div>
  ),
  Meter: (n) => {
    const v = Math.max(0, Math.min(100, Number(n.value) || 0));
    return (
      <div className="meter">
        <div className="meter-head"><span>{str(n.label)}</span><span>{str(n.figure)}</span></div>
        <div className="meter-track"><div className="meter-fill" style={{ width: `${v}%` }} /></div>
      </div>
    );
  },
  ChartView: (n) => {
    const labels = arr(n.labels), values = nums(n.values);
    const max = Math.max(1, ...values), rowH = 24, labelW = 80, w = 480;
    return (
      <div className="card">
        {n.title && <div className="card-title">{str(n.title)}</div>}
        <svg width={w} height={Math.max(1, values.length) * rowH} viewBox={`0 0 ${w} ${Math.max(1, values.length) * rowH}`} className="chart">
          {values.map((v, i) => {
            const bw = ((w - labelW - 50) * v) / max;
            return (
              <g key={i} transform={`translate(0 ${i * rowH})`}>
                <text x={labelW - 6} y={rowH / 2 + 4} textAnchor="end" className="chart-label">{str(labels[i])}</text>
                <rect x={labelW} y={4} width={bw} height={rowH - 8} rx={3} className="chart-bar" />
                <text x={labelW + bw + 4} y={rowH / 2 + 4} className="chart-value">{v}</text>
              </g>
            );
          })}
        </svg>
      </div>
    );
  },
  DataGrid: (n) => (
    <div className="datagrid" style={{ height: Number(n.height) || 240 }}>
      <table>
        <thead><tr>{arr(n.columns).map((c, i) => <th key={i}>{str(c)}</th>)}</tr></thead>
        <tbody>
          {arr(n.rows).map((r, i) => (
            <tr key={i}>{arr(r).map((c, j) => <td key={j}>{str(c)}</td>)}</tr>
          ))}
        </tbody>
      </table>
    </div>
  ),
  Sparkline: (n) => (
    <div className="sparkline">
      {n.label && <span className="kpi-label">{str(n.label)}</span>}
      <Spark values={n.values} width={160} height={32} />
    </div>
  ),
  Button: (n) => <button type="button" className="btn">{str(n.label)}</button>,
  Chip: (n) => <span className="chip">{str(n.text)}</span>,
  Divider: () => <hr className="divider" />,
  Spacer: () => <div className="spacer" />,
  Alert: (n) => (
    <div className="alert" role="alert">
      {n.title && <strong>{str(n.title)}</strong>}
      <div>{str(n.text)}</div>
    </div>
  ),
  Skeleton: (n) => (
    <div className="skeleton">
      {Array.from({ length: Math.max(1, Math.min(20, Number(n.lines) || 3)) }, (_, i) => <div key={i} className="skeleton-line" />)}
    </div>
  ),
};

export function Node({ node }) {
  if (!node || typeof node !== "object") return null;
  const draw = C[node.component];
  return draw ? draw(node) : null;
}
