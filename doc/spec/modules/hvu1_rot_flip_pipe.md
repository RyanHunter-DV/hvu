
Position mapper. Given an input sample `(pos_x, pos_y)` in the rotated-then-flipped image, produce the original buffer coordinate `(src_x, src_y)`.

This module does **not** walk a frame, generate an address stream, or talk to memory. Upstream (resize / interpolation) supplies each `(pos_x, pos_y)`; downstream (`hvu1_image_addr_coder` decoder) turns `(src_x, src_y)` into a byte offset if a fetch is needed.
Rotation mapping matches `hvu1_rotate_*_block` (`rot` is the same 2-bit field). Order is **rotate first, then flip**.
90° and 270° **swap** the logical image size that `(pos_x, pos_y)` lives in: `out_w = H`, `out_h = W`. 0° and 180° keep `out_w = W`, `out_h = H`. `img_width` / `img_height` always describe the original buffer `W` / `H`.


## Ports

| Port         | Dir | Width | Description                                  |
| ------------ | --- | ----- | -------------------------------------------- |
| `clk`        | in  | 1     | Clock                                        |
| `rst_n`      | in  | 1     | Async active-low reset                       |
| `img_width`  | in  | 16    | Original buffer width `W`                    |
| `img_height` | in  | 16    | Original buffer height `H`                   |
| `rot`        | in  | 2     | Rotation select (table above)                |
| `hflip`      | in  | 1     | Horizontal flip of the rotated raster        |
| `vflip`      | in  | 1     | Vertical flip of the rotated raster          |
| `pos_x`      | in  | 16    | Sample X in the rotated-then-flipped image   |
| `pos_y`      | in  | 16    | Sample Y in the rotated-then-flipped image   |
| `in_valid`   | in  | 1     | Input position valid                         |
| `in_ready`   | out | 1     | Pipe can accept this cycle                   |
| `src_x`      | out | 16    | Original buffer X (target position to fetch) |
| `src_y`      | out | 16    | Original buffer Y (target position to fetch) |
| `out_valid`  | out | 1     | Mapped position valid                        |
| `out_ready`  | in  | 1     | Downstream can accept this cycle             |
|              |     |       |                                              |

## Handshake

Input and output each use a valid/ready pair. A beat transfers when `valid && ready`.

- Input: `in_valid` / `in_ready` with `pos_x`, `pos_y`. Upstream may present a new position **every cycle**.
- Output: `out_valid` / `out_ready` with `src_x`, `src_y`. Hold the mapped position until downstream accepts.

Throughput is one position per cycle when both sides transfer (`in_valid && in_ready` and `out_valid && out_ready` in the same cycle is allowed: the output register is overwritten with the newly accepted mapping). `in_ready` is high when the output register is empty or the current output is being taken (`in_ready = !out_valid || out_ready`). Mapping is computed on the accepted input and registered for the output beat (one-cycle latency).

`rot`, `hflip`, `vflip`, `img_width`, and `img_height` are sampled with the input beat.

## Mapping

Flip is applied on the input coordinate (the rotated raster), then that coordinate is mapped through rotation to the original buffer:

- `ox' = hflip ? (out_w - 1 - pos_x) : pos_x`
- `oy' = vflip ? (out_h - 1 - pos_y) : pos_y`

`hflip` and `vflip` are independent (different axes).

| `rot`   | Angle   | Input space `(pos_x, pos_y)` | Original `(src_x, src_y)` from `(ox', oy')` |
| ------- | ------- | ---------------------------- | ------------------------------------------- |
| `2'b00` | 0°      | `W × H`                      | `(ox', oy')`                                |
| `2'b01` | 90° CW  | `H × W`                      | `(oy', H-1-ox')`                            |
| `2'b10` | 180°    | `W × H`                      | `(W-1-ox', H-1-oy')`                        |
| `2'b11` | 270° CW | `H × W`                      | `(W-1-oy', ox')`                            |

Example, 90° CW, no flip: input `(0, 0)` (top-left of the rotated image) maps to original `(0, H-1)` (bottom of the first column).
