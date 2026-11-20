// Goal 79: the web app's Google Fonts requests answered from <mojo-ui>/fonts (D-7901), shared by steps.mjs (ref.mjs keeps
// its own copy, as M0's proof was committed).
import fs from 'node:fs'
import path from 'node:path'

export const FACES = {
  'Geist': [['normal', 'geist/Geist[wght].ttf'], ['italic', 'geist/Geist-Italic[wght].ttf']],
  'Geist Mono': [['normal', 'geistmono/GeistMono[wght].ttf']],
  'Bricolage Grotesque': [['normal', 'bricolagegrotesque/BricolageGrotesque[opsz,wdth,wght].ttf']],
  'IBM Plex Sans': [['normal', 'ibmplexsans/IBMPlexSans[wdth,wght].ttf'], ['italic', 'ibmplexsans/IBMPlexSans-Italic[wdth,wght].ttf']],
  'IBM Plex Mono': [['normal', 'ibmplexmono/IBMPlexMono-Regular.ttf', 400], ['normal', 'ibmplexmono/IBMPlexMono-Medium.ttf', 500], ['normal', 'ibmplexmono/IBMPlexMono-SemiBold.ttf', 600]],
  'Source Serif 4': [['normal', 'sourceserif4/SourceSerif4[opsz,wght].ttf'], ['italic', 'sourceserif4/SourceSerif4-Italic[opsz,wght].ttf']],
  'Instrument Serif': [['normal', 'instrumentserif/InstrumentSerif-Regular.ttf', 400], ['italic', 'instrumentserif/InstrumentSerif-Italic.ttf', 400]],
  'Caveat': [['normal', 'caveat/Caveat[wght].ttf']],
  'Literata': [['normal', 'literata/Literata[opsz,wght].ttf'], ['italic', 'literata/Literata-Italic[opsz,wght].ttf']],
  'Figtree': [['normal', 'figtree/Figtree[wght].ttf'], ['italic', 'figtree/Figtree-Italic[wght].ttf']],
}

export function fontCss(families) {
  return families.map((fam) => (FACES[fam] ?? []).map(([style, file, weight]) =>
    `@font-face { font-family: "${fam}"; font-style: ${style}; font-weight: ${weight ?? '100 900'}; font-display: block; src: url("https://pn-fonts.local/${encodeURI(file)}") format("truetype"); }`).join('\n')).join('\n')
}

export async function routeFonts(ctx, root, unknown = new Set()) {
  await ctx.route('https://fonts.googleapis.com/**', (route) => {
    const u = new URL(route.request().url())
    const fams = u.searchParams.getAll('family').map((f) => f.split(':')[0].replace(/\+/g, ' '))
    for (const f of fams) if (!FACES[f]) unknown.add(f)
    route.fulfill({ contentType: 'text/css', body: fontCss(fams) })
  })
  await ctx.route('https://fonts.gstatic.com/**', (route) => route.abort())
  await ctx.route('https://pn-fonts.local/**', (route) => {
    const file = decodeURI(new URL(route.request().url()).pathname.slice(1))
    route.fulfill({ contentType: 'font/ttf', body: fs.readFileSync(path.join(root, 'fonts', file)), headers: { 'access-control-allow-origin': '*' } })
  })
  return unknown
}
