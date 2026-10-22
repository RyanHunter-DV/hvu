Support fetching from system memory with source format (rgb or bgr) then translated to target format, then write back to target place. If the source place and target place are the same start or overlapped, the original content will be replaced. Users need make sure the correctly setting of the source/target address.
the conversion logic is pure easy which just to switch the pixel address.
The source pixel may: rgb, bgr, rgba or bgra, which affects the address locating, but the 'A' field always stays at the end, which means this part of the data will never changed.
rgb to rgba/bgra is not support, hvu cannot know how to add or remove the 'A' color channel.

A top module for rgb2rgb conversion, the input or output pixel data communicates with the [[hvu1_sys_dma]] device, use internal interface protocol. This module cannot fetch or write to the system memory directly.

# Strategies
- inputs source pixel stream with valid signal, this module passively accepts pixel data and do conversion.
- input 12x4bits x 16 pixel data, which means this module can convert maximum with 16pixels within one cycle.
- configurable source format and target format, no matter has 'A' channel or not, the last 12bits are always directly pass to output.
- use combinational logic to switch the color space

---

## Pixel format

Pixels use the HVU1 internal format: **48 bits per pixel** — four 12-bit components `{R, G, B, A}`.

```verilog
// hvu1_types.svh
typedef logic [11:0] hvu1_px_comp_t;
typedef struct packed {
    hvu1_px_comp_t r;
    hvu1_px_comp_t g;
    hvu1_px_comp_t b;
    hvu1_px_comp_t a;
} hvu1_px48_t;   // 48 bits
```

### External format encoding (`fmt_i`)

External (memory-side) pixel formats are identified by a 2-bit encoding.
Bit [1] indicates alpha presence; bit [0] indicates R/B channel order.

| `fmt_i` | Format | Channel order | Has alpha? |
|---------|--------|---------------|------------|
| `2'b00` | RGB    | `{R, G, B}`   | No         |
| `2'b01` | BGR    | `{B, G, R}`   | No         |
| `2'b10` | RGBA   | `{R, G, B, A}`| Yes        |
| `2'b11` | BGRA   | `{B, G, R, A}`| Yes        |

### Conversion rule

The conversion is purely combinational — it re-maps the R and B channels of each pixel based on the source and target format encodings. The G and A channels pass through unchanged.

Since the operation is symmetric (R↔B swap), the same logic handles both directions:

| `src_fmt_i[1:0]` | `dst_fmt_i[1:0]` | Action |
|-------------------|-------------------|--------|
| `00` (RGB)        | `01` (BGR)        | swap R↔B |
| `01` (BGR)        | `00` (RGB)        | swap R↔B |
| `10` (RGBA)       | `11` (BGRA)       | swap R↔B |
| `11` (BGRA)       | `10` (RGBA)       | swap R↔B |
| same as dst        | same as src       | pass-through (no swap) |

**Illegal cases:** src has alpha but dst does not, or vice versa (`src_fmt_i[1] != dst_fmt_i[1]`). These are flagged on `err_o` (alpha mismatch). The module still produces output by treating the last 12 bits as alpha and passing them through, but the result is semantically invalid.

---

## Port definitions

| Port | Dir | Type / Width | Description |
|------|-----|--------------|-------------|
| `pix_valid_i` | input | `logic` | Input pixel data valid |
| `pix_ready_o` | output | `logic` | Module ready to accept input |
| `pix_data_i` | input | `hvu1_px48_t [0:15]` | Input 16-pixel vector |
| `src_fmt_i` | input | `logic [1:0]` | Source pixel format (see encoding table) |
| `dst_fmt_i` | input | `logic [1:0]` | Target pixel format (see encoding table) |
| `pix_valid_o` | output | `logic` | Output pixel data valid |
| `pix_ready_i` | input | `logic` | Downstream ready to accept output |
| `pix_data_o` | output | `hvu1_px48_t [0:15]` | Output 16-pixel vector (converted) |
| `err_o` | output | `logic` | Alpha mismatch error flag |

---

## RTL implementation

```verilog
//=============================================================================
// hvu1_rgb2rgb — Combinational RGB↔BGR pixel-format converter (16 px/cycle)
//=============================================================================
//
// Converts between RGB, BGR, RGBA, and BGRA pixel formats.  Up to 16 pixels
// are processed per cycle.  The conversion is purely combinational — the R
// and B channels are swapped when source and target formats differ in R/B
// order.  The G and A channels always pass through unchanged.
//
// Format encoding (src_fmt_i / dst_fmt_i):
//   2'b00 — RGB   (no alpha)
//   2'b01 — BGR   (no alpha)
//   2'b10 — RGBA  (alpha at end)
//   2'b11 — BGRA  (alpha at end)
//
// Alpha-channel mismatch (src_fmt_i[1] != dst_fmt_i[1]) is flagged on err_o
// but conversion proceeds — the last 12-bit component is treated as alpha
// and passed through.
//
// Interface: passive stream consumer/producer via valid/ready handshake.
// Communicates with hvu1_sys_dma using internal interface protocol.
//
// See: doc/spec/modules/hvu1_rgb2rgb.md
//=============================================================================

`include "hvu1_types.svh"

module hvu1_rgb2rgb (
    // --- input stream (from DMA) ---
    input  logic          pix_valid_i,
    output logic          pix_ready_o,
    input  hvu1_px48_t    pix_data_i [0:15],

    // --- configuration ---
    input  logic [1:0]    src_fmt_i,
    input  logic [1:0]    dst_fmt_i,

    // --- output stream (to downstream) ---
    output logic          pix_valid_o,
    input  logic          pix_ready_i,
    output hvu1_px48_t    pix_data_o [0:15],

    // --- status ---
    output logic          err_o
);

    //-------------------------------------------------------------------------
    // Format decode
    //-------------------------------------------------------------------------
    // fmt_i[0]  — 0: R-first (RGB/RGBA), 1: B-first (BGR/BGRA)
    // fmt_i[1]  — 0: no alpha, 1: has alpha
    //-------------------------------------------------------------------------

    wire src_has_alpha = src_fmt_i[1];
    wire dst_has_alpha = dst_fmt_i[1];
    wire src_is_bgr    = src_fmt_i[0];
    wire dst_is_bgr    = dst_fmt_i[0];

    // Swap R↔B when source and target differ in R/B channel order.
    // The swap decision is independent of alpha presence.
    wire do_swap = src_is_bgr ^ dst_is_bgr;   // XOR: 1 when orders differ

    // Alpha mismatch: src and dst disagree on alpha presence.
    // The spec forbids adding/removing the A channel.
    assign err_o = src_has_alpha ^ dst_has_alpha;

    //-------------------------------------------------------------------------
    // Stream handshake (pass-through)
    //-------------------------------------------------------------------------
    // This module is combinational (0-cycle latency), so valid/ready flow
    // through directly.  pix_ready_o is gated by downstream readiness so
    // back-pressure propagates upstream.
    //-------------------------------------------------------------------------

    assign pix_valid_o = pix_valid_i;
    assign pix_ready_o = pix_ready_i;

    //-------------------------------------------------------------------------
    // Per-pixel channel swizzle (combinational)
    //-------------------------------------------------------------------------
    // Each of the 16 pixels is independently converted.  When do_swap is
    // asserted, the R and B channels are exchanged; G and A pass through.
    //
    // Note: the A channel (last 12-bit component) is always passed through
    // regardless of whether the format declares alpha.  This is by design —
    // the "no alpha" formats (RGB/BGR) simply have the 4th component treated
    // as padding that flows through unchanged.
    //-------------------------------------------------------------------------

    genvar px;
    generate
        for (px = 0; px < 16; px = px + 1) begin : g_pixel
            always_comb begin
                if (do_swap) begin
                    pix_data_o[px].r = pix_data_i[px].b;
                    pix_data_o[px].g = pix_data_i[px].g;
                    pix_data_o[px].b = pix_data_i[px].r;
                    pix_data_o[px].a = pix_data_i[px].a;
                end else begin
                    pix_data_o[px]   = pix_data_i[px];
                end
            end
        end
    endgenerate

endmodule
```

---

## Timing / area

- **Latency:** 0 cycles (combinational).
- **Throughput:** 16 pixels / cycle (when `pix_valid_i` and `pix_ready_i` are both asserted).
- **Area:** per pixel — 4 × 12-bit multiplexers (R and B channels); 2 × 12-bit pass-through wires (G and A). Total: 16 × (2 × 12-bit) muxes ≈ 384 2:1 mux elements. Negligible for a DPU datapath.
- **Critical path:** 1 level of 2:1 mux gated by `do_swap` (a single XOR of two static configuration bits). No timing concern.

---

## Hierarchy

```
hvu1_rgb2rgb
├── Format decoder (combinational wires)
├── Stream handshake (valid/ready pass-through)
└── 16× per-pixel channel swizzle (generate — combinational)
```

This module sits inside the `hvu1_fetch_unit` → `input_reformat` stage of the HVU1 pipeline:

```
axi_master → input_reformat → local_memory → division → image_op → display
                 ↑
          hvu1_rgb2rgb
```

---

## Verification checklist

1. **Pass-through:** `src_fmt_i == dst_fmt_i` → all 16 pixels pass through unchanged.
2. **RGB ↔ BGR:** drive `{12'hAAA, 12'hBBB, 12'hCCC, 12'hDDD}` per pixel; verify R↔B swap, G and A unchanged.
3. **RGBA ↔ BGRA:** same channel swap test with alpha present; verify A passes through untouched.
4. **Alpha mismatch:** `src_fmt_i[1] != dst_fmt_i[1]` → `err_o` asserted, data still produced.
5. **Back-pressure:** de-assert `pix_ready_i` → `pix_ready_o` de-asserts, `pix_valid_o` holds.
6. **All-16-pixel coverage:** verify all 16 lanes independently with distinct patterns.

---

## Revision history

| Date       | Change                                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| 2026-07-15 | Added RTL implementation, port definitions, format encoding table, timing/area notes, verification checklist |
| (earlier)  | Initial sketch                                                                                               |
|            |                                                                                                              |

---

