# mojoui.mdinline held to what the web page's own parser (Lezer Markdown, GFM) says of these lines (made with it on 2026-11-24:
# each [classes|text]: m mark, b bold, i slanted, s struck, c code, l link, u address). mdinline: ok
#   pixi run mojo run -I . tests/test_mdinline.mojo
from std.testing import assert_equal
from mojoui.mdinline import inline_flags, MARK, BOLD, ITALIC, STRIKE, CODE, LINK, URL


def said(line: String) -> String:
    var f = inline_flags(line, 0)
    var out = String("")
    var k = 0
    var n = line.byte_length()
    while k < n:
        var e = k
        while e < n and f[e] == f[k]:
            e += 1
        var c = String("")
        for p in [(BOLD, "b"), (CODE, "c"), (ITALIC, "i"), (LINK, "l"), (MARK, "m"), (STRIKE, "s"), (URL, "u")]:
            if (f[k] & p[0]) != 0:
                c += String(p[1])
        out += "[" + c + "|" + String(line[byte=k:e]) + "]"
        k = e
    return out


def main() raises:
    var rows: List[Tuple[String, String]] = [
        ("plain _under_ and __strong__ and snake_case_word and 2*3*4", "[|plain ][im|_][i|under][im|_][| and ][bm|__][b|strong][bm|__][| and snake_case_word and 2][im|*][i|3][im|*][|4]"),
        ("**bold** *it* ***both*** `co**de` ~~st~~ end", "[bm|**][b|bold][bm|**][| ][im|*][i|it][im|*][| ][im|*][bim|**][bi|both][bim|**][im|*][| ][m|`][c|co**de][m|`][| ][ms|~~][s|st][ms|~~][| end]"),
        ("a \\*not\\* it, a \\_b\\_", "[|a \\*not\\* it, a \\_b\\_]"),
        ("see https://example.org/a?b=1 and www.x.org and <http://y.z>", "[|see ][u|https://example.org/a?b=1][| and ][u|www.x.org][| and ][m|<][u|http://y.z][m|>]"),
        ("[words](http://a.b \"t\") and ![pic](p.png) and [ref][1]", "[lm|[][l|words][lm|](][lu|http://a.b][l| \"t\"][lm|)][| and ][lm|![][l|pic][lm|](][lu|p.png][lm|)][| and ][lm|[][l|ref][lm|]][l|[1]]"),
        ("`unclosed and **unclosed", "[|`unclosed and **unclosed]"),
        ("a*b*c and **a**b", "[|a][im|*][i|b][im|*][|c and ][bm|**][b|a][bm|**][|b]"),
        ("text with * star * alone", "[|text with * star * alone]"),
        ("line ending with two spaces  ", "[|line ending with two spaces  ]"),
        ("[foo] bar and [a] b", "[lm|[][l|foo][lm|]][| bar and ][lm|[][l|a][lm|]][| b]"),
        ("[x](y) **[b](c)** *[i](j)*", "[lm|[][l|x][lm|](][lu|y][lm|)][| ][bm|**][blm|[][bl|b][blm|](][blu|c][blm|)][bm|**][| ][im|*][ilm|[][il|i][ilm|](][ilu|j][ilm|)][im|*]"),
        ("*a **b** c* and **a *b* c** and ***x** y* and *x **y***", "[im|*][i|a ][bim|**][bi|b][bim|**][i| c][im|*][| and ][bm|**][b|a ][bim|*][bi|b][bim|*][b| c][bm|**][| and ][im|*][bim|**][bi|x][bim|**][i| y][im|*][| and ][im|*][i|x ][bim|**][bi|y][bim|**][im|*]"),
        ("_a_b and a_b_ and __init__ and _a *b* c_", "[im|_][i|a_b and a_b][im|_][| and ][bm|__][b|init][bm|__][| and ][im|_][i|a ][im|*][i|b][im|*][i| c][im|_]"),
        ("`` a`b `` and ```x``` and ` `", "[m|``][c| a`b ][m|``][| and ][m|```][c|x][m|```][| and ][m|`][c| ][m|`]"),
        ("**not closed *em* and ~one~ ~~two~~ three~~", "[|**not closed ][im|*][i|em][im|*][| and ~one~ ][ms|~~][s|two][ms|~~][| three~~]"),
        ("http://a.b/c). (https://x.y/z) end, https://q.w. And mailto: a@b.c", "[u|http://a.b/c][|). (][u|https://x.y/z][|) end, ][u|https://q.w][|. And mailto: ][u|a@b.c]"),
        ("!![x](y) \\[no](no) [a\\]b](c) [a [n] b](c) [t](<u v> 'x')", "[|!][lm|![][l|x][lm|](][lu|y][lm|)][| \\[no](no) ][lm|[][l|a\\]b][lm|](][lu|c][lm|)][| [a ][lm|[][l|n][lm|]][| b](c) ][lm|[][l|t][lm|](][lu|<u v>][l| 'x'][lm|)]"),
        ("**bold**text and te**xt** and **\"q\"**x and *(x)*y", "[bm|**][b|bold][bm|**][|text and te][bm|**][b|xt][bm|**][| and **\"q\"**x and *(x)*y]"),
        ("a ** b ** c and * * and **** and a***b***c", "[|a ** b ** c and * * and **** and a][im|*][bim|**][bi|b][bim|**][im|*][|c]"),
    ]
    var bad = 0
    for r in rows:
        if said(r[0]) != r[1]:
            bad += 1
            print("line", r[0], "\n  web   ", r[1], "\n  native", said(r[0]))
    assert_equal(bad, 0)
    print("mdinline: ok,", len(rows), "lines")
