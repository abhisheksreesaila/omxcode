# usage: covershot.py <path under the site> <outprefix> [deck]   (COVER_BASE: the site's URL, default http://127.0.0.1:8732/)
#   screenshots desktop+phone, reports console errors and overflow
import os, sys, asyncio
from playwright.async_api import async_playwright
path, out = sys.argv[1], sys.argv[2]; deck = len(sys.argv) > 3
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path="/usr/bin/chromium")
        for name, w, h in ([("desk", 1600, 900)] if deck else [("desk", 1440, 900), ("phone", 390, 844)]):
            pg = await b.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            errs = []; pg.on("console", lambda m: m.type == "error" and errs.append(m.text)); pg.on("pageerror", lambda e: errs.append(str(e)))
            await pg.goto(os.environ.get("COVER_BASE", "http://127.0.0.1:8732/") + path, wait_until="networkidle")
            await pg.emulate_media(reduced_motion="reduce")
            if deck:
                n = await pg.evaluate("Reveal.getTotalSlides()")
                for i in range(n):
                    await pg.evaluate(f"Reveal.slide({i}); while(Reveal.nextFragment()){{}}")
                    await pg.wait_for_timeout(900)
                    await pg.screenshot(path=f"{out}-s{i+1:02d}.png")
                print(name, "slides", n, "errors", errs[:5]); continue
            await pg.evaluate("document.querySelectorAll('.rv').forEach(e=>e.classList.add('in')); document.querySelectorAll('iframe').forEach(f=>{f.loading='eager'; f.src=f.src})")
            await pg.wait_for_timeout(2500)
            await pg.wait_for_timeout(1500)
            ov = await pg.evaluate("document.documentElement.scrollWidth > innerWidth")
            await pg.screenshot(path=f"{out}-{name}.png", full_page=True)
            print(name, "overflow", ov, "errors", errs[:5])
        await b.close()
asyncio.run(main())
