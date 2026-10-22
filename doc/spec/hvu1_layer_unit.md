# Overview

## pipe line for rot/flip and resize

The LPU presents a packed raster to the CU, left-to-right, top-to-bottom.

Resize is the walk master. It iterates destination `(dst_x, dst_y)` over the programmed output size. If scaling is on, each destination sample inverse-maps to a Q16.16 logical-source coordinate and the interpolator issues one or more integer fetch positions. If scaling is off, the same walk emits integer positions 1:1.

Every fetch position is in the logical (post-rotate/flip) plane. It goes through `hvu1_rot_flip_pipe` to the original buffer coordinate, then through the position decoder to a memory offset. Pixel responses return to the interpolator; the completed destination pixel streams to the CU. 
## image position coder and decoder
to map the system address offset to image positions, input of the offset, and next cycle generates the pos_x and pos_y offsets.
after mapping to pos_x, pos_y, then to do rotate, flip and resize.
also requires a decoder that inputs are pos_x, pos_y, then output is the offset of system memory.
## rotating and flip
The layer unit supports 0°/90°/180°/270° clockwise rotation and independent hflip / vflip.

Resize (or any fetch client) issues a sample position `(pos_x, pos_y)` in the rotated-then-flipped image. `hvu1_rot_flip_pipe` maps that coordinate back to the original buffer position `(src_x, src_y)`. Byte addresses are **not** produced here; `hvu1_image_addr_coder` / the position decoder convert between `(src_x, src_y)` and a system-memory offset.

| Module               | RTL                                    | Role                                                                 |
| -------------------- | -------------------------------------- | -------------------------------------------------------------------- |
| `hvu1_rot_flip_pipe` | `src/rtl/lpu/rot/hvu1_rot_flip_pipe.v` | Map input `(pos_x, pos_y)` → original `(src_x, src_y)` (rotate, then flip) |

`img_width` / `img_height` are the original buffer size `W` / `H` (16-bit).


# Interface



---

# hvu1_rot_flip_pipe
[[modules/hvu1_rot_flip_pipe|hvu1_rot_flip_pipe]]

# hvu1_resize_pipe

Full module specification: [[modules/hvu1_resize_pipe|hvu1_resize_pipe]].

The scaler is **destination-driven**. It iterates `(dst_x, dst_y)` over `dst_width × dst_height` and inverse-maps each output sample into the logical source plane (the image **after** rotate/flip, **before** memory). Fetch positions leave this block on a valid/ready request bundle, pass `hvu1_rot_flip_pipe`, then the position decoder. Returned 12-bit components are interpolated to one destination pixel and streamed line-by-line to the CU.

## Strategies

- **Inverse map, not forward map.** Every CU pixel is produced once. Source coordinates are `src = dst * (src_dim / dst_dim)` in Q16.16.
- **Divide on frame start, multiply on the pixel path.** `ratio_w = (src_width  << 16) / dst_width`, `ratio_h` likewise. No per-pixel divider.
- **Bypass shares the walk.** `en = 0` issues integer `(dst_x, dst_y)` with a single fetch and pass-through payload, so rot/flip and DMA stay in circuit.
- **Interpolator owns tap count.** Nearest: one integer position (round Q16.16 with `integer + frac[15]`). Bilinear: four taps in 2×2 order, weights `{frac_x, frac_y}`. At most one destination pixel in flight.
- **Clamp to `[0, src_width-1] × [0, src_height-1]`.** Required so `dst_dim - 1` cannot index `src_dim`.
- **Backpressure everywhere.** `pixel_req_valid/ready`, `pixel_rsp_valid/ready`, and CU `dst_valid/ready`. The walk does not increment until the current output pixel is accepted.

## Modes

| `en` | `interpolation` | Action |
|------|-----------------|--------|
| 0 | — | 1:1 raster walk, one fetch per pixel |
| 1 | `2'b00` | Nearest |
| 1 | `2'b01` | Bilinear (2×2) |

`src_width` / `src_height` are post-rotate logical size. Packed-buffer size is programmed on `hvu1_rot_flip_pipe`.




# hvu1_axis_addr
according to the valid input pos_x/y, the width and color format settings, to calculate the target offset in the system memory, and then calculated with base address, to generate a real physical memory address of current position pixel.
input is axis, like the pos_x, pos_y, each can ranges from 0~8091

## ports

*inputs*:
- clk
- rst_n
- width
- offset

*outputs*:
- pos_x
- pos_y

# hvu1_csc
csc is color space change module, which will receive different pixel formats from the system memory and translated to the fixed argb format for internal process.
## ports
*with resize_pipe*
- csc_resize_pvalid/csc_reseize_pready, the valid/ready handshake
- csc_resize_r/g/b/a, output pixels
*with mem_ctrl*
the fetch requst sending by the axis2addr module, and csc only receives the pixel response from mem_ctrl.
- pixel_valid/ready handshake
- pixel_data_stream, 128 bits data stream reading from memory.
- 

*from register setting*
- pixel_format, indicates which format is in current memory for this layer.

## feature brief
*supports yuv444 -> rgb*


*support rgb conversion*
argb,rgba,abgr format conversion.

*support yuv444 -> yuv422 -> yuv420*
to support conversion from 444 until 420 or back verse.


*support two yuv420 storage format*
the yuv420 supports I420 and NV12 storage, which shall be treated as different yuv420 format.
