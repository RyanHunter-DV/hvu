# hvu1_yuv2rgb — YUV to RGB color-space converter

Converts YUV (YCbCr) pixels back into RGB color space using the standard BT.601 or BT.709 inverse coefficients. Input pixel stream uses the same internal interface protocol as [[hvu1_rgb2rgb]] and [[hvu1_rgb2yuv]], receiving up to 16 pixels per cycle. The output is an RGB 4:4:4 pixel stream, where each pixel carries `{R, G, B, A}` — the alpha channel passes through unchanged.

This module is the inverse of [[hvu1_rgb2yuv]]. Composing the two should yield the original pixel (within fixed-point rounding tolerance).

This module sits in the `input_reformat` stage of the HVU1 pipeline, processing YUV data from memory before downstream RGB operations.

---

## Strategies

- Same passive stream interface as `hvu1_rgb2rgb`: valid/ready handshake, 16 px/cycle, `hvu1_px48_t` payload.
- Configurable standard select (`bt_sel_i`): `1'b0` = BT.601 (SDTV), `1'b1` = BT.709 (HDTV).
- 3-stage pipeline: offset-remove + multiply → sum → shift/clamp. Keeps `f_max` high at the cost of 3 cycles of latency.
- Fixed-point arithmetic (Q2.14 signed coefficients) — no floating-point, no division.
- **4 multiplies per pixel** (vs 9 in `hvu1_rgb2yuv`) — the inverse matrix is sparser.
- Alpha channel passes through unchanged (3-cycle delay chain).
- Output uses the same `hvu1_px48_t` struct, re-mapped as `{R, G, B, A}`.

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

**Input/output mapping:**

| Struct field | Input meaning | Output meaning |
|-------------|---------------|----------------|
| `.r`        | Y  (luma)     | R  (red)       |
| `.g`        | Cb (blue-difference chroma) | G  (green) |
| `.b`        | Cr (red-difference chroma)  | B  (blue)  |
| `.a`        | Alpha         | Alpha (pass-through)        |

---

## Conversion formulas

### BT.601 inverse (SDTV, `bt_sel_i = 1'b0`)

```
R = Y + 1.40200 * (Cr - 2048)
G = Y - 0.34414 * (Cb - 2048) - 0.71414 * (Cr - 2048)
B = Y + 1.77200 * (Cb - 2048)
```

### BT.709 inverse (HDTV, `bt_sel_i = 1'b1`)

```
R = Y + 1.57480 * (Cr - 2048)
G = Y - 0.18732 * (Cb - 2048) - 0.46812 * (Cr - 2048)
B = Y + 1.85560 * (Cb - 2048)
```

- **Y, Cb, Cr** range: `[0, 4095]` (12-bit unsigned, Cb/Cr offset-binary).
- **R, G, B** range: `[0, 4095]` (12-bit unsigned).
- **Offset 2048** = 12-bit midpoint. Subtracted from Cb/Cr **before** multiplication.
- **Note:** Some coefficients exceed 1.0 (e.g. 1.8556 for BT.709 Cb→B). The coefficient format accounts for this.

---

## Fixed-point coefficient encoding

All coefficients are stored in **Q2.14** format: 16-bit signed, 1 sign bit + 2 integer bits + 13 fractional bits.

Wait — more precisely: Q2.14 uses 1 sign + 2 integer + 13 fractional = 16 bits total. But the integer range is [−2, +1.999] with 2 integer bits (one of which handles the sign via two's complement). Let's define it as: **16-bit signed, scaling factor = 2^14 = 16384**.

Resolution: `2^-14 ≈ 0.000061`. Range: `[-2.0, 2.0 - 2^-14]`.

### BT.601 inverse coefficients (Q2.14)

| Coeff  | Formula term           | Float value | Q2.14 integer | Hex      |
|--------|------------------------|-------------|---------------|----------|
| Cr_R   | `(Cr-2048)` coeff for R | +1.40200    | +22970        | 16'h59BA |
| Cb_G   | `(Cb-2048)` coeff for G | -0.34414    | -5638         | 16'hE9FA |
| Cr_G   | `(Cr-2048)` coeff for G | -0.71414    | -11700        | 16'hD24C |
| Cb_B   | `(Cb-2048)` coeff for B | +1.77200    | +29032        | 16'h7168 |

### BT.709 inverse coefficients (Q2.14)

| Coeff  | Formula term           | Float value | Q2.14 integer | Hex      |
|--------|------------------------|-------------|---------------|----------|
| Cr_R   | `(Cr-2048)` coeff for R | +1.57480    | +25802        | 16'h64CA |
| Cb_G   | `(Cb-2048)` coeff for G | -0.18732    | -3069         | 16'hF403 |
| Cr_G   | `(Cr-2048)` coeff for G | -0.46812    | -7670         | 16'hE20A |
| Cb_B   | `(Cb-2048)` coeff for B | +1.85560    | +30402        | 16'h76C2 |

---

## Pipeline architecture

```
cycle N:   Stage 0 — offset-remove + multiply  (4 DSPs per pixel)
cycle N+1: Stage 1 — sum                        (R: 2 terms, G: 3 terms, B: 2 terms)
cycle N+2: Stage 2 — shift + clamp               (>> 14, clip to [0,4095])
cycle N+3: output valid
```

```
 pix_data_i ──┬─ Y ───────────────────────────────────────[×1]──┐
              │          Stage 0              Stage 1    Stage 2 │
              ├─ Cb ─[−2048]──┬─× Cb_G ──────────[+]──┐         │
              │               └─× Cb_B ──────────[+]──┼──[>>14]──[clip]── G
              │                                       │         │
              ├─ Cr ─[−2048]──┬─× Cr_R ───[+]─────────┼──[>>14]──[clip]── R
              │               └─× Cr_G ───[+]─────────┘         │
              │                                       │         │
              └─ A ─────────────────────────────────────────────┼────────── A
                                           (3-cycle delay regs) │
                                                                │
                                   Y ───────────[>>14]──[clip]── B
                                   (Y + Cb_B product, from above)
```

**Latency:** 3 cycles (registered pipeline).
**Throughput:** 16 pixels / cycle (after pipeline fill).

---

## Arithmetic detail

### Data flow per pixel

```
Stage 0:
  cb_diff = Cb - 2048           // 13-bit signed, range [-2048, +2047]
  cr_diff = Cr - 2048           // 13-bit signed, range [-2048, +2047]
  prod_cb_g = cb_diff × Cb_G   // 13b × Q2.14 = Q14.14 (29-bit signed)
  prod_cb_b = cb_diff × Cb_B   // 13b × Q2.14 = Q14.14 (29-bit signed)
  prod_cr_r = cr_diff × Cr_R   // 13b × Q2.14 = Q14.14 (29-bit signed)
  prod_cr_g = cr_diff × Cr_G   // 13b × Q2.14 = Q14.14 (29-bit signed)
  y_aligned = Y << 14           // 12b → 26-bit unsigned, zero-extended to 29-bit

Stage 1:
  sum_r = y_aligned + prod_cr_r                         // 2 terms → 30-bit
  sum_g = y_aligned + prod_cb_g + prod_cr_g             // 3 terms → 31-bit
  sum_b = y_aligned + prod_cb_b                         // 2 terms → 30-bit

Stage 2:
  R = clamp(sum_r >> 14, 0, 4095)
  G = clamp(sum_g >> 14, 0, 4095)
  B = clamp(sum_b >> 14, 0, 4095)
```

---

## Port definitions

| Port | Dir | Type / Width | Description |
|------|-----|--------------|-------------|
| `clk_i` | input | `logic` | Core clock |
| `rstn_i` | input | `logic` | Async reset, active low |
| `pix_valid_i` | input | `logic` | Input pixel data valid |
| `pix_ready_o` | output | `logic` | Module ready to accept input |
| `pix_data_i` | input | `hvu1_px48_t [0:15]` | Input 16-pixel vector `{Y,Cb,Cr,A}` |
| `bt_sel_i` | input | `logic` | `0` = BT.601, `1` = BT.709 |
| `pix_valid_o` | output | `logic` | Output pixel data valid (delayed 3 cycles) |
| `pix_ready_i` | input | `logic` | Downstream ready to accept output |
| `pix_data_o` | output | `hvu1_px48_t [0:15]` | Output 16-pixel vector `{R,G,B,A}` |

---

## RTL implementation

```verilog
//=============================================================================
// hvu1_yuv2rgb — 3-stage YUV→RGB converter, BT.601 / BT.709 (16 px/cyc)
//=============================================================================
//
// Converts 12-bit YCbCr 4:4:4 pixels back to RGB using BT.601 (SDTV) or
// BT.709 (HDTV) inverse coefficients selected by bt_sel_i.  Fixed-point
// Q2.14 arithmetic with a 3-stage pipeline:
//   Stage 0 — offset-remove + multiply
//   Stage 1 — sum
//   Stage 2 — shift + clamp
//
// Latency: 3 cycles.  Throughput: 16 pixels / cycle.
// Alpha channel passes through unchanged (3-cycle delay matched).
//
// This is the inverse of hvu1_rgb2yuv.
//
// Interface: same valid/ready stream protocol as hvu1_rgb2rgb.
// See: doc/spec/modules/hvu1_yuv2rgb.md
//=============================================================================

`include "hvu1_types.svh"

module hvu1_yuv2rgb (
    // --- clock & reset ---
    input  logic          clk_i,
    input  logic          rstn_i,

    // --- input stream ---
    input  logic          pix_valid_i,
    output logic          pix_ready_o,
    input  hvu1_px48_t    pix_data_i [0:15],

    // --- configuration ---
    input  logic          bt_sel_i,       // 0 = BT.601, 1 = BT.709

    // --- output stream ---
    output logic          pix_valid_o,
    input  logic          pix_ready_i,
    output hvu1_px48_t    pix_data_o [0:15]
);

    //-------------------------------------------------------------------------
    // Local parameters
    //-------------------------------------------------------------------------
    localparam int PX          = 16;          // pixels per cycle
    localparam int COEFF_W     = 16;          // Q2.14 coefficient width
    localparam int COMP_W      = 12;          // input component width
    localparam int DIFF_W      = 13;          // Cb/Cr diff width (signed, [-2048,2047])
    localparam int MUL_W       = DIFF_W + COEFF_W;   // 29-bit product (Q14.14)
    localparam int SUM_W       = 31;          // 31-bit sum (worst: G with 3 terms)
    localparam int SHIFT       = 14;          // Q2.14 → integer shift amount
    localparam int MIDPOINT    = 12'd2048;    // Cb/Cr offset (12-bit)
    localparam int CLAMP_MAX   = 12'd4095;    // 12-bit max

    //-------------------------------------------------------------------------
    // BT.601 inverse coefficients (Q2.14, 16-bit signed)
    //-------------------------------------------------------------------------
    // R = Y + 1.40200 * (Cr - 2048)
    // G = Y - 0.34414 * (Cb - 2048) - 0.71414 * (Cr - 2048)
    // B = Y + 1.77200 * (Cb - 2048)
    //-------------------------------------------------------------------------
    localparam logic signed [COEFF_W-1:0] BT601_CR_R = 16'sd22970;
    localparam logic signed [COEFF_W-1:0] BT601_CB_G = -16'sd5638;
    localparam logic signed [COEFF_W-1:0] BT601_CR_G = -16'sd11700;
    localparam logic signed [COEFF_W-1:0] BT601_CB_B = 16'sd29032;

    //-------------------------------------------------------------------------
    // BT.709 inverse coefficients (Q2.14, 16-bit signed)
    //-------------------------------------------------------------------------
    // R = Y + 1.57480 * (Cr - 2048)
    // G = Y - 0.18732 * (Cb - 2048) - 0.46812 * (Cr - 2048)
    // B = Y + 1.85560 * (Cb - 2048)
    //-------------------------------------------------------------------------
    localparam logic signed [COEFF_W-1:0] BT709_CR_R = 16'sd25802;
    localparam logic signed [COEFF_W-1:0] BT709_CB_G = -16'sd3069;
    localparam logic signed [COEFF_W-1:0] BT709_CR_G = -16'sd7670;
    localparam logic signed [COEFF_W-1:0] BT709_CB_B = 16'sd30402;

    //-------------------------------------------------------------------------
    // Coefficient mux (combinational)
    //-------------------------------------------------------------------------
    logic signed [COEFF_W-1:0] coeff_cr_r;
    logic signed [COEFF_W-1:0] coeff_cb_g;
    logic signed [COEFF_W-1:0] coeff_cr_g;
    logic signed [COEFF_W-1:0] coeff_cb_b;

    always_comb begin
        if (bt_sel_i) begin
            // BT.709
            coeff_cr_r = BT709_CR_R;
            coeff_cb_g = BT709_CB_G;
            coeff_cr_g = BT709_CR_G;
            coeff_cb_b = BT709_CB_B;
        end else begin
            // BT.601
            coeff_cr_r = BT601_CR_R;
            coeff_cb_g = BT601_CB_G;
            coeff_cr_g = BT601_CR_G;
            coeff_cb_b = BT601_CB_B;
        end
    end

    //-------------------------------------------------------------------------
    // Pipeline registers
    //-------------------------------------------------------------------------
    // Stage 0 → 1: products (29-bit signed) + Y aligned (29-bit signed)
    logic signed [MUL_W-1:0] s1_prod_cr_r [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cb_g [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cr_g [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cb_b [0:PX-1];
    logic signed [MUL_W-1:0] s1_y_aligned [0:PX-1];   // Y << 14

    // Stage 1 → 2: raw sums (31-bit signed)
    logic signed [SUM_W-1:0] s2_sum_r [0:PX-1];
    logic signed [SUM_W-1:0] s2_sum_g [0:PX-1];
    logic signed [SUM_W-1:0] s2_sum_b [0:PX-1];

    // Alpha delay chain (3 cycles)
    logic [COMP_W-1:0] s1_alpha [0:PX-1];
    logic [COMP_W-1:0] s2_alpha [0:PX-1];

    // Valid/ready shift registers (3-stage delay)
    logic [2:0] valid_sr;
    logic [2:0] ready_sr;

    //-------------------------------------------------------------------------
    // Stage 0: Offset-remove + multiply — register the products
    //-------------------------------------------------------------------------
    genvar px;
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage0
            // --- combinational intermediates ---
            logic signed [DIFF_W-1:0] cb_diff;
            logic signed [DIFF_W-1:0] cr_diff;

            always_comb begin
                // Remove midpoint offset: Cb/Cr are 12-bit unsigned [0,4095]
                // cb_diff, cr_diff are 13-bit signed [-2048, +2047]
                cb_diff = $signed({1'b0, pix_data_i[px].g}) - $signed(MIDPOINT);
                cr_diff = $signed({1'b0, pix_data_i[px].b}) - $signed(MIDPOINT);
            end

            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    s1_prod_cr_r[px] <= '0;
                    s1_prod_cb_g[px] <= '0;
                    s1_prod_cr_g[px] <= '0;
                    s1_prod_cb_b[px] <= '0;
                    s1_y_aligned[px] <= '0;
                    s1_alpha    [px] <= '0;
                end else if (pix_valid_i && pix_ready_i) begin
                    // Y: align to Q14.14 by left-shifting 14 bits
                    s1_y_aligned[px] <= $signed({1'b0, pix_data_i[px].r}) <<< SHIFT;

                    // Cr_diff × Cr→R coeff  →  R contribution
                    s1_prod_cr_r[px] <= cr_diff * coeff_cr_r;

                    // Cb_diff × Cb→G coeff  →  G contribution (term 1)
                    s1_prod_cb_g[px] <= cb_diff * coeff_cb_g;

                    // Cr_diff × Cr→G coeff  →  G contribution (term 2)
                    s1_prod_cr_g[px] <= cr_diff * coeff_cr_g;

                    // Cb_diff × Cb→B coeff  →  B contribution
                    s1_prod_cb_b[px] <= cb_diff * coeff_cb_b;

                    // Alpha: start delay chain
                    s1_alpha    [px] <= pix_data_i[px].a;
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Stage 1: Sum — register the results
    //-------------------------------------------------------------------------
    // R = Y_aligned + prod_cr_r                    (2 terms)
    // G = Y_aligned + prod_cb_g + prod_cr_g        (3 terms)
    // B = Y_aligned + prod_cb_b                    (2 terms)
    //-------------------------------------------------------------------------
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage1
            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    s2_sum_r[px] <= '0;
                    s2_sum_g[px] <= '0;
                    s2_sum_b[px] <= '0;
                    s2_alpha[px] <= '0;
                end else if (valid_sr[0] && ready_sr[0]) begin
                    s2_sum_r[px] <= s1_y_aligned[px] + s1_prod_cr_r[px];
                    s2_sum_g[px] <= s1_y_aligned[px] + s1_prod_cb_g[px] + s1_prod_cr_g[px];
                    s2_sum_b[px] <= s1_y_aligned[px] + s1_prod_cb_b[px];
                    s2_alpha[px] <= s1_alpha[px];
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Stage 2: Shift + clamp + output register
    //-------------------------------------------------------------------------
    // Arithmetic right-shift by SHIFT (14) to convert Q14.14 → integer,
    // then clamp to 12-bit unsigned range [0, 4095].
    //-------------------------------------------------------------------------
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage2

            logic [COMP_W-1:0] r_clamped;
            logic [COMP_W-1:0] g_clamped;
            logic [COMP_W-1:0] b_clamped;

            always_comb begin
                r_clamped = clamp_12bit($signed(s2_sum_r[px] >>> SHIFT));
                g_clamped = clamp_12bit($signed(s2_sum_g[px] >>> SHIFT));
                b_clamped = clamp_12bit($signed(s2_sum_b[px] >>> SHIFT));
            end

            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    pix_data_o[px].r <= '0;   // R
                    pix_data_o[px].g <= '0;   // G
                    pix_data_o[px].b <= '0;   // B
                    pix_data_o[px].a <= '0;   // Alpha
                end else if (valid_sr[1] && ready_sr[1]) begin
                    pix_data_o[px].r <= r_clamped;
                    pix_data_o[px].g <= g_clamped;
                    pix_data_o[px].b <= b_clamped;
                    pix_data_o[px].a <= s2_alpha[px];   // alpha passes through
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Valid/ready shift register (3-stage delay)
    //-------------------------------------------------------------------------
    // valid_sr[0] = stage 1 enabled
    // valid_sr[1] = stage 2 enabled
    // valid_sr[2] = output valid
    //-------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            valid_sr <= '0;
            ready_sr <= '0;
        end else begin
            if (pix_ready_i) begin
                valid_sr <= {valid_sr[1:0], pix_valid_i && pix_ready_o};
            end
            ready_sr <= {ready_sr[1:0], pix_ready_i};
        end
    end

    assign pix_valid_o = valid_sr[2];
    assign pix_ready_o = pix_ready_i;   // always ready when downstream is ready

    //-------------------------------------------------------------------------
    // Clamp function: limit signed value to 12-bit unsigned range [0, 4095]
    //-------------------------------------------------------------------------
    function automatic logic [COMP_W-1:0] clamp_12bit(
        input logic signed [SUM_W-1:0] val
    );
        if (val < 0)
            clamp_12bit = '0;
        else if (val > $signed(CLAMP_MAX))
            clamp_12bit = CLAMP_MAX;
        else
            clamp_12bit = val[COMP_W-1:0];
    endfunction

endmodule
```

---

## Timing / area

| Parameter | Value |
|-----------|-------|
| **Latency** | 3 clock cycles (registered pipeline) |
| **Throughput** | 16 pixels / cycle (after pipeline fill) |
| **f_max target** | ≥ 400 MHz (28 nm) — single multiply + 2- or 3-term adder per stage |
| **DSP usage** | 16 px × 4 multiplies = 64 DSPs |
| **Register bits** | ~12 Kbits (16 px × 29-bit × 4 products + 16 px × 29-bit Y + 3 × 31-bit sums + alpha chain) |

**Comparison with `hvu1_rgb2yuv`:**

| Metric | `hvu1_rgb2yuv` | `hvu1_yuv2rgb` |
|--------|---------------|----------------|
| Multiplies / pixel | 9 | 4 |
| DSPs (16 px) | 144 | 64 |
| Coefficient format | Q1.15 | Q2.14 |
| Offset direction | add after sum | subtract before multiply |
| Critical path | 3-term sum | 3-term sum (G channel) |

The inverse transform is significantly cheaper — the YUV→RGB matrix has many zero/identity entries.

---

## Round-trip fidelity

Composing `hvu1_rgb2yuv` → `hvu1_yuv2rgb` should recover the original RGB values within ±1 LSB for most inputs. The dominant error sources are:

1. **Coefficient quantization** (Q1.15 in forward, Q2.14 in inverse): ~0.5 LSB per multiply.
2. **Intermediate rounding** (truncation at shift): ~0.5 LSB per channel.
3. **Clamping:** values near 0 or 4095 may clip irreversibly.

Expected round-trip PSNR: > 54 dB (12-bit equivalent).

---

## Hierarchy

```
hvu1_yuv2rgb
├── Coefficient mux (bt_sel_i → BT.601 or BT.709 coefficients)
├── Stage 0: 16× (offset-remove + 4-multiply bank) (registered)
├── Stage 1: 16× (R: 2-term sum, G: 3-term sum, B: 2-term sum) (registered)
├── Stage 2: shift (>>14) + clamp + output register
├── Alpha delay chain (3-cycle shift register)
└── Valid/ready shift register (3-stage)
```

Pipeline placement in HVU1:

```
memory → input_reformat → local_memory → division → image_op → display
              ↑
       hvu1_yuv2rgb (YUV→RGB, 3-cycle)
              ↓
       hvu1_rgb2rgb (channel swap, 0-cycle)
```

A typical YUV-processing path might be:

```
memory (YUV data) → hvu1_yuv2rgb → hvu1_rgb2rgb → downstream RGB ops
```

Or for a round-trip in the reformat stage:

```
memory → hvu1_rgb2rgb → hvu1_rgb2yuv → ... processing ... → hvu1_yuv2rgb → display
```

---

## Verification checklist

1. **BT.601 neutral gray:** `{Y=2048, Cb=2048, Cr=2048, A=0}` → R≈2048, G≈2048, B≈2048 (no chroma shift).
2. **BT.601 red:** `{Y=712, Cb=1408, Cr=3499, A=0}` → R≈4095, G≈0, B≈0 (saturated red recovery).
3. **BT.709 neutral gray:** `{Y=2048, Cb=2048, Cr=2048, A=0}` → R≈2048, G≈2048, B≈2048.
4. **BT.709 green:** `{Y=2970, Cb=470, Cr=164, A=0}` → R≈0, G≈4095, B≈0 (saturated green recovery).
5. **Round-trip:** `rgb2yuv` → `yuv2rgb` with same `bt_sel_i` → output within ±1 LSB of input for non-saturated colors.
6. **Alpha pass-through:** random alpha values on each of 16 lanes → all pass through unchanged.
7. **Pipeline fill/drain:** valid/ready pattern matches 3-cycle latency exactly.
8. **Back-pressure:** de-assert `pix_ready_i` → pipeline stalls, `pix_valid_o` holds.
9. **Clamp underflow:** drive Cb=0, Cr=0, Y=0 → output at 0 (not negative) for all channels.
10. **Clamp overflow:** drive Y=4095, Cb=4095, Cr=4095 → output clamped at 4095.
11. **BT select switch:** mid-stream `bt_sel_i` toggles → output changes 3 cycles later.
12. **All-16-lane:** drive distinct patterns on each of the 16 lanes → verify all lanes compute independently.

---

## Revision history

| Date | Change |
|------|--------|
| 2026-07-16 | Initial spec: BT.601/BT.709 inverse coefficients, Q2.14 fixed-point, 3-stage pipeline, RTL, round-trip analysis, verification checklist |