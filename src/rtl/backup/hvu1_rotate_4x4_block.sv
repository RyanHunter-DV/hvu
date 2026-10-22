//=============================================================================
// hvu1_rotate_4x4_block — Combinational 4×4 pixel-block rotator
//=============================================================================
//
// Permutes pixel positions within a 4×4 block for 0°, 90°, 180°, and 270°
// clockwise rotation.  Purely combinational — no clock, no storage.
//
// Rotation mapping (N=4, L=N-1=3):
//   rot_i = 2'b00:  dst[i][j] = src[i]    [j]        (bypass, 0°)
//   rot_i = 2'b01:  dst[i][j] = src[L-j]  [i]        (90° CW)
//   rot_i = 2'b10:  dst[i][j] = src[L-i]  [L-j]      (180°)
//   rot_i = 2'b11:  dst[i][j] = src[j]    [L-i]      (270° CW)
//
// Pixel payload (48-bit hvu1_px48_t) passes through unchanged — only
// positions are permuted.
//
// See: doc/spec/modules/hvu1_rotate_block.md
//=============================================================================

`include "hvu1_types.svh"

module hvu1_rotate_4x4_block (
    input  hvu1_px48_t src [0:3][0:3],   // source 4×4 pixel array
    input  logic [1:0] rot_i,            // rotation select (see table above)
    output hvu1_px48_t dst [0:3][0:3]    // rotated 4×4 pixel array
);

    localparam int N = 4;
    localparam int L = N - 1;            // L = 3

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[i][j] = src[i]    [j];       // 0° (bypass)
                        2'b01:   dst[i][j] = src[L-j]  [i];       // 90° CW
                        2'b10:   dst[i][j] = src[L-i]  [L-j];     // 180°
                        2'b11:   dst[i][j] = src[j]    [L-i];     // 270° CW
                        default: dst[i][j] = src[i]    [j];       // safe fallback
                    endcase
                end
            end
        end
    endgenerate

endmodule
