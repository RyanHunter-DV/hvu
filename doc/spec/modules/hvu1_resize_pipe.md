**File Structure**: `$PROJECT_HOME/src/rtl/lpu`

# hvu1_resize_pipe

Destination-driven scaler for the HVU1 layer processing unit (LPU). The pipe walks the **destination** raster, inverse-maps each output sample into the logical source plane, fetches the tap(s) required by the selected interpolator, and emits a line-by-line pixel stream toward the composition unit.

RTL: `$PROJECT_HOME/src/rtl/lpu`

Inverse mapping:

	src_x = dst_x * (src_width  / dst_width)
	src_y = dst_y * (src_height / dst_height)

Ratios are **Q16.16** fixed point. There is no floating-point unit and no per-pixel divide.

When `en = 1`, the pipe computes fractional source coordinates, issues pixel fetches, and interpolates. When `en = 0`, it still walks the destination (1:1 with the logical source) and issues integer positions with no interpolation — a raster walk through the same fetch path.

Fetch positions are in the **logical** (post-rotate, post-flip) source plane. After the fetch mux, `pixel_req_*` goes through `hvu1_rot_flip_pipe` to the original buffer coordinate, then the position decoder produces a system-memory offset. Returned colour comes from CSC on the response handshake. Do not fetch with a pre-rotate coordinate.

---

## Strategies

- **Inverse (destination-driven) mapping.** Iterate `dst_x ∈ [0, dst_width)`, `dst_y ∈ [0, dst_height)` in raster order (`x` innermost). Forward mapping from source would leave holes and duplicates; inverse mapping produces every destination pixel exactly once.
- **One divide per frame, multiply per pixel.** `ratio_w` / `ratio_h` are computed when a frame starts (dimensions latched on `start`). The per-pixel path is `src_*_c = dst_* * ratio_*` (integer × Q16.16). A restoring/non-restoring divider is not placed on the pixel datapath. Bypass (`en = 0`) does not use the divider.
- **Q16.16 throughout the coordinate path.** Integer in `[31:16]`, fraction in `[15:0]`. Fits a 16-bit dimension (max 8192) with a 16-bit sub-pixel weight. Nearest-neighbour rounding and bilinear weights both consume this format.
- **Both interpolators instantiated; one fetch port.** `hvu1_resize_pipe` contains `hvu1_nearest_interp` and `hvu1_bilinear_interp`. A single external pixel-fetch bundle and a single CU pixel stream are muxed from the active path according to `interpolation` (`en = 0` uses nearest). The idle interpolator is held with `in_valid = 0` and must not drive `pixel_req_valid`.
- **Bypass reuses the walk, not a sidecar DMA.** `en = 0` forces integer `src = dst`, nearest-style single fetch, and pass-through of the returned pixel. Control, rot/flip, address decode, and CSC/CU handshakes stay in circuit.
- **Rot/flip sits on the fetch request, not on the destination walk.** Resize always thinks in logical source coordinates (`src_width` × `src_height` after rotate/flip). Interpolation therefore sees a geometrically consistent neighbourhood even when the packed buffer is stored rotated.
- **Valid/ready on every streaming boundary.** A beat transfers when `valid && ready`. Request, CSC response, and CU output stall independently. The walk does not start the next destination sample until the current output pixel is committed.
- **One destination pixel in flight.** Nearest: 1 tap. Bilinear: 4 taps. No prefetch of the next Q16.16 sample. Responses return in request order (no tags).
- **Clamp at the source edge.** Integer tap coordinates are saturated to `[0, src_width-1]` × `[0, src_height-1]`. Without this, `dst_x = dst_width-1` can land on `src_width` with a naïve ratio. `hvu1_nearest_interp` does not clamp the rounded integer; the parent clamps before fetch. Bilinear clamps taps inside the interpolator.
- **12-bit internal components.** Fetch/CU payload is `{R, G, B, A}`, 12 bits each (CSC / internal `hvu1_px48_t`). Alpha follows the same latency as colour. No 8-bit rounding inside the scaler.

---

## Placement

```
  [hvu1_resize_pipe local]
    dst walk → Q16 map → steer en/in_valid → clamp (nearest) → mux fetch/CSC/CU
         │                                                      │
         │   ┬─ hvu1_nearest_interp  (round + CSC→CU) ─┬────────┘
         └───┤                                         ├─ mux ─→ hvu1_rot_flip_pipe
             └─ hvu1_bilinear_interp (2×2 + blend) ────┘         ↓
                                                                 address decoder
                                                                 ↓
                           mux (cu_*) ←────────────────── CSC / memory
                                      ↓
                                     CU
```

CU output is a packed raster, left-to-right, top-to-bottom, `dst_width` × `dst_height`. Local ops: [Local resizing operations](#local-resizing-operations-hvu1_resize_pipe).

---

## Operating modes

| `en` | `interpolation` | Behaviour |
|------|-----------------|-----------|
| `0` | ignored | 1:1 walk. `dst_width` / `dst_height` equal the logical source size. One integer fetch per output pixel; payload passed through. |
| `1` | `2'b00` nearest | Inverse map, round Q16.16 to integer, one fetch per destination pixel. |
| `1` | `2'b01` bilinear | Inverse map, four fetches on the floor/ceil 2×2, blend with `{frac_x, frac_y}`. |
| `1` | `2'b10`, `2'b11` | Reserved. Treat as nearest until a later interpolator is attached. |

`src_width` / `src_height` are the logical source size **after** rotate/flip (90°/270° already swap W/H relative to the packed buffer). `dst_width` / `dst_height` are the size presented to the CU.

When `en = 1`, `dst_width == 0` or `dst_height == 0` is illegal: do not start the frame.

---

## Local resizing operations (`hvu1_resize_pipe`)

These operations live in `hvu1_resize_pipe` itself. Interpolators only round/blend and move CSC ↔ CU pixels. The pipe owns the destination raster, the Q16.16 inverse map, interpolator `en` / `in_valid` steering, integer-position clamp on the nearest fetch path, the fetch/CSC/CU mux, and CU line/frame flags.

```
  [local] start latch + ratio
       ↓
  [local] dst_x/dst_y walk  →  [local] src_x_c/src_y_c (Q16.16)
       ↓
  [local] steer in_valid / en  →  nearest or bilinear
       ↓
  [local] mux out_valid / pos_*_int / csc_* / cu_*
       ↓
  [local] dst_eol, dst_last, frame_done
```

### 1. Frame latch and ratio (IDLE → first MAP)

On `start` in IDLE, with legal dimensions (`dst_width` and `dst_height` non-zero):

- Latch `src_width`, `src_height`, `dst_width`, `dst_height`, `en`, `interpolation`.
- `dst_x = 0`, `dst_y = 0`.
- If pipe `en = 1`:

		src_w_c[31:0] = {16'd0, src_width}
		src_h_c[31:0] = {16'd0, src_height}
		ratio_w[31:0] = (src_w_c << 16) / dst_width
		ratio_h[31:0] = (src_h_c << 16) / dst_height

	Integer unsigned divide, once per frame. Not on the pixel datapath.

- If pipe `en = 0`: do not divide. Ratios unused.

Latched values are static until `frame_done` returns to IDLE.

	sel_bilinear = en & (interpolation == 2'b01)

Reserved `interpolation` (`2'b10`, `2'b11`) uses nearest (`sel_bilinear = 0`).

### 2. Destination raster walk

	dst_x ∈ [0, dst_width),  dst_y ∈ [0, dst_height)     // x innermost

FSM:

| State | Local action |
|-------|----------------|
| `IDLE` | Wait `start`. Latch and (if `en`) compute ratios. |
| `MAP` | Form `src_x_c/src_y_c` for current `(dst_x, dst_y)`. Present `in_valid` to the selected interpolator. Stay until that interpolator accepts (`in_ready`). |
| `WAIT` | Hold `(dst_x, dst_y)` until the muxed CU pixel is accepted (`cu_pvalid && cu_pready`). Then advance the raster or finish the frame. |

Advance after CU accept:

- If not last pixel: `dst_x += 1`; on row end (`dst_x == dst_width-1`), `dst_x = 0`, `dst_y += 1`. Back to `MAP`.
- If last pixel (`dst_x == dst_width-1` and `dst_y == dst_height-1`): pulse `frame_done` one cycle, return to `IDLE`.

Do not offer the next Q16.16 sample until the current CU pixel is committed. One destination pixel in flight.

### 3. Inverse map to Q16.16 (combinational on `dst_x/dst_y`)

Dimensions and indices 16-bit unsigned. Working coordinates 32-bit Q16.16 (`[31:16]` integer, `[15:0]` fraction).

Pipe `en = 1`:

	src_x_c[31:0] = dst_x * ratio_w
	src_y_c[31:0] = dst_y * ratio_h

16-bit × 32-bit; keep a 48-bit intermediate; Q16.16 is the low 32 bits (integer field fits 16 bits after clamp). Bound in this spec: at most `8191 * (8192 << 16) / 1`.

Pipe `en = 0` (1:1 walk, `dst_width == src_width`, `dst_height == src_height`):

	src_x_c = {dst_x, 16'd0}
	src_y_c = {dst_y, 16'd0}

Fraction is 0, so nearest round is an identity on the integer field.

Feed `src_x_c` / `src_y_c` to the selected interpolator as `pos_x` / `pos_y`.

### 4. Interpolator steering

Both interpolators are instantiated. Exactly one is active.

| Pipe `en` | `interpolation` | Local steering |
|-----------|-----------------|----------------|
| `0` | ignored | nearest `en = 1`, bilinear `en = 0`; `in_valid` only to nearest |
| `1` | `2'b00` | same as above |
| `1` | `2'b01` | bilinear `en = 1`, nearest `en = 0`; `in_valid` only to bilinear |
| `1` | other | same as nearest |

Idle interpolator: `en = 0`, `in_valid = 0`, `out_ready = 0`, `csc_pvalid = 0`, `cu_pready = 0` so it cannot raise fetch `out_valid` or `cu_pvalid`.

### 5. Nearest integer clamp (local, before fetch mux)

`hvu1_nearest_interp` does not clamp to the source rectangle. The pipe saturates its `pos_*_int` before the external fetch port:

	fetch_x = min(pos_x_int, src_width  - 1)
	fetch_y = min(pos_y_int, src_height - 1)

Bilinear already clamps taps internally; the pipe does not clamp bilinear `pos_*_int` again.

### 6. Fetch / CSC / CU mux (local)

One external fetch bundle, one CSC response, one CU stream. Select with `sel_bilinear`.

| Pipe port | `sel_bilinear = 0` | `sel_bilinear = 1` |
|-----------|--------------------|--------------------|
| fetch `pos_x`, `pos_y` | clamped nearest `pos_*_int` | bilinear `pos_*_int` |
| `pixel_req_valid` | nearest `out_valid` | bilinear `out_valid` |
| `pixel_req_ready` | → nearest `out_ready` | → bilinear `out_ready` |
| `csc_pvalid`, `csc_r/g/b/a` | → nearest | → bilinear |
| `csc_pready` | nearest | bilinear |
| `cu_r/g/b/a`, `cu_pvalid` | nearest | bilinear |
| `cu_pready` | → nearest | → bilinear |

Fetch coordinates are logical source. After this mux they go to `hvu1_rot_flip_pipe`, then the address decoder. Do not fetch with a pre-rotate coordinate.

### 7. CU line/frame flags (local)

Derived from the walk counters while the current pixel is on the CU bus (`cu_pvalid`):

	dst_eol  = cu_pvalid && (dst_x == dst_width  - 1)
	dst_last = cu_pvalid && (dst_x == dst_width  - 1) && (dst_y == dst_height - 1)
	frame_done = (WAIT) && cu_pvalid && cu_pready && dst_last     // one-cycle pulse

---

## Interpolation and fetch mux

Steering, clamp, and mux tables are in [Local resizing operations](#local-resizing-operations-hvu1_resize_pipe) §§4–6. Both interpolators are instantiated; the walk presents one Q16.16 sample to exactly one of them.

`hvu1_nearest_interp` rounds Q16.16 to uint16 with valid/ready, and — when its `en` is set — takes the CSC pixel for that sent position and drives the CU bundle. When `en` is low, its FSM stays idle.

`hvu1_bilinear_interp` uses the same CSC and CU bundles as nearest. It issues four integer tap positions, receives four CSC pixels, blends them, and sends one result pixel to CU. When its `en` is low, the FSM stays idle.

The parent muxes the two interpolators’ fetch and CU/CSC bundles (`sel_bilinear`). Inactive side: `pixel_req_ready = 0`, `csc_pvalid = 0`, `cu_pready = 0`, `in_valid = 0`.

### Nearest path (`sel_bilinear = 0`)

1. Walk Q16.16 → `hvu1_nearest_interp` with that module’s `en` set.
2. Parent clamps `pos_*_int` to `[0, src_width-1]` × `[0, src_height-1]` and uses `out_valid` / `out_ready` as `pixel_req_valid` / `pixel_req_ready`.
3. CSC returns the pixel for the sent position on `csc_pvalid` / `csc_r/g/b/a`.
4. Nearest, while enabled, sends that pixel on `cu_r/g/b/a` with `cu_pvalid` / `cu_pready`. If nearest `en` is low, it keeps the FSM idle and does not drive the CU bundle.

### Bilinear path (`sel_bilinear = 1`)

1. Walk Q16.16 → `hvu1_bilinear_interp` with that module’s `en` set.
2. Bilinear issues four integer tap positions on `pos_x_int` / `pos_y_int` with `out_valid` / `out_ready` (same handshake as nearest).
3. Each tap comes back from CSC on `csc_pvalid` / `csc_r/g/b/a`.
4. After four CSC pixels, bilinear computes one result pixel and sends it on `cu_r/g/b/a` with `cu_pvalid` / `cu_pready`. If bilinear `en` is low, FSM idle, no `cu_pvalid`.

---

## Pixel fetch bundle

Resize is master of the logical-source fetch. Positions may be presented every cycle. Downstream rot/flip uses `in_valid` / `in_ready` and `out_valid` / `out_ready`.

| Signal | Dir (from resize) | Width | Description |
|--------|-------------------|-------|-------------|
| `pos_x` | out | 16 | Logical source X; useful range 0..8191 |
| `pos_y` | out | 16 | Logical source Y; useful range 0..8191 |
| `pixel_req_valid` | out | 1 | Request beat valid |
| `pixel_req_ready` | in | 1 | Downstream (rot/flip) can accept |

`pos_x` / `pos_y` are qualified by `pixel_req_valid`. Transfer when `pixel_req_valid && pixel_req_ready`.

CSC returns the fetched pixel on the response handshake (same colour as `pixel_r/g/b/a` / `csc_*` below). Transfer when `csc_pvalid && csc_pready`.

---

## Destination walk and CU stream

Walk, inverse map, and `dst_eol` / `dst_last` / `frame_done` are local operations ([§§1–3, 7](#local-resizing-operations-hvu1_resize_pipe)). FETCH / EMIT for taps live in the active interpolator. The walk only offers the next Q16.16 sample when the previous CU pixel has been accepted.

CU-facing output (line by line). `cu_*` and `dst_*` are the same bundle:

| Signal | Also named | Dir | Width | Description |
|--------|------------|-----|-------|-------------|
| `cu_pvalid` | `dst_valid` | out | 1 | Destination pixel valid |
| `cu_pready` | `dst_ready` | in | 1 | CU can accept |
| `cu_r` | `dst_r` | out | 12 | Output R |
| `cu_g` | `dst_g` | out | 12 | Output G |
| `cu_b` | `dst_b` | out | 12 | Output B |
| `cu_a` | `dst_a` | out | 12 | Output A |
| `dst_last` | | out | 1 | Last pixel of the frame |
| `dst_eol` | | out | 1 | Last pixel of the current line (`dst_x == dst_width-1`) |

Throughput: nearest is one destination pixel per fetch round-trip; bilinear is four fetches per destination pixel. When request, CSC response, and CU are all ready every cycle, nearest is one output pixel per cycle after fill; bilinear is one per four cycles.

---

## Constraints

| Item | Rule |
|------|------|
| Max dimension | 8192. Position ports are 16-bit; useful range 0..8191. |
| `en = 1` | `dst_width` and `dst_height` must be non-zero. |
| `en = 0` | `dst_width == src_width` and `dst_height == src_height` (logical source). |
| Divider | Integer unsigned `(src_dim << 16) / dst_dim`. Result is Q16.16. |
| Edge | All integer tap coordinates clamped to the source rectangle. |
| Reset | Async active-low `rstn`. Clear valids; walk returns to IDLE. |
| In flight | At most one destination pixel’s taps (1 or 4). No prefetch. |

---

## Ports (`hvu1_resize_pipe`)

Configuration is static for a frame (sampled on `start`). Streaming ports use valid/ready.

### Clock, reset, control

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rstn` | in | 1 | Async active-low reset |
| `start` | in | 1 | Pulse in IDLE to latch configuration and begin a frame |
| `en` | in | 1 | `1` = scale; `0` = 1:1 walk / pass-through |
| `interpolation` | in | 2 | `0` nearest, `1` bilinear, others reserved |
| `src_width` | in | 16 | Logical source width (after rot/flip) |
| `src_height` | in | 16 | Logical source height (after rot/flip) |
| `dst_width` | in | 16 | Destination width (to CU) |
| `dst_height` | in | 16 | Destination height (to CU) |
| `frame_done` | out | 1 | One-cycle pulse after the last destination pixel is accepted |

### Pixel fetch (to rot/flip → address decoder → memory)

See [Pixel fetch bundle](#pixel-fetch-bundle).

### with cu

Pixel stream sent to the CU component. Valid/ready handshake.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `cu_r` | out | 12 | Output pixel stream, R, sending to CU |
| `cu_g` | out | 12 | Output pixel stream, G, to CU |
| `cu_b` | out | 12 | Output pixel stream, B, to CU |
| `cu_a` | out | 12 | Output pixel stream, A, to CU |
| `cu_pvalid` | out | 1 | Pixel valid to CU |
| `cu_pready` | in | 1 | CU ready |

Also `dst_last` / `dst_eol` as in [Destination walk and CU stream](#destination-walk-and-cu-stream).

### with csc

Pixel response from CSC for the position that was sent on the fetch bundle.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `csc_pvalid` | in | 1 | Pixel valid from CSC |
| `csc_pready` | out | 1 | Resize ready for CSC pixel |
| `csc_r` | in | 12 | R from CSC |
| `csc_g` | in | 12 | G from CSC |
| `csc_b` | in | 12 | B from CSC |
| `csc_a` | in | 12 | A from CSC |

---

# hvu1_nearest_interp

Streaming rounder plus CSC→CU pass-through.

Receives Q16.16 `pos_x` / `pos_y` and emits unsigned 16-bit integer `pos_x_int` / `pos_y_int`. Input and output each use valid/ready.

`en` enables nearest interpolation. CSC returns the pixel for the sent position on `csc_pvalid` / `csc_pready` with `csc_r/g/b/a`. If this module is enabled, that pixel is sent directly on the `cu_r/g/b/a` + `cu_pvalid` / `cu_pready` bundle. If `en` is low, keep the FSM idle and do not drive CU.

Parent muxes this CU/CSC bundle with bilinear according to `interpolation`.

---

## Strategies

- **`en` gates the block.** `en` enables nearest interpolation. When `en` is low, the FSM stays idle (no CU valid, no CSC ready).
- **CSC pixel follows the sent position.** After the rounded integer is used as the fetch coordinate, `csc_r/g/b/a` is the pixel at that position. Handshake: `csc_pvalid` / `csc_pready`.
- **Enabled → pass through to CU.** If enabled, forward the CSC pixel directly to `cu_r/g/b/a` with `cu_pvalid` / `cu_pready`. No blend.
- **Valid/ready on every streaming boundary.** Position in, integer out (fetch), CSC in, CU out. A beat transfers when `valid && ready`. One destination pixel in flight: do not accept the next Q16.16 sample until `cu_pready` has taken the current CU pixel.
- **Normal round (round-half-up / 四舍五入).** `out = integer + frac[15]`, i.e. `floor(pos + 0.5)`. Combinational on the accepted input; the integer is registered for the output beat.
- **Two independent axes.** Same incrementer on X and Y; no coupling.
- **No source-rectangle clamp in this block.** Saturate only to uint16 so `16'hFFFF + 0.5` does not wrap to 0. Parent clamps to `[0, src_width-1]` × `[0, src_height-1]` before fetch.
- **Bypass is free.** Fraction `16'h0000` rounds to the integer field, so pipe `en = 0` can feed `{dst_x, 16'd0}` through this block (with this module’s `en` set when the nearest path is selected).

---

## Algorithm

Each input is unsigned Q16.16:

	pos_x[31:16]  integer     pos_x[15:0]  fraction
	pos_y[31:16]  integer     pos_y[15:0]  fraction

	rnd_x[16:0] = {1'b0, pos_x[31:16]} + pos_x[15]
	rnd_y[16:0] = {1'b0, pos_y[31:16]} + pos_y[15]

	pos_x_int[15:0] = rnd_x[16] ? 16'hFFFF : rnd_x[15:0]
	pos_y_int[15:0] = rnd_y[16] ? 16'hFFFF : rnd_y[15:0]

The 17-bit add catches `integer == 16'hFFFF` with `frac[15] == 1`. Output saturates to `16'hFFFF`.

| Input Q16.16 | Meaning | `pos_*_int` |
|--------------|---------|-------------|
| `32'h0000_0000` | 0.0 | 0 |
| `32'h0000_7FFF` | 0.5 − 2⁻¹⁶ | 0 |
| `32'h0000_8000` | 0.5 | 1 |
| `32'h0000_FFFF` | 1 − 2⁻¹⁶ | 1 |
| `32'h0001_0000` | 1.0 | 1 |
| `32'h077E_8000` | 1918.5 | 1919 |
| `32'hFFFF_8000` | 65535.5 | 65535 (uint16 saturate) |

---

## Handshake and FSM

When `en` is low, stay in `IDLE` (`in_ready = 0`, `out_valid = 0`, `csc_pready = 0`, `cu_pvalid = 0`).

When `en` is high:

	in_ready   = (state == IDLE)
	out_valid  = (state == REQ)
	csc_pready = (state == CSC)
	cu_pvalid  = (state == EMIT)

| State | Action |
|-------|--------|
| `IDLE` | Accept `in_valid`. Latch rounded `pos_*_int`. Go `REQ`. |
| `REQ` | Present `pos_*_int` with `out_valid`. On `out_ready`, go `CSC`. |
| `CSC` | `csc_pready` high. On `csc_pvalid`, latch `csc_r/g/b/a` onto `cu_*`. Go `EMIT`. |
| `EMIT` | `cu_pvalid = 1`. On `cu_pready`, go `IDLE`. |

Round is combinational on the accepted input; the integer is registered on the `IDLE` → `REQ` beat and held until the next accept. Parent one-pixel-in-flight means the next Q16.16 sample is not offered until this CU pixel is taken.

---

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rstn` | in | 1 | Async active-low reset |
| `en` | in | 1 | Enable nearest interpolation. When low, keep the FSM idle |
| `pos_x` | in | 32 | Q16.16 X (`[31:16]` integer, `[15:0]` fraction) |
| `pos_y` | in | 32 | Q16.16 Y |
| `in_valid` | in | 1 | Input position valid |
| `in_ready` | out | 1 | This block can accept this cycle |
| `pos_x_int` | out | 16 | Rounded unsigned integer X |
| `pos_y_int` | out | 16 | Rounded unsigned integer Y |
| `out_valid` | out | 1 | Integer position valid (sent position for fetch) |
| `out_ready` | in | 1 | Downstream can accept this cycle |

### with csc

Input pixel for the sent position.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `csc_pvalid` | in | 1 | Pixel valid from CSC |
| `csc_pready` | out | 1 | This block ready for CSC pixel |
| `csc_r` | in | 12 | R, pixel at the sent position |
| `csc_g` | in | 12 | G |
| `csc_b` | in | 12 | B |
| `csc_a` | in | 12 | A |

### with cu

If `en` is set, CSC pixel is sent directly on this bundle. If `en` is low, FSM idle, do not raise `cu_pvalid`.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `cu_r` | out | 12 | Output pixel stream, R, sending to CU |
| `cu_g` | out | 12 | G, to CU |
| `cu_b` | out | 12 | B, to CU |
| `cu_a` | out | 12 | A, to CU |
| `cu_pvalid` | out | 1 | Pixel valid to CU |
| `cu_pready` | in | 1 | CU ready |

---

# hvu1_bilinear_interp

Same CSC and CU port shape as `hvu1_nearest_interp`. Receives Q16.16 `pos_x` / `pos_y`, issues four integer tap positions, takes four pixels from CSC, computes one bilinear result, and sends that pixel to CU.

`en` enables bilinear interpolation. If `en` is low, keep the FSM idle and do not drive CU.

Parent muxes this CU/CSC bundle and the integer-position handshake with nearest according to `interpolation`.

---

## Strategies

- **`en` gates the block.** When `en` is low, the FSM stays idle (no CU valid, no CSC ready, no `out_valid`).
- **CSC in, CU out — same bundles as nearest.** Each fetched tap arrives on `csc_pvalid` / `csc_pready` with `csc_r/g/b/a`. After four taps are blended, one result pixel is sent on `cu_r/g/b/a` with `cu_pvalid` / `cu_pready`.
- **Position handshake matches nearest.** Q16.16 in on `pos_x` / `pos_y` with `in_valid` / `in_ready`. Integer tap out on `pos_x_int` / `pos_y_int` with `out_valid` / `out_ready` (four beats per destination pixel).
- **Separable lerp, not a 4-term polynomial in one step.** Horizontal blend of the top pair and of the bottom pair, then vertical blend of those two results. Three lerps, identical hardware, four components in parallel.
- **Shared lerp datapath, three beats.** One `12 × 17` lerp (two unsigned multipliers, add, round-shift, 12-bit saturate) reused as `H0`, then `H1`, then `V`. Blend latency is three cycles after the fourth tap is registered; fetch time dominates.
- **Floor / floor+1 taps; fraction weights the +1 tap.** Integer field is `x0/y0` (floor). `x1 = x0 + 1`, `y1 = y0 + 1`, then clamp. `fx/fy = pos_*[15:0]` as Q0.16. The sample point itself is not rounded (unlike nearest).
- **Always four requests, even on the edge.** If clamp makes `x0 == x1` (or `y0 == y1`), still issue four beats with duplicate coordinates.
- **Fixed issue order.** `(x0,y0), (x1,y0), (x0,y1), (x1,y1)`. In-order CSC responses; tap index = response count. No tags.
- **At most four outstanding fetches, one destination pixel.** Issue may overlap collect. Do not start the next Q16.16 sample until `cu_pready` has taken the current CU pixel.
- **Round-half-up back to 12 bits at each lerp.** Add `16'h8000` before `>> 16`, then saturate to `12'hFFF`. Same rule for A as for R/G/B.
- **Q0.16 weights never reach 1.0.** `fx` max is `16'hFFFF` = `1 - 2^-16`. Error after 12-bit rounding is ≤ 1 LSB.

---

## Tap generation

Input `pos_x` / `pos_y` are unsigned Q16.16 (same packing as nearest).

	x0 = clamp(pos_x[31:16],     0, src_width  - 1)
	y0 = clamp(pos_y[31:16],     0, src_height - 1)
	x1 = clamp(pos_x[31:16] + 1, 0, src_width  - 1)
	y1 = clamp(pos_y[31:16] + 1, 0, src_height - 1)
	fx = pos_x[15:0]     // Q0.16, weight of x1
	fy = pos_y[15:0]     // Q0.16, weight of y1

	wx1[16:0] = {1'b0, fx}
	wx0[16:0] = 17'h10000 - {1'b0, fx}     // 1 - fx
	wy1[16:0] = {1'b0, fy}
	wy0[16:0] = 17'h10000 - {1'b0, fy}

`src_width == 0` / `src_height == 0` is illegal (parent does not start the frame).

Issue sequence (`tap_idx`): `pos_x_int` / `pos_y_int` follow this order while `out_valid` is high.

| `tap_idx` | Position | Stored CSC pixel |
|-----------|----------|------------------|
| 0 | `(x0, y0)` | `P00` |
| 1 | `(x1, y0)` | `P10` |
| 2 | `(x0, y1)` | `P01` |
| 3 | `(x1, y1)` | `P11` |

---

## Lerp datapath

Per component `c` (R, G, B, A independently, 12-bit unsigned), from CSC taps:

	function [11:0] lerp12;
	    input [11:0] p0, p1;
	    input [16:0] w0, w1;              // w0 + w1 = 17'h10000
	    reg   [28:0] acc;
	    begin
	        acc    = p0 * w0 + p1 * w1;   // 12×17 + 12×17 → 29-bit
	        acc    = acc + 29'd32768;     // round-half-up at bit 15
	        lerp12 = (acc[28:16] > 12'hFFF) ? 12'hFFF : acc[27:16];
	    end
	endfunction

	h0.c = lerp12(P00.c, P10.c, wx0, wx1)     // top row,     beat 0
	h1.c = lerp12(P01.c, P11.c, wx0, wx1)     // bottom row,  beat 1
	out.c = lerp12(h0.c,  h1.c,  wy0, wy1)    // vertical,    beat 2 → cu_r/g/b/a

`p * w` max is `4095 * 65536 = 268369920` (28 bits). Two products sum to at most `4095 * 65536` because `w0 + w1 = 2^16`. `acc[27:16]` is the 12-bit result; the `> 12'hFFF` saturating mux is defensive.

Four-component parallel: four `lerp12` instances share the same weights, one beat. Three beats total after `P11` is captured.

---

## Handshake and FSM

When `en` is low, stay in `IDLE` (`in_ready = 0`, `out_valid = 0`, `csc_pready = 0`, `cu_pvalid = 0`).

When `en` is high:

	in_ready = (state == IDLE)

| State | Action |
|-------|--------|
| `IDLE` | Accept `in_valid`. Latch taps and weights. `tap_wr = 0`, `tap_rd = 0`. Go `FETCH`. |
| `FETCH` | If `tap_wr != 4` and `out_ready`, present tap `tap_wr` on `pos_x_int` / `pos_y_int` with `out_valid` and increment `tap_wr`. If `tap_rd != 4` and `csc_pvalid`, store `csc_r/g/b/a` into `P**` selected by `tap_rd` and increment `tap_rd`. `csc_pready` is high while `tap_rd != 4`. When `tap_rd == 4`, go `BLEND0`. |
| `BLEND0` | `h0 = lerp(P00, P10, wx0, wx1)`. Go `BLEND1`. |
| `BLEND1` | `h1 = lerp(P01, P11, wx0, wx1)`. Go `BLEND2`. |
| `BLEND2` | `cu_* = lerp(h0, h1, wy0, wy1)`. Go `EMIT`. |
| `EMIT` | `cu_pvalid = 1`. On `cu_pready`, go `IDLE`. |

Issue and collect overlap: `FETCH` may raise `out_valid` while `csc_pready` is also high. `pos_*_int` mux on `tap_wr` (the tap being issued).

Do not combinationally depend `out_ready` on `csc_pvalid`. `out_valid` is `state == FETCH && tap_wr != 4`. Downstream backpressure stalls only the issue pointer.

---

## Ports

Same grouping as nearest: position path, **with csc**, **with cu**.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rstn` | in | 1 | Async active-low reset |
| `en` | in | 1 | Enable bilinear interpolation. When low, keep the FSM idle |
| `src_width` | in | 16 | Logical source width; clamp ceiling `src_width-1` |
| `src_height` | in | 16 | Logical source height; clamp ceiling `src_height-1` |
| `pos_x` | in | 32 | Q16.16 X (`[31:16]` integer, `[15:0]` fraction) |
| `pos_y` | in | 32 | Q16.16 Y |
| `in_valid` | in | 1 | Input position valid |
| `in_ready` | out | 1 | This block can accept this cycle (`IDLE` and `en`) |
| `pos_x_int` | out | 16 | Integer tap X (current issue) |
| `pos_y_int` | out | 16 | Integer tap Y (current issue) |
| `out_valid` | out | 1 | Integer tap valid (sent position for fetch) |
| `out_ready` | in | 1 | Downstream can accept this cycle |

### with csc

Received pixels from CSC, one per issued tap, in issue order.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `csc_pvalid` | in | 1 | Pixel valid from CSC |
| `csc_pready` | out | 1 | This block ready for CSC pixel |
| `csc_r` | in | 12 | R, pixel at the sent tap position |
| `csc_g` | in | 12 | G |
| `csc_b` | in | 12 | B |
| `csc_a` | in | 12 | A |

### with cu

If `en` is set, the blended result pixel is sent on this bundle. If `en` is low, FSM idle, do not raise `cu_pvalid`.

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `cu_r` | out | 12 | Result pixel stream, R, sending to CU |
| `cu_g` | out | 12 | G, to CU |
| `cu_b` | out | 12 | B, to CU |
| `cu_a` | out | 12 | A, to CU |
| `cu_pvalid` | out | 1 | Pixel valid to CU |
| `cu_pready` | in | 1 | CU ready |
