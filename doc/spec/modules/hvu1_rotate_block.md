# hvu1_rotate_4x4_block / hvu1_rotate_8x8_block

Combinational pixel-block rotators used in the HVU1 image pipeline (AFBC decode and layer transform). Each module permutes pixel positions inside a fixed-size square block for **0°, 90°, 180°, and 270° clockwise** rotation.

See also: [[../hvu1_design_brief|hvu1_design_brief]], [[../../../star1_linlon_d6/doc/raw/design_notes/image_rotation|image_rotation]].

---

## Overview

| Module | Block size | Role |
|--------|------------|------|
| `hvu1_rotate_4x4_block` | 4 × 4 pixels | Atomic rotator; rotates one quadrant |
| `hvu1_rotate_8x8_block` | 8 × 8 pixels | Top-level rotator; partitions into four 4 × 4 quadrants, rotates each quadrant, then re-maps quadrants |

Both modules are **purely combinational** (no clock). Rotation angle is selected per invocation through `rot_i`.

### Pixel format

Pixels use the HVU1 internal format from the design brief: **48 bits per pixel** — four 12-bit components `{R, G, B, A}`.

```verilog
// One pixel
typedef logic [11:0] hvu1_px_comp_t;
typedef struct packed {
    hvu1_px_comp_t r;
    hvu1_px_comp_t g;
    hvu1_px_comp_t b;
    hvu1_px_comp_t a;
} hvu1_px48_t;   // 48 bits
```

Rotators only permute pixel **positions**; pixel payload is passed through unchanged.

### Coordinate convention

- `src[i][j]` / `dst[i][j]`: **row** `i`, **column** `j`.
- `i = 0` is the **top** row; `j = 0` is the **left** column.
- Indices are **0-based** within the block.

### Rotation control (`rot_i`)

Matches Linlon D6 `ROT` field encoding (2 bits):

| `rot_i` | Rotation |
|---------|----------|
| `2'b00` | 0° (bypass) |
| `2'b01` | 90° clockwise |
| `2'b10` | 180° |
| `2'b11` | 270° clockwise (90° counter-clockwise) |

---

## hvu1_rotate_4x4_block

### Functionality

For a 4 × 4 source block `src[0:3][0:3]`, produce `dst[0:3][0:3]` according to `rot_i`.

Let `N = 4`, `L = N - 1 = 3`.

| `rot_i` | Mapping |
|---------|---------|
| `2'b00` | `dst[i][j] = src[i][j]` |
| `2'b01` | `dst[i][j] = src[L-j][i]` |
| `2'b10` | `dst[i][j] = src[L-i][L-j]` |
| `2'b11` | `dst[i][j] = src[j][L-i]` |

**90° clockwise** is transpose plus column reversal (`dst[i][j] = src[3-j][i]`).

All angles are implemented as **combinational permutations** (generate loops or explicit assigns). No storage.

### Ports

| Port | Dir | Type / Width | Description |
|------|-----|--------------|-------------|
| `src` | input | `hvu1_px48_t [0:3][0:3]` | Source 4 × 4 pixel array |
| `rot_i` | input | `logic [1:0]` | Rotation select (see table above) |
| `dst` | output | `hvu1_px48_t [0:3][0:3]` | Rotated 4 × 4 pixel array |

### RTL interface (reference)

```verilog
module hvu1_rotate_4x4_block (
    input  hvu1_px48_t src [0:3][0:3],
    input  logic [1:0] rot_i,
    output hvu1_px48_t dst [0:3][0:3]
);
    genvar i, j;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_row
            for (j = 0; j < 4; j = j + 1) begin : g_col
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[i][j] = src[i][j];
                        2'b01:   dst[i][j] = src[3-j][i];   // 90° CW
                        2'b10:   dst[i][j] = src[3-i][3-j]; // 180°
                        2'b11:   dst[i][j] = src[j][3-i];   // 270° CW
                        default: dst[i][j] = src[i][j];
                    endcase
                end
            end
        end
    endgenerate
endmodule
```

### Timing / area

- **Latency:** 0 cycles (combinational).
- **Area:** 16:1 multiplexing per pixel component; no multipliers or line buffers.

---

## hvu1_rotate_8x8_block

### Functionality

An 8 × 8 block is split into four 4 × 4 **quadrants**:
```
Original 8×8 layout (quadrant IDs):
+----------+----------+
|  Q0      |  Q1      |
| rows 0-3 | rows 0-3 |
| cols 0-3 | cols 4-7 |
+----------+----------+
|  Q2      |  Q3      |
| rows 4-7 | rows 4-7 |
| cols 0-3 | cols 4-7 |
+----------+----------+
```

**Step 1 — Partition:** Extract `q0..q3` from `src`:

| Quadrant | Source rows | Source cols |
|----------|-------------|-------------|
| Q0 | `0..3` | `0..3` |
| Q1 | `0..3` | `4..7` |
| Q2 | `4..7` | `0..3` |
| Q3 | `4..7` | `4..7` |

```verilog
q0[i][j] = src[i]  [j];
q1[i][j] = src[i]  [j+4];
q2[i][j] = src[i+4][j];
q3[i][j] = src[i+4][j+4];
```

**Step 2 — Intra-quadrant rotation:** Four instances of `hvu1_rotate_4x4_block` produce `rq0..rq3` from `q0..q3` with the same `rot_i`.

**Step 3 — Inter-quadrant remap:** Place rotated quadrants into the destination 8 × 8 layout.

| `rot_i` | Top-left `dst[0:3][0:3]` | Top-right `dst[0:3][4:7]` | Bottom-left `dst[4:7][0:3]` | Bottom-right `dst[4:7][4:7]` |
|---------|--------------------------|---------------------------|-----------------------------|------------------------------|
| `2'b00` | `rq0` | `rq1` | `rq2` | `rq3` |
| `2'b01` | `rq2` | `rq0` | `rq3` | `rq1` |
| `2'b10` | `rq3` | `rq2` | `rq1` | `rq0` |
| `2'b11` | `rq1` | `rq3` | `rq0` | `rq2` |

**90° clockwise** destination layout:

```
+----------+----------+
|  rq2     |  rq0     |
+----------+----------+
|  rq3     |  rq1     |
+----------+----------+
```

**Step 4 — Reconstruct:** Write the selected quadrants back into `dst[i][j]` using the inverse of the partition equations.

### Ports

| Port | Dir | Type / Width | Description |
|------|-----|--------------|-------------|
| `src` | input | `hvu1_px48_t [0:7][0:7]` | Source 8 × 8 pixel array |
| `rot_i` | input | `logic [1:0]` | Rotation select (shared by all four 4 × 4 instances) |
| `dst` | output | `hvu1_px48_t [0:7][0:7]` | Rotated 8 × 8 pixel array |

### RTL hierarchy (reference)

```verilog
module hvu1_rotate_8x8_block (
    input  hvu1_px48_t src [0:7][0:7],
    input  logic [1:0] rot_i,
    output hvu1_px48_t dst [0:7][0:7]
);
    hvu1_px48_t q0 [0:3][0:3], q1 [0:3][0:3], q2 [0:3][0:3], q3 [0:3][0:3];
    hvu1_px48_t rq0[0:3][0:3], rq1[0:3][0:3], rq2[0:3][0:3], rq3[0:3][0:3];

  // Step 1: partition (generate)
  // Step 2: four instances
    hvu1_rotate_4x4_block u_rot_q0 (.src(q0), .rot_i(rot_i), .dst(rq0));
    hvu1_rotate_4x4_block u_rot_q1 (.src(q1), .rot_i(rot_i), .dst(rq1));
    hvu1_rotate_4x4_block u_rot_q2 (.src(q2), .rot_i(rot_i), .dst(rq2));
    hvu1_rotate_4x4_block u_rot_q3 (.src(q3), .rot_i(rot_i), .dst(rq3));
  // Step 3–4: quadrant mux + reconstruct (generate, case on rot_i)
endmodule
```

### Timing / area

- **Latency:** 0 cycles (combinational).
- **Hierarchy:** 4 × `hvu1_rotate_4x4_block` + quadrant wiring/mux.
- Suited to **tile-parallel** AFBC decode where multiple 8 × 8 blocks are processed in parallel upstream/downstream.

---

## Design notes

1. **Tile alignment:** AFBC decode in Linlon D6 works on 4 × 4 sub-blocks ([[../../../star1_linlon_d6/doc/raw/design_notes/image_rotation|image_rotation]]). The 8 × 8 wrapper matches a 2 × 2 tile cluster while reusing the same 4 × 4 rotator.
2. **Flip composition:** Horizontal/vertical flip (separate HVU1 features) can be applied before or after rotation by mirroring row/column indices; these modules do not implement flip.
3. **Packed-bus variant:** If a flat bus is preferred over unpacked arrays, pack row-major with `src_flat[(row*4+col)*48 +: 48]` for 4 × 4 (3072 bits total) and `(row*8+col)*48` for 8 × 8 (3072 bits total). Permutation logic is unchanged.
4. **Verification:** Golden model is the mapping tables above; compare `dst` against software `rot_i` transforms on random `hvu1_px48_t` patterns.

---

## Revision history

| Date | Change |
|------|--------|
| 2026-07-09 | Initial structured spec: ports, rotation math, 8×8 quadrant strategy |
