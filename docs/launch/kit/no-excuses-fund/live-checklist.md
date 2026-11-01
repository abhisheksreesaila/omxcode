# What must be live on omxlabs.tech before submitting

The fund wants the product **live and working** on the .tech domain, not a landing page. The site exists
(`~/Projects/omxlabs`, plain HTML); this is what it needs on top.

## Tonight (the domain)
- [ ] Buy **omxlabs.tech**.
- [ ] Point it at the site: GitHub Pages for `~/Projects/omxlabs` (repo Settings → Pages → custom domain `omxlabs.tech`; add a `CNAME` file containing `omxlabs.tech`; at the registrar, four `A` records to GitHub Pages' IPs and a `www` CNAME to `<user>.github.io`). Tick "Enforce HTTPS" once the certificate appears.
- [ ] Push the omxlabs site commits that aren't pushed yet (cdaaee2, 47a4db0: the claim clip on the omxplorer cover and deck).
- [ ] Open https://omxlabs.tech on a phone and a laptop. Every page loads, no console errors.

## Before the Product Hunt launch
- [ ] **The robot story on the homepage:** `[clip: robots-45s]` (mp4 + poster jpg in `assets/img/`), with its source line (DROID, 13 labs, CC-BY-4.0, the 994-episode sample).
- [ ] **A way to try it, one click from the homepage** ("Meet omxplorer" becomes "Try omxplorer", per the omxlabs README):
  - [ ] Linux: the install lines (`git clone … && pixi install && scripts/omxplorer.sh`), and what you need (x86-64, GTK 4, NVIDIA for the GPU path).
  - [ ] Mac: the download link (github.com/abhisheksreesaila/omxcode/releases/tag/mac-app), with "CPU build" stated until the GPU build ships.
  - [ ] **Hosted demo** (the strongest proof of "live and working"): omxplorer's web host (`scripts/omxplorer.sh web`) on a GPU machine behind `try.omxlabs.tech`, with a sample file loaded. One app state per tab already exists; add a cap on concurrent sessions and an idle timeout before opening it to the public.
- [ ] The "what isn't done" line on the omxplorer cover: web on WebGPU, Android and iPhone next (roadmap, not apology).
- [ ] Every number on the site has its mono source line (it already does on the existing pages; keep it for the new ones).
- [ ] DROID's attribution (CC-BY-4.0 asks for it): "DROID, Khazatsky et al. 2024, CC-BY-4.0" with a link, on any page or clip that shows the data.
- [ ] Links to: the GitHub repo, the YouTube videos, the X account.

## Before submitting (by Dec 15)
- [ ] The hosted demo has stayed up for at least a week; note uptime.
- [ ] The traction numbers in submission.md are filled in from real counts.
- [ ] Re-read the fund's rules on the page itself (our copy couldn't read it) and match the form's questions.
