// mx-chart: Apache ECharts (from npm: web/package.json, pinned by package-lock.json) as a mojoui widget, in TypeScript.
// Tree-shaken: only ECharts' core, the line chart, the grid and the SVG renderer are bundled (esbuild, at build time);
// ECharts needs no eval or new Function, so it runs under the page's CSP as it is. Mojo owns the data: props.series is
// the note's word count after each edit (a JSON list of numbers); the widget only draws it, in the app's theme (the
// palette's --o-* variables). A click on a point emits "pick" {index, value}; agents read the series (describe).
/// <reference path="../../../../mojoui/hosts/static/mojoui-widgets.d.ts" />
import * as echarts from 'echarts/core';
import { LineChart } from 'echarts/charts';
import { GridComponent } from 'echarts/components';
import { SVGRenderer } from 'echarts/renderers';

echarts.use([LineChart, GridComponent, SVGRenderer]);

type Props = { series?: unknown };
type Host = HTMLElement & { mojouiChart?: echarts.ECharts; mojouiSeries?: number[]; mojouiSizes?: ResizeObserver; mojouiTokens?: mojoui.Tokens;
  mojouiAt?: number };

const numbers = (v: unknown): number[] => (Array.isArray(v) ? v.map(Number).filter(Number.isFinite) : []);

const alpha = (color: string, a: number) => {  // '#rrggbb' at opacity a (anything else as it is)
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color);
  return m ? `rgba(${parseInt(m[1], 16)},${parseInt(m[2], 16)},${parseInt(m[3], 16)},${a})` : color;
};

function palette(el: Host) {  // the app's theme: the Look's tokens (theme()), else the page's --o-* variables
  const t = el.mojouiTokens;
  if (t) {
    const face = t.font.family ? `'${t.font.family.replace(/'/g, '')}', system-ui, sans-serif` : getComputedStyle(el).fontFamily;
    return { data: t.palette.data[0] || t.palette.accent, card: t.palette.card, ink2: t.palette.ink2, line: t.palette.line, font: face };
  }
  const css = getComputedStyle(el);
  const v = (name: string, fallback: string) => css.getPropertyValue(name).trim() || fallback;
  return {
    data: v('--o-data', '#6e56cf'), card: v('--o-card', '#ffffff'),
    ink2: v('--o-ink2', '#3c3c43'), line: v('--o-line', 'rgba(120,120,128,.2)'),
    font: css.fontFamily || 'system-ui, sans-serif',
  };
}

function option(el: Host, series: number[]): echarts.EChartsCoreOption {
  const p = palette(el);
  return {
    animationDuration: 420,
    animationEasing: 'cubicOut',
    animationDurationUpdate: 360,
    textStyle: { fontFamily: p.font },
    grid: { left: 34, right: 14, top: 14, bottom: 26 },
    xAxis: {
      type: 'category', data: series.map((_, i) => String(i + 1)), boundaryGap: false,
      axisLine: { lineStyle: { color: p.line } }, axisTick: { show: false },
      axisLabel: { color: p.ink2, fontSize: 11, hideOverlap: true },
    },
    yAxis: {
      type: 'value', minInterval: 1, splitNumber: 3,
      axisLabel: { color: p.ink2, fontSize: 11 },
      splitLine: { lineStyle: { color: p.line, type: [3, 4] } },
    },
    series: [{
      type: 'line', data: series, smooth: 0.35, showSymbol: true, symbol: 'circle', symbolSize: 9,
      lineStyle: { color: p.data, width: 2.5, cap: 'round' },  // (the theme's data colour, as mojoui's own charts use)
      itemStyle: { color: p.card, borderColor: p.data, borderWidth: 2 },
      emphasis: { scale: 1.5, itemStyle: { color: p.data, borderColor: p.card } },
      areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: alpha(p.data, 0.22) }, { offset: 1, color: alpha(p.data, 0) }]) },
    }],
  };
}

mojoui.defineWidget<Props, Host>({
  tag: 'mx-chart',
  events: ['pick'],
  focusable: true,  // (a Tab stop of its own: arrows move along the points, Enter or Space picks one)
  description: "The note's word count after each edit, drawn by Apache ECharts",
  mount(el, props, emit) {
    el.mojouiSeries = numbers(props.series);
    const chart = echarts.init(el, undefined, { renderer: 'svg' });
    el.mojouiChart = chart;
    chart.setOption(option(el, el.mojouiSeries));
    chart.on('click', (e: { componentType?: string; dataIndex?: number; value?: unknown }) => {
      if (e.componentType === 'series' && typeof e.dataIndex === 'number') emit('pick', { index: e.dataIndex, value: Number(e.value) });
    });
    el.addEventListener('keydown', (e: KeyboardEvent) => {
      const s = el.mojouiSeries ?? [];
      if (!s.length) return;
      const at = el.mojouiAt ?? s.length - 1;
      const step = e.key === 'ArrowLeft' ? -1 : e.key === 'ArrowRight' ? 1 : 0;
      if (step) {
        e.preventDefault();
        chart.dispatchAction({ type: 'downplay', seriesIndex: 0, dataIndex: at });
        el.mojouiAt = Math.min(s.length - 1, Math.max(0, (el.mojouiAt === undefined ? s.length : at) + step));
        chart.dispatchAction({ type: 'highlight', seriesIndex: 0, dataIndex: el.mojouiAt });
      } else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        emit('pick', { index: at, value: s[at] });
      }
    });
    el.addEventListener('blur', () => chart.dispatchAction({ type: 'downplay', seriesIndex: 0 }));
    el.mojouiSizes = new ResizeObserver(() => chart.resize());
    el.mojouiSizes.observe(el);
  },
  update(el, props) {
    el.mojouiSeries = numbers(props.series);
    el.mojouiChart?.setOption(option(el, el.mojouiSeries));
  },
  theme(el, tokens) {  // (on mount and on every theme change: light/dark live; the series stays)
    el.mojouiTokens = tokens;
    el.mojouiChart?.setOption(option(el, el.mojouiSeries ?? []));
  },
  destroy(el) {
    el.mojouiSizes?.disconnect();
    el.mojouiChart?.dispose();
    el.mojouiChart = undefined;
  },
  describe(el) {
    const s = el.mojouiSeries ?? [];
    return { text: `${s.length} point${s.length === 1 ? '' : 's'}: ${s.join(', ')}`, value: s, points: s.length };
  },
});
