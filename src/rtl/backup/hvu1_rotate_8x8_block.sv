//=============================================================================
// hvu1_rotate_8x8_block — Combinational 8×8 pixel-block rotator
//=============================================================================
//
// Rotates an 8×8 pixel block by partitioning into four 4×4 quadrants,
// rotating each quadrant independently, then re-mapping the quadrants
// according to the rotation angle.
//
// Algorithm:
//   Step 1 — Partition: extract q0..q3 from src[0:7][0:7]
//   Step 2 — Intra-quadrant rotate: four instances of hvu1_rotate_4x4_block
//   Step 3 — Inter-quadrant remap: place rq0..rq3 per rot_i
//   Step 4 — Reconstruct: write selected quadrants into dst[0:7][0:7]
//
// Quadrant layout (original 8×8):
//   +----------+----------+
//   |  Q0      |  Q1      |   rows 0-3
//   | cols 0-3 | cols 4-7 |
//   +----------+----------+
//   |  Q2      |  Q3      |   rows 4-7
//   | cols 0-3 | cols 4-7 |
//   +----------+----------+
//
// Purely combinational — no clock, no storage.
// See: doc/spec/modules/hvu1_rotate_block.md
//=============================================================================

`include "hvu1_types.svh"

module hvu1_rotate_8x8_block (
    input  hvu1_px48_t src [0:7][0:7],   // source 8×8 pixel array
    input  logic [1:0] rot_i,            // rotation select
    output hvu1_px48_t dst [0:7][0:7]    // rotated 8×8 pixel array
);

    //=========================================================================
    // Step 1 — Partition: extract four 4×4 quadrants from src
    //=========================================================================
    hvu1_px48_t q0 [0:3][0:3];
    hvu1_px48_t q1 [0:3][0:3];
    hvu1_px48_t q2 [0:3][0:3];
    hvu1_px48_t q3 [0:3][0:3];

    genvar pi, pj;
    generate
        for (pi = 0; pi < 4; pi = pi + 1) begin : g_part_row
            for (pj = 0; pj < 4; pj = pj + 1) begin : g_part_col
                // Q0: top-left  (rows 0-3, cols 0-3)
                assign q0[pi][pj] = src[pi]  [pj];
                // Q1: top-right (rows 0-3, cols 4-7)
                assign q1[pi][pj] = src[pi]  [pj+4];
                // Q2: bottom-left (rows 4-7, cols 0-3)
                assign q2[pi][pj] = src[pi+4][pj];
                // Q3: bottom-right (rows 4-7, cols 4-7)
                assign q3[pi][pj] = src[pi+4][pj+4];
            end
        end
    endgenerate

    //=========================================================================
    // Step 2 — Intra-quadrant rotation: four 4×4 rotators
    //=========================================================================
    hvu1_px48_t rq0 [0:3][0:3];
    hvu1_px48_t rq1 [0:3][0:3];
    hvu1_px48_t rq2 [0:3][0:3];
    hvu1_px48_t rq3 [0:3][0:3];

    hvu1_rotate_4x4_block u_rot_q0 (
        .src   (q0),
        .rot_i (rot_i),
        .dst   (rq0)
    );

    hvu1_rotate_4x4_block u_rot_q1 (
        .src   (q1),
        .rot_i (rot_i),
        .dst   (rq1)
    );

    hvu1_rotate_4x4_block u_rot_q2 (
        .src   (q2),
        .rot_i (rot_i),
        .dst   (rq2)
    );

    hvu1_rotate_4x4_block u_rot_q3 (
        .src   (q3),
        .rot_i (rot_i),
        .dst   (rq3)
    );

    //=========================================================================
    // Step 3 & 4 — Inter-quadrant remap + reconstruct dst[0:7][0:7]
    //
    // Destination quadrant placement by rot_i:
    //            top-left       top-right      bottom-left    bottom-right
    //   2'b00:   rq0            rq1            rq2            rq3 (bypass)
    //   2'b01:   rq2            rq0            rq3            rq1 (90° CW)
    //   2'b10:   rq3            rq2            rq1            rq0 (180°)
    //   2'b11:   rq1            rq3            rq0            rq2 (270° CW)
    //=========================================================================

    genvar ri, rj;
    generate
        for (ri = 0; ri < 4; ri = ri + 1) begin : g_dst_row
            for (rj = 0; rj < 4; rj = rj + 1) begin : g_dst_col

                // --- top-left quadrant: dst[0:3][0:3] ---
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[ri]   [rj]   = rq0[ri][rj];
                        2'b01:   dst[ri]   [rj]   = rq2[ri][rj];
                        2'b10:   dst[ri]   [rj]   = rq3[ri][rj];
                        2'b11:   dst[ri]   [rj]   = rq1[ri][rj];
                        default: dst[ri]   [rj]   = rq0[ri][rj];
                    endcase
                end

                // --- top-right quadrant: dst[0:3][4:7] ---
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[ri]   [rj+4] = rq1[ri][rj];
                        2'b01:   dst[ri]   [rj+4] = rq0[ri][rj];
                        2'b10:   dst[ri]   [rj+4] = rq2[ri][rj];
                        2'b11:   dst[ri]   [rj+4] = rq3[ri][rj];
                        default: dst[ri]   [rj+4] = rq1[ri][rj];
                    endcase
                end

                // --- bottom-left quadrant: dst[4:7][0:3] ---
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[ri+4][rj]   = rq2[ri][rj];
                        2'b01:   dst[ri+4][rj]   = rq3[ri][rj];
                        2'b10:   dst[ri+4][rj]   = rq1[ri][rj];
                        2'b11:   dst[ri+4][rj]   = rq0[ri][rj];
                        default: dst[ri+4][rj]   = rq2[ri][rj];
                    endcase
                end

                // --- bottom-right quadrant: dst[4:7][4:7] ---
                always_comb begin
                    unique case (rot_i)
                        2'b00:   dst[ri+4][rj+4] = rq3[ri][rj];
                        2'b01:   dst[ri+4][rj+4] = rq1[ri][rj];
                        2'b10:   dst[ri+4][rj+4] = rq0[ri][rj];
                        2'b11:   dst[ri+4][rj+4] = rq2[ri][rj];
                        default: dst[ri+4][rj+4] = rq3[ri][rj];
                    endcase
                end

            end
        end
    endgenerate

endmodule
