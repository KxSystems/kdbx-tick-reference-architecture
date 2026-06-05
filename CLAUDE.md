# CLAUDE.md

Project notes for AI assistants working in this repo.

## Repo purpose

Shared collection of architecture diagrams and technical documents. The committed artifact for every diagram is a `.drawio.png` — a PNG with the draw.io XML embedded in a metadata chunk, so a single file is both the rendered preview and the editable source.

## Layout

- [arch/](arch/) — architecture diagrams (`.drawio.png` files), one per architecture variant
- [tick/](tick/) — base tick stack (TP / RDB / HDB / FH / RTE / GW); simplest reference pattern
- [tick-x/](tick-x/) — adds intraday writedown: RDB writes int-partitions, IDB serves them, CHAINED_RDB serves queries
- [scaled-tick-x/](scaled-tick-x/) — adds chained-RDB failover (RDB_CHAIN_N / HDB_EXTRA_N replicas via `-m N`)
- [samples/](samples/) — shared schemas, analytics, sample data, sample env
- [README.md](README.md) — top-level overview and per-variant entry points

Each architecture variant has its own `README.md` that embeds the matching `arch/<variant>.drawio.png`. When adding or modifying a diagram, also update the corresponding variant README to reference the new image.

## Diagram style

All diagrams in this repo use a consistent hand-drawn "sketch" style. Match it when authoring new diagrams or editing existing ones.

### Sketch rendering

Apply these attributes to every shape and edge:

```
sketch=1;curveFitting=1;jiggle=2;hachureGap=4
```

Font: `fontFamily=Verdana`. Font sizes 13 for body shapes, 15 for emphasised labels, 12 for edge labels.

### Default shape: rounded rectangle

Default to **rounded rectangles** for components, services, and processes — not ellipses or circles. Use:

```
shape=mxgraph.basic.rect;rounded=1;arcSize=10
```

Reserve other shapes for specific roles:
- `cylinder3` — data stores (logs, feeds, durable state)
- `cloud` — external systems / commercial feeds
- Stacked rounded rectangles — clusters / multi-instance services (see below)

### Color palette (semantic)

| Role | Fill | Stroke |
| --- | --- | --- |
| Data plane / q processes | `#E2EFDA` | `#70AD47` |
| Control plane / processing | `#DAEAF7` | `#5B9BD5` |
| External / sample components | `#FFF2CC` | `#D6B656` |
| Infrastructure / neutral | `#F5F5F5` | `#BDBDBD` |
| Temporal / state | `#e1d5e7` | `#9673a6` |
| Alternative / legacy | `#dae8fc` | `#6c8ebf` |

### Edges

```
edgeStyle=orthogonalEdgeStyle;rounded=1;sketch=1;curveFitting=1;jiggle=2;
strokeColor=#5B9BD5;strokeWidth=2;endArrow=block;endFill=1
```

- `strokeWidth=2` for primary flow, `1` for secondary/optional
- `dashed=1` for recovery / inference / fallback paths
- Edge labels: `fontSize=12;fontFamily=Verdana;labelBackgroundColor=#FFFFFF`

### Stack-of-N (clusters)

Sketch-mode hachure fills are semi-transparent, so naively stacking three filled rectangles produces ugly hachure bleed-through. The working pattern is:

1. **Back boxes** — outline only (`fillColor=none`), offset behind the front (e.g. +16/-14 for back, +8/-7 for mid).
2. **Mask** — a solid white rectangle (`fillColor=#FFFFFF;strokeColor=none;sketch=0`) at the front box's exact position, layered above the back outlines.
3. **Front box** — full sketch rectangle with fill + label, drawn on top of the mask.

Render order is mxCell document order; later cells render on top. See the RDB / HDB stacks in [diagrams/tickerplant-architecture.drawio.png](diagrams/tickerplant-architecture.drawio.png) for a worked example.

### Composition

Keep individual diagrams **simple and focused** on one concern (e.g. a single component's internal flow, or a single integration path). Compose larger architectures by referencing or visually nesting these simpler diagrams rather than building one mega-diagram. A reader should be able to grasp any single diagram in under 30 seconds.

## Authoring workflow

The repo standardises on **`.drawio.png` as the single source of truth** — a PNG that embeds the full draw.io XML in a metadata chunk. It previews inline in the README and is fully editable in draw.io desktop, the VS Code extension, or by re-uploading to draw.io web. We do **not** commit standalone `.drawio` source files; XML diffs aren't useful for review anyway, so the binary PNG is the only artifact we keep.

Match the existing sketch attributes exactly when editing — drift in `jiggle` / `hachureGap` / `curveFitting` is visible side-by-side.

### New diagram (hand-authored XML)

1. Write the `.drawio` XML to a temp path (e.g. `/tmp/foo.drawio`).
2. Export it to the repo's PNG location:
   ```sh
   /Applications/draw.io.app/Contents/MacOS/draw.io -x -f png -e \
     -o diagrams/foo.drawio.png /tmp/foo.drawio
   ```
3. Delete the temp `.drawio`. Add a README entry pointing at the new PNG.

### Editing an existing diagram

1. Extract the embedded XML from the PNG to a temp path:
   ```sh
   /Applications/draw.io.app/Contents/MacOS/draw.io -x -f xml \
     -o /tmp/foo.drawio diagrams/foo.drawio.png
   ```
2. Edit the temp XML.
3. Re-export over the original PNG using the export command above. Delete the temp file.

### CLI flags

`-x` export · `-f png|xml` format · `-e` embed source (PNG only) · `-o` output path. The transient `SharedImageManager` GPU errors on stderr are harmless Electron noise; success is the final `input -> output` line.
