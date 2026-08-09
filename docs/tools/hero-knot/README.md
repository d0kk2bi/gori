# hero-knot

Generates `templates/partials/hero-knot.html`, the woven three-ring mark in the
landing-page hero.

```
python3 tools/hero-knot/build.py
```

The three rings are real circles tilted out of the screen plane, so the script
can compute where each one passes in front of or behind the others and cut them
at exactly those points. The pieces are then written out back to front: the
over/under pattern is derived from the geometry rather than drawn by hand, which
is why the emitted markup should never be edited directly — change a constant at
the top of the script and re-run it.

Each ring is a ribbon, not a stroke: a strip of filled quads whose width,
depth brightness and specular glint are computed per sample. The ribbon swells
and brightens toward the viewer, thins and falls toward the page colour behind,
carries glints where a tube would catch light from the upper left, and lays a
cast shadow displaced away from that light. The shadow's displacement is the
away-from-light vector projected onto the local normal — a fixed vector would
slide each chunk's shadow onto its neighbour's ribbon and read as a dark tick
at every chunk boundary.

## What lives where

- **Geometry, depth order, width, shading terms** — this script, into the
  partial. Quads carry `--d` (depth) and `--s` (glint) only.
- **Colour and motion** — `static/css/style.css`, under "The hero mark".
  `--knot-near/--knot-far/--knot-hi/--knot-cut` are the theme palette; the
  quad fill is mixed from them at paint time.
- **The traffic nodes' motion paths** — printed by the script, pasted onto
  the `.kn-r*` rules. They are the full ellipses the ribbons are cut from,
  so they have to be updated whenever the partial is regenerated. Each node
  exists twice (front/back of the disc) with complementary opacity windows,
  which is what lets a lap really pass behind the core.

## Why the whole mark can spin

The painted depth order is only correct for the viewpoint it was computed from.
Turning the group in the picture plane is a rigid motion — it moves every piece
the same way and never changes which one is nearer — so the weave stays true.
Anything that would rotate the rings *through* the screen plane would not.

## Seam lore

Two artifacts cost time here; both fixes live in the emitted geometry:

- Adjacent opaque quads sharing an antialiased edge show a hairline at every
  boundary. Fix: each quad is stroked in its own fill colour (`stroke-width`
  0.5 in the CSS), which swallows the seam.
- Baking `--d` as integer percentages made the eye read the 1% steps between
  neighbouring quads as Mach-band lines across the ribbon; one decimal place
  is enough to dissolve them.
