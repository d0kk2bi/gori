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
"""
import math
import pathlib

C = 120.0          # centre of the 240x240 viewBox
R = 113.0          # ring radius
TAU = math.radians(55.0)
PHI = [0.0, 60.0, 120.0]
DISC = 79.0        # radius of the core disc
STEPS = 4000       # sampling resolution for crossing detection

RY = R * math.cos(TAU)
ZAMP = R * math.sin(TAU)

OUT = pathlib.Path(__file__).resolve().parents[2] / "templates/partials/hero-knot.html"


def pt(i, th):
    p = math.radians(PHI[i])
    cx, sx = math.cos(p), math.sin(p)
    a, b = R * math.cos(th), RY * math.sin(th)
    return (C + a * cx - b * sx, C + a * sx + b * cx)


def z(th):
    return ZAMP * math.sin(th)


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
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


# A piece gets one width and one opacity, taken at its middle, so a long
# piece would step visibly against its neighbours. Splitting every run down
# to at most STEP keeps consecutive pieces close enough in depth that the
# taper reads continuous.
STEP = math.radians(22.0)

pieces = []
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
        n = max(1, math.ceil((b - a) / STEP))
        for s in range(n):
            t0 = a + (b - a) * s / n
            t1 = a + (b - a) * (s + 1) / n
            x1, y1 = pt(i, t0)
            x2, y2 = pt(i, t1)
            large = 1 if (t1 - t0) > math.pi else 0
            pieces.append({
                "z": z((t0 + t1) / 2),
                "d": (f"M{fmt(x1)} {fmt(y1)}"
                      f"A{fmt(R)} {fmt(RY)} {fmt(PHI[i])} {large} 1 {fmt(x2)} {fmt(y2)}"),
            })

pieces.sort(key=lambda p: p["z"])


def shade(zv):
    """Near side thicker and brighter: what gives a flat stroke the weight of
    a turning ribbon."""
    t = (zv / ZAMP + 1) / 2            # 0 far, 1 near
    return 1.7 + 3.3 * t, t ** 1.7


def emit(group, indent):
    lines = []
    for p in group:
        w, o = shade(p["z"])
        lines.append(f'{indent}<path class="knot-cut" stroke-width="{fmt(w + 2.2)}"'
                     f' d="{p["d"]}"/>')
        lines.append(f'{indent}<path class="knot-arc" stroke-width="{fmt(w)}"'
                     f' style="--d:{o * 100:.1f}%" d="{p["d"]}"/>')
    return "\n".join(lines)


back = emit([p for p in pieces if p["z"] < 0], "      ")
front = emit([p for p in pieces if p["z"] >= 0], "      ")

# Full-ring paths, handed to CSS as the motion path each traffic node rides.
rings = []
for i in range(3):
    x0, y0 = pt(i, 0.0)
    xh, yh = pt(i, math.pi)
    rings.append(f"M{fmt(x0)} {fmt(y0)}"
                 f"A{fmt(R)} {fmt(RY)} {fmt(PHI[i])} 0 1 {fmt(xh)} {fmt(yh)}"
                 f"A{fmt(R)} {fmt(RY)} {fmt(PHI[i])} 0 1 {fmt(x0)} {fmt(y0)}")

# The art box overhangs the clip circle: the drift below scales and slides it,
# and without the overhang a corner would swing into view at the far end of
# the travel.
ART = DISC * 1.18
box = fmt(C - ART)
side = fmt(2 * ART)

doc = f"""{{# The hero mark: three rings woven around a disc of the official art, the
   same weave the logo carries. Generated geometry -- three circles of radius
   {fmt(R)} tilted {fmt(math.degrees(TAU))} deg out of the screen plane and spun 0/60/120 deg about the
   view axis, each cut at its own horizon and at every crossing, then painted
   back to front. So the over/under pattern is the one the solid would show,
   not a hand-authored guess, and a rigid spin of the whole group keeps it
   true. Re-generate rather than edit these arcs by hand. #}}
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

    {{# Everything behind the disc. #}}
    <g class="knot-spin">
{back}
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

    {{# Everything in front of it, and the three request nodes riding the
       rings -- traffic circling the loop. #}}
    <g class="knot-spin">
{front}
      <circle class="knot-node knot-node-0" r="3.1"/>
      <circle class="knot-node knot-node-1" r="2.7"/>
      <circle class="knot-node knot-node-2" r="2.4"/>
    </g>
  </svg>
</figure>
"""

OUT.write_text(doc)
print(f"wrote {OUT} ({len(pieces)} pieces)")
print()
print("Paste these into static/css/style.css, inside the offset-path @supports")
print("block -- the nodes ride the same ellipses the arcs are cut from, so they")
print("have to be regenerated together with the partial:")
print()
for i, r in enumerate(rings):
    print(f'  .knot-node-{i} {{')
    print(f'    offset-path: path("{r}");')
    print("  }")
