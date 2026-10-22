# hvu1_rgb2yuv — RGB to YUV color-space converter

Converts RGB pixels into YUV (YCbCr) color space using the standard BT.601 or BT.709 coefficients. Input pixel stream uses the same internal interface protocol as [[hvu1_rgb2rgb]], receiving up to 16 pixels per cycle. The output is a YUV 4:4:4 pixel stream, where each pixel carries `{Y, Cb, Cr, A}` — the alpha channel passes through unchanged.

This module sits in the `input_reformat` stage of the HVU1 pipeline, downstream of [[hvu1_rgb2rgb]] and upstream of `local_memory`.

---

## Strategies

- Same passive stream interface as `hvu1_rgb2rgb`: valid/ready handshake, 16 px/cycle, `hvu1_px48_t` payload.
- Configurable standard select (`bt_sel_i`): `1'b0` = BT.601 (SDTV), `1'b1` = BT.709 (HDTV).
- 3-stage pipeline: multiply-per-component → sum → offset/clamp. Keeps `f_max` high at the cost of 3 cycles of latency.
- Fixed-point arithmetic (Q1.15 signed coefficients) — no floating-point, no division.
- Alpha channel passes through combinatorially (unchanged); pipeline registers only cover Y/Cb/Cr.
- Output uses the same `hvu1_px48_t` struct, re-mapped as `{Y, Cb, Cr, A}`.

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

**Output mapping:** The `hvu1_px48_t` struct is re-purposed for YUV:

| Struct field | Input meaning | Output meaning |
|-------------|---------------|----------------|
| `.r`        | Red           | Y  (luma)      |
| `.g`        | Green         | Cb (blue-difference chroma) |
| `.b`        | Blue          | Cr (red-difference chroma)  |
| `.a`        | Alpha         | Alpha (pass-through)        |

---

## Conversion formulas

### BT.601 (SDTV, `bt_sel_i = 1'b0`)

```
Y  =  0.299000 * R + 0.587000 * G + 0.114000 * B
Cb = -0.168736 * R - 0.331264 * G + 0.500000 * B + 2048
Cr =  0.500000 * R - 0.418688 * G - 0.081312 * B + 2048
```

### BT.709 (HDTV, `bt_sel_i = 1'b1`)

```
Y  =  0.212600 * R + 0.715200 * G + 0.072200 * B
Cb = -0.114572 * R - 0.385428 * G + 0.500000 * B + 2048
Cr =  0.500000 * R - 0.454153 * G - 0.045847 * B + 2048
```

- **R, G, B** range: `[0, 4095]` (12-bit unsigned).
- **Y** range: `[0, 4095]` (12-bit unsigned).
- **Cb, Cr** range: `[0, 4095]` (12-bit unsigned, offset-binary with midpoint at 2048).
- **Offset 2048** = 12-bit midpoint = `12'd2048` = `2^(12-1)`.

---

## Fixed-point coefficient encoding

All coefficients are stored in **Q1.15** format: 16-bit signed, 1 sign bit + 0 integer bits + 15 fractional bits.

Resolution: `2^-15 ≈ 0.0000305`. Range: `[-1.0, 1.0 - 2^-15]`.

### BT.601 coefficients (Q1.15)

| Coeff  | Float value  | Q1.15 integer | Hex      |
|--------|-------------|---------------|----------|
| Y_R    | +0.299000   | +9798         | 16'h2646 |
| Y_G    | +0.587000   | +19235        | 16'h4B23 |
| Y_B    | +0.114000   | +3736         | 16'h0E98 |
| Cb_R   | -0.168736   | -5529         | 16'hEA67 |
| Cb_G   | -0.331264   | -10855        | 16'hD599 |
| Cb_B   | +0.500000   | +16384        | 16'h4000 |
| Cr_R   | +0.500000   | +16384        | 16'h4000 |
| Cr_G   | -0.418688   | -13720        | 16'hCA68 |
| Cr_B   | -0.081312   | -2664         | 16'hF598 |

### BT.709 coefficients (Q1.15)

| Coeff  | Float value  | Q1.15 integer | Hex      |
|--------|-------------|---------------|----------|
| Y_R    | +0.212600   | +6966         | 16'h1B36 |
| Y_G    | +0.715200   | +23436        | 16'h5B8C |
| Y_B    | +0.072200   | +2366         | 16'h093E |
| Cb_R   | -0.114572   | -3754         | 16'hF156 |
| Cb_G   | -0.385428   | -12630        | 16'hCEAA |
| Cb_B   | +0.500000   | +16384        | 16'h4000 |
| Cr_R   | +0.500000   | +16384        | 16'h4000 |
| Cr_G   | -0.454153   | -14882        | 16'hC5DE |
| Cr_B   | -0.045847   | -1502         | 16'hFA22 |

---

## Pipeline architecture

```
cycle N:   Stage 0 — multiply     (9 DSPs per pixel)
cycle N+1: Stage 1 — sum          (3 adder trees per pixel)
cycle N+2: Stage 2 — offset/clamp (Cb/Cr offset + clip to [0,4095])
cycle N+3: output valid
```

```
 pix_data_i ──┬─ R ─┬─× Y_R ─┐
              │     ├─× Cb_R ┐│
              │     └─× Cr_R ┐││
              ├─ G ─┬─× Y_G ┐│││
              │     ├─× Cb_G ││││   Stage 0           Stage 1        Stage 2
              │     └─× Cr_G ││││  (multiply)         (sum)          (offset)
              ├─ B ─┬─× Y_B ─┼───[+]── Y_raw ──────────────────────── Y
              │     ├─× Cb_B ─┼───[+]── Cb_raw ──[+2048]──[clip]── Cb
              │     └─× Cr_B ─┼───[+]── Cr_raw ──[+2048]──[clip]── Cr
              └─ A ────────────────────────────────────────────────── A
                                  (pass-through — 3-cycle delay regs)
```

**Latency:** 3 cycles (registered pipeline).
**Throughput:** 16 pixels / cycle (after pipeline fill).

---

## Port definitions

| Port | Dir | Type / Width | Description |
|------|-----|--------------|-------------|
| `clk_i` | input | `logic` | Core clock |
| `rstn_i` | input | `logic` | Async reset, active low |
| `pix_valid_i` | input | `logic` | Input pixel data valid |
| `pix_ready_o` | output | `logic` | Module ready to accept input |
| `pix_data_i` | input | `hvu1_px48_t [0:15]` | Input 16-pixel vector `{R,G,B,A}` |
| `bt_sel_i` | input | `logic` | `0` = BT.601, `1` = BT.709 |
| `pix_valid_o` | output | `logic` | Output pixel data valid (delayed 3 cycles) |
| `pix_ready_i` | input | `logic` | Downstream ready to accept output |
| `pix_data_o` | output | `hvu1_px48_t [0:15]` | Output 16-pixel vector `{Y,Cb,Cr,A}` |

---

## RTL implementation

```verilog
//=============================================================================
// hvu1_rgb2yuv — 3-stage RGB→YUV (YCbCr) converter, BT.601 / BT.709 (16 px/cyc)
//=============================================================================
//
// Converts 12-bit RGB pixels to YCbCr 4:4:4 using BT.601 (SDTV) or BT.709
// (HDTV) coefficients selected by bt_sel_i.  Fixed-point Q1.15 arithmetic
// with a 3-stage pipeline: multiply → sum → offset/clamp.
//
// Latency: 3 cycles.  Throughput: 16 pixels / cycle.
// Alpha channel passes through unchanged (3-cycle delay matched).
//
// Interface: same valid/ready stream protocol as hvu1_rgb2rgb.
// See: doc/spec/modules/hvu1_rgb2yuv.md
//=============================================================================

`include "hvu1_types.svh"

module hvu1_rgb2yuv (
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
    localparam int COEFF_W     = 16;          // Q1.15 coefficient width
    localparam int COMP_W      = 12;          // input component width
    localparam int MUL_W       = COMP_W + COEFF_W;  // 28-bit product
    localparam int SUM_W       = MUL_W + 2;   // 30-bit sum (3 terms)
    localparam int MIDPOINT    = 12'd2048;    // Cb/Cr offset (12-bit)
    localparam int CLAMP_MAX   = 12'd4095;    // 12-bit max

    //-------------------------------------------------------------------------
    // BT.601 coefficients (Q1.15, 16-bit signed)
    //-------------------------------------------------------------------------
    // Y  =  0.299*R + 0.587*G + 0.114*B
    // Cb = -0.168736*R - 0.331264*G + 0.5*B + 2048
    // Cr =  0.5*R - 0.418688*G - 0.081312*B + 2048
    //-------------------------------------------------------------------------
    localparam logic signed [COEFF_W-1:0] BT601_YR  = 16'sd9798;
    localparam logic signed [COEFF_W-1:0] BT601_YG  = 16'sd19235;
    localparam logic signed [COEFF_W-1:0] BT601_YB  = 16'sd3736;
    localparam logic signed [COEFF_W-1:0] BT601_CbR = -16'sd5529;
    localparam logic signed [COEFF_W-1:0] BT601_CbG = -16'sd10855;
    localparam logic signed [COEFF_W-1:0] BT601_CbB = 16'sd16384;
    localparam logic signed [COEFF_W-1:0] BT601_CrR = 16'sd16384;
    localparam logic signed [COEFF_W-1:0] BT601_CrG = -16'sd13720;
    localparam logic signed [COEFF_W-1:0] BT601_CrB = -16'sd2664;

    //-------------------------------------------------------------------------
    // BT.709 coefficients (Q1.15, 16-bit signed)
    //-------------------------------------------------------------------------
    // Y  =  0.2126*R + 0.7152*G + 0.0722*B
    // Cb = -0.114572*R - 0.385428*G + 0.5*B + 2048
    // Cr =  0.5*R - 0.454153*G - 0.045847*B + 2048
    //-------------------------------------------------------------------------
    localparam logic signed [COEFF_W-1:0] BT709_YR  = 16'sd6966;
    localparam logic signed [COEFF_W-1:0] BT709_YG  = 16'sd23436;
    localparam logic signed [COEFF_W-1:0] BT709_YB  = 16'sd2366;
    localparam logic signed [COEFF_W-1:0] BT709_CbR = -16'sd3754;
    localparam logic signed [COEFF_W-1:0] BT709_CbG = -16'sd12630;
    localparam logic signed [COEFF_W-1:0] BT709_CbB = 16'sd16384;
    localparam logic signed [COEFF_W-1:0] BT709_CrR = 16'sd16384;
    localparam logic signed [COEFF_W-1:0] BT709_CrG = -16'sd14882;
    localparam logic signed [COEFF_W-1:0] BT709_CrB = -16'sd1502;

    //-------------------------------------------------------------------------
    // Coefficient mux (combinational)
    //-------------------------------------------------------------------------
    logic signed [COEFF_W-1:0] coeff_y_r,  coeff_y_g,  coeff_y_b;
    logic signed [COEFF_W-1:0] coeff_cb_r, coeff_cb_g, coeff_cb_b;
    logic signed [COEFF_W-1:0] coeff_cr_r, coeff_cr_g, coeff_cr_b;

    always_comb begin
        if (bt_sel_i) begin
            // BT.709
            coeff_y_r  = BT709_YR;  coeff_y_g  = BT709_YG;  coeff_y_b  = BT709_YB;
            coeff_cb_r = BT709_CbR; coeff_cb_g = BT709_CbG; coeff_cb_b = BT709_CbB;
            coeff_cr_r = BT709_CrR; coeff_cr_g = BT709_CrG; coeff_cr_b = BT709_CrB;
        end else begin
            // BT.601
            coeff_y_r  = BT601_YR;  coeff_y_g  = BT601_YG;  coeff_y_b  = BT601_YB;
            coeff_cb_r = BT601_CbR; coeff_cb_g = BT601_CbG; coeff_cb_b = BT601_CbB;
            coeff_cr_r = BT601_CrR; coeff_cr_g = BT601_CrG; coeff_cr_b = BT601_CrB;
        end
    end

    //-------------------------------------------------------------------------
    // Pipeline registers
    //-------------------------------------------------------------------------
    // Stage 0 → 1: raw products (28-bit signed)
    logic signed [MUL_W-1:0] s1_prod_y_r  [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_y_g  [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_y_b  [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cb_r [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cb_g [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cb_b [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cr_r [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cr_g [0:PX-1];
    logic signed [MUL_W-1:0] s1_prod_cr_b [0:PX-1];

    // Stage 1 → 2: raw sums (30-bit signed)
    logic signed [SUM_W-1:0] s2_sum_y  [0:PX-1];
    logic signed [SUM_W-1:0] s2_sum_cb [0:PX-1];
    logic signed [SUM_W-1:0] s2_sum_cr [0:PX-1];

    // Alpha delay chain (3 cycles to match Y/Cb/Cr pipeline)
    logic [COMP_W-1:0] s1_alpha [0:PX-1];
    logic [COMP_W-1:0] s2_alpha [0:PX-1];

    // Valid/ready shift registers (3-stage delay)
    logic [2:0] valid_sr;
    logic [2:0] ready_sr;

    //-------------------------------------------------------------------------
    // Stage 0: Multiply (combinational) — register the products
    //-------------------------------------------------------------------------
    genvar px;
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage0
            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    s1_prod_y_r  [px] <= '0;
                    s1_prod_y_g  [px] <= '0;
                    s1_prod_y_b  [px] <= '0;
                    s1_prod_cb_r [px] <= '0;
                    s1_prod_cb_g [px] <= '0;
                    s1_prod_cb_b [px] <= '0;
                    s1_prod_cr_r [px] <= '0;
                    s1_prod_cr_g [px] <= '0;
                    s1_prod_cr_b [px] <= '0;
                    s1_alpha     [px] <= '0;
                end else if (pix_valid_i && pix_ready_i) begin
                    // Y channel products
                    s1_prod_y_r [px] <= $signed({1'b0, pix_data_i[px].r}) * coeff_y_r;
                    s1_prod_y_g [px] <= $signed({1'b0, pix_data_i[px].g}) * coeff_y_g;
                    s1_prod_y_b [px] <= $signed({1'b0, pix_data_i[px].b}) * coeff_y_b;

                    // Cb channel products
                    s1_prod_cb_r[px] <= $signed({1'b0, pix_data_i[px].r}) * coeff_cb_r;
                    s1_prod_cb_g[px] <= $signed({1'b0, pix_data_i[px].g}) * coeff_cb_g;
                    s1_prod_cb_b[px] <= $signed({1'b0, pix_data_i[px].b}) * coeff_cb_b;

                    // Cr channel products
                    s1_prod_cr_r[px] <= $signed({1'b0, pix_data_i[px].r}) * coeff_cr_r;
                    s1_prod_cr_g[px] <= $signed({1'b0, pix_data_i[px].g}) * coeff_cr_g;
                    s1_prod_cr_b[px] <= $signed({1'b0, pix_data_i[px].b}) * coeff_cr_b;

                    // Alpha: start delay chain
                    s1_alpha    [px] <= pix_data_i[px].a;
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Stage 1: Sum (combinational) — register the 3-term sums
    //-------------------------------------------------------------------------
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage1
            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    s2_sum_y  [px] <= '0;
                    s2_sum_cb [px] <= '0;
                    s2_sum_cr [px] <= '0;
                    s2_alpha  [px] <= '0;
                end else if (valid_sr[0] && ready_sr[0]) begin
                    s2_sum_y [px]  <= s1_prod_y_r [px] + s1_prod_y_g [px] + s1_prod_y_b [px];
                    s2_sum_cb[px]  <= s1_prod_cb_r[px] + s1_prod_cb_g[px] + s1_prod_cb_b[px];
                    s2_sum_cr[px]  <= s1_prod_cr_r[px] + s1_prod_cr_g[px] + s1_prod_cr_b[px];
                    s2_alpha [px]  <= s1_alpha[px];
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Stage 2: Offset + clamp + output (combinational → register output)
    //-------------------------------------------------------------------------
    // Y: shift right by 15 (Q1.15 → integer), clamp to [0, 4095]
    // Cb/Cr: add midpoint offset in Q1.15 domain, then shift, then clamp
    //
    // Arithmetic detail:
    //   Each product is 12-bit unsigned × Q1.15 signed = Q13.15 (28-bit signed)
    //   Sum of 3 products = Q13.17 (30-bit signed, 2 extra bits for 3-term sum)
    //   After >> 15 we get Q13.2 — the integer part, then clamp to 12-bit.
    //-------------------------------------------------------------------------
    generate
        for (px = 0; px < PX; px = px + 1) begin : g_stage2

            // --- intermediate combinational signals ---
            logic signed [SUM_W-1:0] cb_with_offset;
            logic signed [SUM_W-1:0] cr_with_offset;

            logic [COMP_W-1:0] y_clamped;
            logic [COMP_W-1:0] cb_clamped;
            logic [COMP_W-1:0] cr_clamped;

            always_comb begin
                // Y: arithmetic right-shift by 15 (Q1.15 → integer), then clamp
                y_clamped  = clamp_12bit(s2_sum_y[px]  >>> 15);

                // Cb/Cr: add midpoint (2048) aligned to Q1.15 domain, then
                //        shift and clamp
                cb_with_offset = s2_sum_cb[px] + $signed(MIDPOINT << 15);
                cr_with_offset = s2_sum_cr[px] + $signed(MIDPOINT << 15);
                cb_clamped = clamp_12bit(cb_with_offset >>> 15);
                cr_clamped = clamp_12bit(cr_with_offset >>> 15);
            end

            always_ff @(posedge clk_i or negedge rstn_i) begin
                if (!rstn_i) begin
                    pix_data_o[px].r <= '0;   // Y
                    pix_data_o[px].g <= '0;   // Cb
                    pix_data_o[px].b <= '0;   // Cr
                    pix_data_o[px].a <= '0;   // Alpha
                end else if (valid_sr[1] && ready_sr[1]) begin
                    pix_data_o[px].r <= y_clamped;
                    pix_data_o[px].g <= cb_clamped;
                    pix_data_o[px].b <= cr_clamped;
                    pix_data_o[px].a <= s2_alpha[px];   // alpha passes through
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Valid/ready shift register (3-stage delay)
    //-------------------------------------------------------------------------
    // valid_sr[0] = stage 1 enabled, valid_sr[1] = stage 2 enabled,
    // valid_sr[2] = output valid.
    //-------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            valid_sr <= '0;
            ready_sr <= '0;
        end else begin
            // valid propagates forward each stage
            if (pix_ready_i) begin
                valid_sr <= {valid_sr[1:0], pix_valid_i && pix_ready_o};
            end
            // ready propagates backward (track ready for each pipe stage)
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
| **f_max target** | ≥ 400 MHz (28 nm) — single multiply + adder per stage |
| **DSP usage** | 16 px × 9 multiplies = 144 DSPs (or 16 DSPs if time-multiplexed; see notes) |
| **Register bits** | ~20 Kbits (16 px × 28-bit × 9 products + 3 × 30-bit sums + alpha chain) |

**Area optimization notes:**
- The 9 multiplies per pixel can be time-multiplexed across 3 cycles using 3 DSPs/px instead of 9, at the cost of lower throughput (16/3 px/cycle).
- If synthesis maps `$signed` multiplies to LUTs instead of DSPs, LUT count will be significant (~50K LUTs for 16 px × 9 multiplies of 13×16 bits). For production, ensure the synthesis tool infers DSP48 blocks.
- The coefficient mux is a 16-bit 2:1 mux per coefficient (27 muxes total) — negligible area.

---

## Hierarchy

```
hvu1_rgb2yuv
├── Coefficient mux (bt_sel_i → BT.601 or BT.709 coefficients)
├── Stage 0: 16× 9-multiply bank (registered)
├── Stage 1: 16× 3-sum adder tree (registered)
├── Stage 2: offset + clamp + output register
├── Alpha delay chain (3-cycle shift register)
└── Valid/ready shift register (3-stage)
```

Pipeline placement in HVU1:

```
axi_master → input_reformat → local_memory → division → image_op → display
                 ↑
          hvu1_rgb2rgb (channel swap, 0-cycle)
                 ↓
          hvu1_rgb2yuv (color-space convert, 3-cycle)
```

---

## Verification checklist

1. **BT.601 identity:** pure-red `{4095, 0, 0, 0}` → Y≈1224, Cb≈1408, Cr≈2048.
2. **BT.601 grayscale:** `{2048, 2048, 2048, 0}` → Y≈2048, Cb≈2048, Cr≈2048 (no chroma on neutral).
3. **BT.709 identity:** pure-green `{0, 4095, 0, 0}` → Y≈2929, Cb≈470, Cr≈164.
4. **BT.709 grayscale:** `{2048, 2048, 2048, 0}` → Y≈2048, Cb≈2048, Cr≈2048.
5. **Alpha pass-through:** random alpha values on each of 16 lanes → all pass through unchanged.
6. **Pipeline fill/drain:** valid/ready pattern matches 3-cycle latency exactly.
7. **Back-pressure:** de-assert `pix_ready_i` → pipeline stalls, `pix_valid_o` holds.
8. **Clamp:** drive R=4095, G=0, B=0 with BT.601 → Y clamped at 4095 (not overflowing).
9. **BT select switch:** mid-stream `bt_sel_i` toggles → output changes 3 cycles later (pipeline delay).
10. **All-16-lane:** drive distinct patterns on each of the 16 lanes → verify all lanes compute independently.

---

## Revision history

| Date | Change |
|------|--------|
| 2026-07-16 | Initial spec: BT.601/BT.709 coefficients, Q1.15 fixed-point, 3-stage pipeline, RTL, verification checklist |