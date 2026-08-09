# hero-knot

Generates `templates/partials/hero-knot.html`, the woven three-ring mark in the
landing-page hero.

```
python3 tools/hero-knot/build.py
```

The three rings are real circles tilted out of the screen plane, so the script
can compute where each one passes in front of or behind the others and cut them
at exactly those points. The arcs are then written out back to front: the
over/under pattern is derived from the geometry rather than drawn by hand, which
is why the arcs in the partial should never be edited directly — change a
constant at the top of the script and re-run it.

## What lives where

- **Geometry and depth order** — this script, into the partial.
- **Colour, thickness ramp and motion** — `static/css/style.css`, under
  "The hero mark". The partial only tags each arc with its depth (`--d`) and
  stroke width.
- **The nodes' motion paths** — printed by the script, pasted into the
  `offset-path` block in `style.css`. They are the full ellipses the arcs are
  cut from, so they have to be updated whenever the partial is regenerated.

## Why the whole mark can spin

The painted depth order is only correct for the viewpoint it was computed from.
Turning the group in the picture plane is a rigid motion — it moves every arc
the same way and never changes which one is nearer — so the weave stays true.
Anything that would rotate the rings *through* the screen plane would not.
