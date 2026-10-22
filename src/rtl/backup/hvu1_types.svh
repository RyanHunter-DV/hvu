//=============================================================================
// hvu1_types.svh — Shared type definitions for the HVU1 image pipeline
//=============================================================================
// HVU1 internal pixel format: 48 bits = four 12-bit components {R, G, B, A}
// See: doc/spec/modules/hvu1_rotate_block.md

`ifndef HVU1_TYPES_SVH
`define HVU1_TYPES_SVH

typedef logic [11:0] hvu1_px_comp_t;

typedef struct packed {
    hvu1_px_comp_t r;
    hvu1_px_comp_t g;
    hvu1_px_comp_t b;
    hvu1_px_comp_t a;
} hvu1_px48_t;   // 48 bits per pixel

`endif // HVU1_TYPES_SVH
