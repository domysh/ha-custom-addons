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
LOCK       = (34, 173, 122)   # tls green
LOCK_DK    = (20, 122, 86)
NGINX      = (0, 150, 57)


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
# TLS Proxy: a padlock whose shackle is the routing that goes through it.
# --------------------------------------------------------------------------
def tls_lock(d, cx, cy, s, body=LOCK, dark=LOCK_DK):
    """Padlock centred on (cx, cy); s is the body width."""
    bw, bh = s, s * 0.78
    top = cy - bh * 0.15
    # Shackle: a half circle whose two ends stop at the body's top edge, plus
    # the straight bits down to it, so it reads as one piece and not as an arc
    # floating above a box.
    #
    # The two have to be aligned by hand, because Pillow strokes them
    # differently: `arc` grows its width *inwards* from the bounding box, so its
    # centreline sits at radius - width/2, while `line` centres its width on the
    # path. Using the same radius for both leaves a step of half the stroke
    # width exactly where the curve meets the straight - which is what the top
    # of the padlock looked wrong for.
    sw = int(s * 0.14)
    r = bw * 0.32                 # outer radius, i.e. the arc's bounding box
    rc = r - sw / 2               # the radius the arc is actually drawn on
    arc_cy = top - r * 0.6
    d.arc([cx - r, arc_cy - r, cx + r, arc_cy + r], start=180, end=360,
          fill=dark, width=sw)
    for sx in (-rc, rc):
        # From the arc's endpoint straight down into the body. The overlap into
        # the body hides the butt end of the stroke.
        d.line([(cx + sx, arc_cy), (cx + sx, top + sw * 0.4)],
               fill=dark, width=sw)
    # body
    rounded(d, [cx - bw / 2, top, cx + bw / 2, top + bh], int(bw * 0.18), body)
    # keyhole
    kr = bw * 0.11
    d.ellipse([cx - kr, top + bh * 0.28 - kr, cx + kr, top + bh * 0.28 + kr], fill=PAPER)
    d.polygon([(cx - kr * 0.55, top + bh * 0.30), (cx + kr * 0.55, top + bh * 0.30),
               (cx + kr * 0.30, top + bh * 0.66), (cx - kr * 0.30, top + bh * 0.66)],
              fill=PAPER)


def tls_routes(d, x, cy, spread, w, colour=NGINX, lw=None):
    """One line in from the left, three out to the right, each ending in a dot:
    the routing the proxy does. `spread` is the distance to the outer lines."""
    lw = lw or max(2, int(spread * 0.16))
    fork = x + w * 0.34
    d.line([(x, cy), (fork, cy)], fill=colour, width=lw)
    r = lw * 1.5
    for dy in (-spread, 0.0, spread):
        d.line([(fork, cy), (fork + w * 0.30, cy + dy), (x + w - r, cy + dy)],
               fill=colour, width=lw, joint="curve")
        d.ellipse([x + w - r * 2, cy + dy - r, x + w, cy + dy + r], fill=colour)


def tls_flow(d, x, cy, w, spread):
    """The whole story in one mark, left to right: traffic arrives, passes
    *through* the padlock, and fans out to three backends.

    The earlier version set the padlock beside the fan, which made two marks
    sharing a space rather than one mark - and left the lock off the path it is
    supposed to be the gate for. Everything here is a fraction of the mark's
    width `w`, so the three parts keep their spacing at any size: the padlock
    has to stay clear of the entry dot on one side and of the fork on the
    other, or it reads as touching them."""
    lock_w = w * 0.30
    lock_cx = x + w * 0.19
    fork = x + w * 0.44
    lw = max(2, int(w * 0.045))
    r = lw * 1.6

    # Inbound: just the line, entering from the edge. An entry dot was tried
    # and dropped - at this size the padlock covers it, and the asymmetry of
    # "plain line in, three dots out" already gives the mark its direction.
    d.line([(x, cy), (fork, cy)], fill=NGINX, width=lw)

    # Outbound: three domains, each ending in its own dot.
    for dy in (-spread, 0.0, spread):
        d.line([(fork, cy), (fork + (x + w - fork) * 0.42, cy + dy),
                (x + w - r, cy + dy)],
               fill=NGINX, width=lw, joint="curve")
        d.ellipse([x + w - r * 2, cy + dy - r, x + w, cy + dy + r], fill=NGINX)

    # The lock last, so it sits on the line rather than beside it.
    tls_lock(d, lock_cx, cy - lock_w * 0.06, lock_w)


def tls_icon(path, size=128):
    im, d = canvas(size, size)
    S = size * SS
    # The padlock alone. Two attempts at putting the logo's routing fan under
    # it were dropped after checking the icon at the sizes it is actually
    # rendered: at 48px and below the three branches and their dots merge into
    # a smudge, and they took contrast away from the one shape that still reads
    # there. The routing is the logo's job, where there is room for it.
    # No tile behind it either - the theme provides the background.
    tls_lock(d, S * 0.5, S * 0.46, S * 0.62)
    finish(im, size, size, path)


def tls_logo(path, w=560, h=160):
    im, d = canvas(w, h)
    W, H = w * SS, h * SS
    tls_flow(d, W * 0.035, H * 0.50, W * 0.32, H * 0.25)
    x = W * 0.40
    avail = W - x - W * 0.035
    f1 = fit(d, "TLS Proxy", int(H * 0.34), avail)
    f2 = fit(d, "nginx  ·  TLS termination, routing by domain",
             int(H * 0.15), avail, bold=False)
    d.text((x, H * 0.40), "TLS Proxy", font=f1, fill=LOCK_DK, anchor="lm")
    d.text((x, H * 0.68), "nginx  ·  TLS termination, routing by domain",
           font=f2, fill=SUBTITLE, anchor="lm")
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
    tls_icon("tls_proxy/icon.png")
    tls_logo("tls_proxy/logo.png")
    fp_icon("fedora_podman/icon.png")
    fp_logo("fedora_podman/logo.png")
