#!/usr/bin/env python3
"""Generate templates/partials/hero-knot.html -- the woven three-ring hero mark.

Three identical circles of radius R, each tilted TAU out of the screen plane
and then spun by PHI_i about the view axis.  Orthographic projection turns
each into an ellipse (semi-axes R and R*cos TAU) whose depth is
z = R*sin(TAU)*sin(theta) -- a function of the ring parameter alone.

Every ring is cut at its own z=0 points and at every crossing with another
ring, then all pieces are painted back to front.  That is a painter's
algorithm over a real 3D embedding, so the over/under pattern is the one the
solid would actually show: the weave is derived, not hand-authored.

Each ring is drawn not as a stroke but as a ribbon: a strip of filled quads
whose width, brightness and specular glint are computed per sample from the
same embedding.  The ribbon swells and brightens on the near side of its
turn, narrows and falls toward the page colour on the far side, and carries
tight glints where the tube would catch a light from the upper left.  A
soft shadow strip under each chunk is what the crossings read by.

The quads carry only two numbers into the page -- --d (depth brightness)
and --s (specular) -- and the stylesheet turns those into theme-aware
colour.  Regenerate rather than edit the emitted arcs by hand.
"""
import math
import pathlib

C = 120.0            # centre of the 240x240 viewBox
R = 113.0            # ring radius
TAU = math.radians(55.0)
PHI = [0.0, 60.0, 120.0]
DISC = 79.0          # radius of the core disc
STEPS = 4000         # sampling resolution for crossing detection

CHUNK = math.radians(8.0)    # z-sort granularity: one shadow + a few quads
QUAD = math.radians(3.2)     # quad size inside a chunk
WMIN, WMAX = 1.9, 6.3        # ribbon width, far side to near side
SHADOW_PAD = 1.2             # how far the shadow strip reaches past each edge
SHADOW_OFF = 2.4             # cast distance, resolved per sample (see below)
EPS = 0.15                   # forward overlap between quads, hides AA seams
OCC_DEPTH = 0.45             # how far the under strand dips at a crossing
OCC_SIGMA = 11.0             # dip radius along the strand, in arc units
PEN = math.radians(35.0)     # calligraphic pen angle (screen space)
CAL = 0.12                   # strength of the pen-angle width modulation
LX, LY = -0.5473, -0.8370    # light direction (upper left; screen y is down)
SPEC_POW = 7                 # glint tightness
D_GAMMA = 1.35               # depth-brightness falloff
W_GAMMA = 1.15               # width falloff

RY = R * math.cos(TAU)
ZAMP = R * math.sin(TAU)

OUT = pathlib.Path(__file__).resolve().parents[2] / "templates/partials/hero-knot.html"


def pt(i, th):
    p = math.radians(PHI[i])
    cx, sx = math.cos(p), math.sin(p)
    a, b = R * math.cos(th), RY * math.sin(th)
    return (C + a * cx - b * sx, C + a * sx + b * cx)


def tangent(i, th):
    p = math.radians(PHI[i])
    cx, sx = math.cos(p), math.sin(p)
    dx, dy = -R * math.sin(th), RY * math.cos(th)
    tx, ty = dx * cx - dy * sx, dx * sx + dy * cx
    n = math.hypot(tx, ty)
    return tx / n, ty / n


def z(th):
    return ZAMP * math.sin(th)


def nearness(th):
    """0 at the far side of the turn, 1 at the near side."""
    return (math.sin(th) + 1) / 2


def width(i, th):
    """Ribbon width: swells toward the viewer, with a slight calligraphic
    bias so the strokes read brushed rather than machined."""
    t = nearness(th) ** W_GAMMA
    tx, ty = tangent(i, th)
    cal = 1 + CAL * math.cos(2 * (math.atan2(ty, tx) - PEN))
    return (WMIN + (WMAX - WMIN) * t) * cal


def spec(i, th):
    """Glint where the tube runs perpendicular to the light, near side only."""
    tx, ty = tangent(i, th)
    cross = abs(tx * LY - ty * LX)
    return (cross ** SPEC_POW) * (nearness(th) ** 2)


def implicit(i, x, y):
    """<0 inside ring i's ellipse, >0 outside."""
    p = math.radians(PHI[i])
    dx, dy = x - C, y - C
    u = dx * math.cos(p) + dy * math.sin(p)
    v = -dx * math.sin(p) + dy * math.cos(p)
    return (u / R) ** 2 + (v / RY) ** 2 - 1.0


def crossings(i, j):
    """theta values on ring i where it crosses ring j."""
    out = []
    prev_th = 0.0
    prev = implicit(j, *pt(i, prev_th))
    for k in range(1, STEPS + 1):
        th = 2 * math.pi * k / STEPS
        cur = implicit(j, *pt(i, th))
        if prev * cur < 0:
            lo, hi = prev_th, th
            for _ in range(60):
                mid = (lo + hi) / 2
                if implicit(j, *pt(i, mid)) * prev < 0:
                    hi = mid
                else:
                    lo = mid
            out.append((lo + hi) / 2)
        prev_th, prev = th, cur
    return out


def dedupe(vals, eps=1e-4):
    vals = sorted(v % (2 * math.pi) for v in vals)
    out = []
    for v in vals:
        if not out or abs(v - out[-1]) > eps:
            out.append(v)
    if len(out) > 1 and abs(out[0] + 2 * math.pi - out[-1]) < eps:
        out.pop()
    return out


def fmt(v):
    s = f"{v:.1f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def edge(i, th, sign, pad=0.0):
    """A point on the ribbon's edge: centreline offset along the normal."""
    x, y = pt(i, th)
    tx, ty = tangent(i, th)
    h = width(i, th) / 2 + pad
    return (x - sign * ty * h, y + sign * tx * h)


# --- pair up the crossings and note who passes under whom ------------------
# For each crossing point, the strand with the smaller z at that point is the
# under strand. It gets an "occlusion dip": its brightness eases down as it
# approaches the crossing and back up leaving it, on BOTH sides, which is
# what makes the over strand read as resting on it. The cast shadow alone
# cannot do this -- it falls on one side only, and the strand meeting the
# over edge at full brightness on the other side reads as two pictures
# pasted together.

under = {0: [], 1: [], 2: []}      # ring -> [theta of a crossing it dips at]
for i in range(3):
    for j in range(i + 1, 3):
        cs_i, cs_j = crossings(i, j), crossings(j, i)
        for ta in cs_i:
            pa = pt(i, ta)
            tb = min(cs_j, key=lambda t: (pt(j, t)[0] - pa[0]) ** 2 +
                                         (pt(j, t)[1] - pa[1]) ** 2)
            if z(ta) < z(tb):
                under[i].append(ta)
            else:
                under[j].append(tb)


def occlusion(i, th):
    """0 clear of any crossing this strand passes under, ~1 right at one."""
    o = 0.0
    for tc in under[i]:
        d = abs((th - tc + math.pi) % (2 * math.pi) - math.pi)
        # arc distance, using the local projected speed at the crossing
        x, y = pt(i, tc)
        tx, ty = -R * math.sin(tc), RY * math.cos(tc)
        s = d * math.hypot(tx, ty)
        o = max(o, math.exp(-((s / OCC_SIGMA) ** 2)))
    return o


# --- cut each ring at horizons and crossings, then chop into chunks --------

chunks = []
for i in range(3):
    cuts = [0.0, math.pi]
    for j in range(3):
        if j != i:
            cuts += crossings(i, j)
    cuts = dedupe(cuts)
    for k, a in enumerate(cuts):
        b = cuts[(k + 1) % len(cuts)]
        if b <= a:
            b += 2 * math.pi
        n = max(1, math.ceil((b - a) / CHUNK))
        for s in range(n):
            t0 = a + (b - a) * s / n
            t1 = a + (b - a) * (s + 1) / n
            chunks.append({"ring": i, "a": t0, "b": t1, "z": z((t0 + t1) / 2)})

chunks.sort(key=lambda c: c["z"])


def emit_chunk(c, indent):
    i, a, b = c["ring"], c["a"], c["b"]
    # Inside an occlusion dip the brightness changes fast, and at the base
    # quad size the eye reads the per-quad steps as facets: subdivide finer
    # wherever the dip is in play.
    q = QUAD / 3 if max(occlusion(i, a), occlusion(i, b),
                        occlusion(i, (a + b) / 2)) > 0.04 else QUAD
    nq = max(1, math.ceil((b - a) / q))
    ths = [a + (b - a) * k / nq for k in range(nq + 1)]
    lines = []

    # Shadow strip: the ribbon's outline, padded a little and displaced away
    # from the light, one filled path per chunk so its edges join the
    # neighbouring chunks' exactly. The displacement is what makes it read
    # as a cast shadow rather than a halo -- on the cream theme especially,
    # a symmetric dark outline reads as blur, not depth. It is not a fixed
    # vector: that would have a tangential component sliding each chunk's
    # shadow onto its neighbours' ribbon, a dark tick every chunk. Instead
    # the away-from-light vector is projected onto the local normal, so the
    # shadow always falls beside the ribbon and thins where the ribbon runs
    # parallel to the light.
    def sh(th, sign):
        x, y = edge(i, th, sign, SHADOW_PAD)
        tx, ty = tangent(i, th)
        nx, ny = -ty, tx
        proj = SHADOW_OFF * (-LX * nx + -LY * ny)
        return (x + nx * proj, y + ny * proj)

    outer = [sh(th, +1) for th in ths]
    inner = [sh(th, -1) for th in ths]
    d = "M" + "L".join(f"{fmt(x)} {fmt(y)}" for x, y in outer)
    d += "L" + "L".join(f"{fmt(x)} {fmt(y)}" for x, y in reversed(inner)) + "Z"
    o = 0.45 + 0.55 * nearness((a + b) / 2)
    lines.append(f'{indent}<path class="knot-sh" opacity="{o:.2f}" d="{d}"/>')

    # Ribbon quads. The leading edge of each quad is nudged EPS forward
    # along the tangent so opaque neighbours overlap instead of meeting at
    # an antialiased hairline.
    for k in range(nq):
        t0, t1 = ths[k], ths[k + 1]
        tx, ty = tangent(i, t1)
        x0o, y0o = edge(i, t0, +1)
        x0i, y0i = edge(i, t0, -1)
        x1o, y1o = edge(i, t1, +1)
        x1i, y1i = edge(i, t1, -1)
        x1o, y1o = x1o + tx * EPS, y1o + ty * EPS
        x1i, y1i = x1i + tx * EPS, y1i + ty * EPS
        # One decimal on the mix percentages: integer steps are close enough
        # together on the near side that the eye reads the boundaries as
        # Mach-band hairlines across the ribbon. The occlusion dip pulls
        # both brightness and glint down where this strand passes under
        # another -- shade, not paint.
        mid = (t0 + t1) / 2
        occ = occlusion(i, mid)
        dv = 100 * nearness(mid) ** D_GAMMA * (1 - OCC_DEPTH * occ)
        sv = 100 * spec(i, mid) * (1 - occ)
        style = f"--d:{dv:.1f}%" + (f";--s:{sv:.1f}%" if sv >= 0.5 else "")
        d = (f"M{fmt(x0o)} {fmt(y0o)}L{fmt(x1o)} {fmt(y1o)}"
             f"L{fmt(x1i)} {fmt(y1i)}L{fmt(x0i)} {fmt(y0i)}Z")
        lines.append(f'{indent}<path class="knot-q" style="{style}" d="{d}"/>')
    return "\n".join(lines)


back = "\n".join(emit_chunk(c, "      ") for c in chunks if c["z"] < 0)
front = "\n".join(emit_chunk(c, "      ") for c in chunks if c["z"] >= 0)

# Full-ring paths, handed to CSS as the motion path each traffic node rides.
rings = []
for i in range(3):
    x0, y0 = pt(i, 0.0)
    xh, yh = pt(i, math.pi)
    rings.append(f"M{fmt(x0)} {fmt(y0)}"
                 f"A{fmt(R)} {fmt(RY)} {fmt(PHI[i])} 0 1 {fmt(xh)} {fmt(yh)}"
                 f"A{fmt(R)} {fmt(RY)} {fmt(PHI[i])} 0 1 {fmt(x0)} {fmt(y0)}")


def nodes(kind):
    """One head and three trail dots per ring. The same six dots exist twice,
    once behind the disc and once in front; complementary opacity windows in
    the motion CSS mean each lap shows the front copies for the near half and
    the back copies for the far half -- real occlusion, not a fade."""
    lines = [f'      <g class="knot-nodes knot-nodes-{kind}">']
    radii = [2.6, 1.9, 1.4, 1.0]
    for i in range(3):
        for k, r in enumerate(radii):
            lines.append(f'        <circle class="knot-node kn-r{i} kn-t{k}" r="{r}"/>')
    lines.append("      </g>")
    return "\n".join(lines)


# The art box overhangs the clip circle: the drift below scales and slides it,
# and without the overhang a corner would swing into view at the far end of
# the travel.
ART = DISC * 1.18
box = fmt(C - ART)
side = fmt(2 * ART)

doc = f"""{{# The hero mark: three rings woven around a disc of the official art, the
   same weave the logo carries. Generated geometry -- three circles of radius
   {fmt(R)} tilted {fmt(math.degrees(TAU))} deg out of the screen plane and spun 0/60/120 deg about the
   view axis, cut at every horizon and crossing and painted back to front, so
   the over/under pattern is the one the solid would show. Each ring is a
   ribbon of filled quads whose width, depth brightness (--d) and glint (--s)
   are computed per sample; the stylesheet turns those into colour.
   Re-generate (tools/hero-knot/build.py) rather than edit by hand. #}}
<figure class="hero-art">
  <svg class="hero-knot" viewBox="0 0 240 240" role="img" aria-label="{{{{ "home.hero_art_alt" | t }}}}">
    <defs>
      <linearGradient id="knotSheen" gradientUnits="userSpaceOnUse"
                      x1="{fmt(C - DISC)}" y1="{fmt(C - DISC)}" x2="{fmt(C + DISC)}" y2="{fmt(C + DISC)}">
        <stop class="knot-s0" offset="0"/>
        <stop class="knot-s1" offset="0.42"/>
        <stop class="knot-s2" offset="1"/>
      </linearGradient>
      <clipPath id="knotDisc">
        <circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}"/>
      </clipPath>
    </defs>

    {{# Everything behind the disc, plus the far-half copies of the nodes. #}}
    <g class="knot-spin">
{back}
{nodes("back")}
    </g>

    {{# The core. Not in a spinning group: the art holds still while the
       rings turn around it. #}}
    <g class="knot-core">
      <circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}" fill="#0a0a0b"/>
      <g clip-path="url(#knotDisc)">
        <image class="knot-core-art" href="{{{{ base_url }}}}/images/wallpaper.webp"
               x="{box}" y="{box}" width="{side}" height="{side}"
               preserveAspectRatio="xMidYMid slice"/>
      </g>
      <circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}" fill="url(#knotSheen)"/>
      <circle class="knot-core-rim" cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC - 0.4)}"/>
    </g>

    {{# Everything in front of it, and the near-half node copies. #}}
    <g class="knot-spin">
{front}
{nodes("front")}
    </g>
  </svg>
</figure>
"""

OUT.write_text(doc)
nq = doc.count('class="knot-q"')
print(f"wrote {OUT} ({len(chunks)} chunks, {nq} quads)")
print()
print("Paste these into static/css/style.css, on the .kn-r* rules -- the nodes")
print("ride the same ellipses the ribbons are cut from, so they have to be")
print("regenerated together with the partial:")
print()
for i, r in enumerate(rings):
    print(f'  .kn-r{i} {{ offset-path: path("{r}"); }}')
