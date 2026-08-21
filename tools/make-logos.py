"""Icons and logos for the add-ons in this repository.

Run from the repository root, with Pillow installed:

    python3 tools/make-logos.py


Home Assistant shows icon.png (square, 128x128) in the add-on list and
logo.png (wide, 250x100 or so) on the add-on page. Both are drawn here rather
than hand-edited so they can be regenerated and stay consistent with each
other: same palette, same geometry, same weight.
"""
from PIL import Image, ImageDraw, ImageFont
import math, os

SS = 4  # supersampling factor: draw big, downscale, get smooth edges

# One palette for the repository, so the two add-ons read as a set. The
# wordmarks use the brand colours rather than near-black: with a transparent
# background the theme shows through, and mid-tone blue and green stay legible
# on a light card and on a dark one, which near-black does not.
INK        = (16, 20, 28)
# Not a background any more - the canvas is transparent. PAPER is now only used
# as ink *on top of* the dark shapes (the terminal body, the padlock), where it
# has to stay opaque or those shapes would have holes punched through them.
PAPER      = (247, 249, 252)
CLEAR      = (0, 0, 0, 0)
# The subtitles are small text, so they need contrast both ways. A mid slate
# beats either brand colour here: the dark greens and blues that read well on a
# white card go muddy on a dark one, and their light versions do the reverse.
SUBTITLE   = (108, 117, 131)
FEDORA     = (41, 101, 166)   # fedora blue
FEDORA_DK  = (24, 62, 105)
PODMAN     = (137, 45, 178)   # podman purple
NGINX      = (0, 150, 57)     # nginx green
NGINX_DK   = (0, 105, 40)


def canvas(w, h, bg=CLEAR):
    # RGBA on a fully transparent ground: Home Assistant shows these on a card
    # whose colour follows the user's theme, so a baked-in background would be
    # a light rectangle floating on a dark UI.
    im = Image.new("RGBA", (w * SS, h * SS), bg)
    return im, ImageDraw.Draw(im)


def finish(im, w, h, path):
    im = im.resize((w, h), Image.LANCZOS)
    im.save(path, optimize=True)
    print(path, im.size)


def font(size, bold=True):
    names = (["DejaVuSans-Bold.ttf", "DejaVuSans.ttf"] if bold else ["DejaVuSans.ttf"])
    for base in ("/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/dejavu/",
                 "/usr/share/fonts/gnu-free/", ""):
        for n in names:
            try:
                return ImageFont.truetype(base + n, size)
            except OSError:
                continue
    return ImageFont.load_default(size)


def fit(d, text, size, max_width, bold=True):
    """Largest font at or below `size` whose rendering of `text` fits
    `max_width`. Measured rather than estimated, so a longer name cannot
    silently run off the edge of the image."""
    while size > 6:
        f = font(size, bold)
        if d.textlength(text, font=f) <= max_width:
            return f
        size -= 1
    return font(size, bold)


def rounded(d, box, r, fill, outline=None, width=0):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


# --------------------------------------------------------------------------
# Nginx UI: nginx's hexagon with a control panel inside it. An "N" was tried
# first and dropped: away from nginx's own wordmark a bare letter reads as any
# initial at all, while three sliders say what this add-on is - the panel you
# configure nginx from - and they survive being scaled down to 48px, which is
# the size that decides an icon.
# --------------------------------------------------------------------------
def nui_hex(d, cx, cy, s, fill=NGINX):
    """Pointy-top hexagon centred on (cx, cy); `s` is its width across the
    flats, so the caller sizes it by the space it takes horizontally."""
    R = s / math.sqrt(3)          # circumradius; height is 2R
    pts = [(cx + R * math.sin(math.radians(a)),
            cy - R * math.cos(math.radians(a))) for a in range(0, 360, 60)]
    d.polygon(pts, fill=fill)


def nui_sliders(d, cx, cy, w, colour=PAPER):
    """Three tracks with a knob on each, centred on (cx, cy) and `w` wide.

    The knobs are deliberately at three different positions: a column of them
    would read as a bulleted list, and the point of the mark is that these are
    controls being *set*."""
    gap = w * 0.30
    lw = max(2, int(w * 0.10))
    r = lw * 1.45
    for dy, kx in ((-gap, 0.66), (0.0, 0.32), (gap, 0.74)):
        y = cy + dy
        d.line([(cx - w / 2, y), (cx + w / 2, y)], fill=colour, width=lw)
        kcx = cx - w / 2 + w * kx
        d.ellipse([kcx - r, y - r, kcx + r, y + r], fill=colour)


def nui_mark(d, cx, cy, s):
    """The hexagon with the sliders in it, as one mark."""
    nui_hex(d, cx, cy, s)
    # 0.56 of the width, so the tracks stop well inside the sloping sides -
    # at the top and bottom rows the hexagon is narrower than across its middle.
    nui_sliders(d, cx, cy, s * 0.56)


def nui_icon(path, size=128):
    im, d = canvas(size, size)
    S = size * SS
    nui_mark(d, S * 0.5, S * 0.5, S * 0.80)
    finish(im, size, size, path)


def nui_logo(path, w=560, h=160):
    im, d = canvas(w, h)
    W, H = w * SS, h * SS
    nui_mark(d, W * 0.115, H * 0.5, H * 0.70)
    x = W * 0.225
    avail = W - x - W * 0.035
    sub = "nginx  \u00b7  sites, certificates and logs from a web panel"
    f1 = fit(d, "Nginx UI", int(H * 0.34), avail)
    f2 = fit(d, sub, int(H * 0.15), avail, bold=False)
    d.text((x, H * 0.40), "Nginx UI", font=f1, fill=NGINX_DK, anchor="lm")
    d.text((x, H * 0.68), sub, font=f2, fill=SUBTITLE, anchor="lm")
    finish(im, w, h, path)


# --------------------------------------------------------------------------
# Fedora Podman Shell: a terminal prompt (the SSH shell) with containers
# stacked behind it, in fedora blue and podman purple.
# --------------------------------------------------------------------------
def fp_containers(d, x, y, s, n=3):
    """n stacked container boxes, receding up-right."""
    for i in reversed(range(n)):
        off = i * s * 0.17
        col = PODMAN if i == 0 else (
            tuple(int(c + (255 - c) * (0.30 * i)) for c in PODMAN))
        rounded(d, [x + off, y - off, x + off + s, y - off + s * 0.62],
                int(s * 0.09), col)


def fp_prompt(d, x, y, s, colour=PAPER):
    """A ">" chevron and an underscore cursor: a shell waiting for input."""
    lw = int(s * 0.13)
    d.line([(x, y - s * 0.28), (x + s * 0.30, y), (x, y + s * 0.28)],
           fill=colour, width=lw, joint="curve")
    d.line([(x + s * 0.46, y + s * 0.26), (x + s * 1.02, y + s * 0.26)],
           fill=colour, width=lw)


def fp_icon(path, size=128):
    im, d = canvas(size, size)
    S = size * SS
    # terminal window
    rounded(d, [S * 0.06, S * 0.14, S * 0.94, S * 0.86], int(S * 0.12), FEDORA_DK)
    rounded(d, [S * 0.06, S * 0.14, S * 0.94, S * 0.34], int(S * 0.12), FEDORA)
    d.rectangle([S * 0.06, S * 0.28, S * 0.94, S * 0.36], fill=FEDORA)
    for i, cx in enumerate((0.17, 0.27, 0.37)):
        r = S * 0.026
        d.ellipse([S * cx - r, S * 0.24 - r, S * cx + r, S * 0.24 + r], fill=PAPER)
    fp_prompt(d, S * 0.20, S * 0.56, S * 0.30)
    fp_containers(d, S * 0.52, S * 0.74, S * 0.30)
    finish(im, size, size, path)


def fp_logo(path, w=500, h=160):
    im, d = canvas(w, h)
    W, H = w * SS, h * SS
    rounded(d, [W * 0.03, H * 0.16, W * 0.30, H * 0.84], int(H * 0.13), FEDORA_DK)
    rounded(d, [W * 0.03, H * 0.16, W * 0.30, H * 0.36], int(H * 0.13), FEDORA)
    d.rectangle([W * 0.03, H * 0.30, W * 0.30, H * 0.38], fill=FEDORA)
    fp_prompt(d, W * 0.08, H * 0.58, H * 0.26)
    fp_containers(d, W * 0.195, H * 0.76, H * 0.24)
    x = W * 0.34
    avail = W - x - W * 0.04
    f1 = fit(d, "Fedora Podman Shell", int(H * 0.27), avail)
    f2 = fit(d, "a root shell over SSH  ·  your own containers",
             int(H * 0.15), avail, bold=False)
    d.text((x, H * 0.40), "Fedora Podman Shell", font=f1, fill=FEDORA, anchor="lm")
    d.text((x, H * 0.68), "a root shell over SSH  ·  your own containers",
           font=f2, fill=SUBTITLE, anchor="lm")
    finish(im, w, h, path)


if __name__ == "__main__":
    nui_icon("nginx_ui/icon.png")
    nui_logo("nginx_ui/logo.png")
    fp_icon("fedora_podman/icon.png")
    fp_logo("fedora_podman/logo.png")
