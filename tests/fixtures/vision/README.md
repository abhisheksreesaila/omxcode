# Vision test images

Fixed inputs for `mxconsole.vision.reference` and `mxconsole.vision.parity`. All come from scikit-image's sample
data (tag v0.22.0, `skimage/data/`), shrunk to at most 480 px on the long side and saved as JPEG (quality 90).
`cat_gray.jpg` is `cat.jpg` in greyscale (mode L), to exercise the RGB conversion.

| file | source | licence (as stated in `skimage/data/_fetchers.py`) |
|---|---|---|
| cat.jpg, cat_gray.jpg | chelsea.png, Stefan van der Walt | CC0 |
| coffee.jpg | coffee.png, Rachel Michetti (Pikolo Espresso Bar) | CC0 |
| astronaut.jpg | astronaut.png, NASA Great Images (Eileen Collins) | public domain |
| rocket.jpg | rocket.jpg, SpaceX (DSCOVR launch) | public domain |
