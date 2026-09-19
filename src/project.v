/*
 * Tiny Flappy - a Flappy Bird style game for Tiny Tapeout (VGA 640x480 @ 60 Hz)
 * SPDX-License-Identifier: Apache-2.0
 *
 * Controls : ui_in[0] = UP button.  Each press (rising edge) is one flap.
 *            Holding the button does NOT keep flapping, so you have to tap.
 * Output   : TinyVGA PMOD (same pinout as the vga example)
 *
 * Game flow
 *   READY : bird hovers, first press starts the game
 *   RUN   : pipes scroll left, score +1 for every pipe you get past
 *   DEAD  : bird turns red and drops; press UP once it has landed to restart
 *
 * The pipes are drawn as 3D blocks (oblique projection): a lit front face,
 * a bright top face and a dark right side face.  The bird collides with what
 * you see, i.e. also with the top / side faces.
 */

`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock (25.175 MHz)
    input  wire       rst_n     // reset_n - low to reset
);

  // ------------------------------------------------------------------------
  // Tunables
  // ------------------------------------------------------------------------
  // Scroll speed in pixels per frame. Pipe spacing is 384 px, so use a
  // divisor of 384 (2, 3, 4, 6, 8) to keep both pipes perfectly aligned.
  localparam signed [9:0] SPEED = 10'sd3;
  // Bird geometry: 32x24 px, x fixed at 160 (multiple of 32, see in_bird_box)
  localparam [8:0] BIRD_MAX_Y = 9'd408;   // 432 (ground) - 24 (bird height)
  localparam [8:0] BIRD_START_Y = 9'd192;

  // ------------------------------------------------------------------------
  // VGA timing
  // ------------------------------------------------------------------------
  wire       hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;

  hvsync_generator hvsync_gen (
      .clk(clk),
      .reset(~rst_n),
      .hsync(hsync),
      .vsync(vsync),
      .display_on(video_active),
      .hpos(pix_x),
      .vpos(pix_y)
  );

  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;
  wire _unused_ok = &{ena, ui_in[7:1], uio_in, 1'b0};

  // ------------------------------------------------------------------------
  // Button: synchronise + rising edge
  // ------------------------------------------------------------------------
  reg [2:0] btn_sr;
  always @(posedge clk) btn_sr <= {btn_sr[1:0], ui_in[0]};
  wire btn_rise = btn_sr[1] & ~btn_sr[2];

  // One tick per frame, at the start of the vertical sync (blanking area)
  reg vsync_q;
  always @(posedge clk) vsync_q <= vsync;
  wire frame_tick = vsync_q & ~vsync;

  // ------------------------------------------------------------------------
  // Pseudo random numbers for the pipe gaps
  // ------------------------------------------------------------------------
  reg [7:0] lfsr;
  always @(posedge clk) begin
    if (!rst_n) lfsr <= 8'hA5;
    else        lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
  end

  // ------------------------------------------------------------------------
  // Game state
  // ------------------------------------------------------------------------
  localparam [1:0] S_READY = 2'd0, S_RUN = 2'd1, S_DEAD = 2'd2;

  reg  [1:0]        state;
  reg  [8:0]        bird_y;        // top of the bird, in pixels
  reg  signed [4:0] vel;           // vertical speed, pixels / frame (down = +)
  reg  signed [9:0] pipe_x;        // left edge of the NEAR pipe footprint (may be < 0)
  reg  [2:0]        gap_n, gap_f;  // gap position of near / far pipe (far = near + 384 px)
  reg               near_on;       // near pipe exists (hidden at game start)
  reg               scored;        // near pipe already counted
  reg  [3:0]        score_o, score_t;
  reg  [5:0]        gscroll;       // ground scroll phase
  reg               flap_pending;  // a press happened during this frame
  reg               hit;           // bird overlapped a pipe during this frame
  wire              hit_now;

  wire flap_ok = flap_pending & (state != S_DEAD);

  wire signed [4:0]  vel_next = flap_ok ? -5'sd10 :
                                (vel < 5'sd10) ? (vel + 5'sd1) : vel;
  wire signed [10:0] y_sum    = $signed({2'b00, bird_y}) + vel_next;
  wire [8:0]         y_next   = y_sum[10] ? 9'd0 :
                                (y_sum > 11'sd408) ? BIRD_MAX_Y : y_sum[8:0];

  wire restart = frame_tick & (state == S_DEAD) & flap_pending & (bird_y == BIRD_MAX_Y);

  always @(posedge clk) begin
    if (!rst_n || restart) begin
      state        <= S_READY;
      bird_y       <= BIRD_START_Y;
      vel          <= 5'sd0;
      pipe_x       <= 10'sd320;       // near pipe hidden, far pipe starts off screen
      gap_n        <= 3'd0;
      gap_f        <= lfsr[2:0];
      near_on      <= 1'b0;
      scored       <= 1'b1;
      score_o      <= 4'd0;
      score_t      <= 4'd0;
      gscroll      <= 6'd0;
      flap_pending <= 1'b0;
      hit          <= 1'b0;
    end else begin
      // remember button presses / collisions until the next frame update
      if (frame_tick) flap_pending <= btn_rise;
      else if (btn_rise) flap_pending <= 1'b1;

      if (frame_tick) hit <= 1'b0;
      else if (hit_now) hit <= 1'b1;

      if (frame_tick) begin
        if (state != S_DEAD) gscroll <= gscroll + 6'd3;

        case (state)
          S_READY: begin
            if (flap_pending) begin
              state  <= S_RUN;
              vel    <= vel_next;
              bird_y <= y_next;
            end
          end

          S_RUN: begin
            vel    <= vel_next;
            bird_y <= y_next;

            // scroll the pipes
            if (pipe_x > (SPEED - 10'sd64)) begin
              pipe_x <= pipe_x - SPEED;
            end else begin
              // near pipe is gone: far pipe becomes near, spawn a new far pipe
              pipe_x  <= pipe_x + (10'sd384 - SPEED);
              gap_n   <= gap_f;
              gap_f   <= lfsr[2:0];
              near_on <= 1'b1;
              scored  <= 1'b0;
            end

            // score when the near pipe has just passed the bird
            if (!scored && pipe_x <= 10'sd112) begin
              scored <= 1'b1;
              if (score_o == 4'd9) begin
                score_o <= 4'd0;
                score_t <= (score_t == 4'd9) ? 4'd0 : score_t + 4'd1;
              end else begin
                score_o <= score_o + 4'd1;
              end
            end

            if (hit || y_next == BIRD_MAX_Y) state <= S_DEAD;
          end

          default: begin  // S_DEAD: the bird falls down
            vel    <= vel_next;
            bird_y <= y_next;
          end
        endcase
      end
    end
  end

  // ------------------------------------------------------------------------
  // Pipes (3D blocks).  Each pipe has a 64 px wide footprint:
  //     0..47  front face      48..63  right side face (depth 16 px)
  // Depth goes up-and-to-the-right, so a standing pipe also shows its top face.
  // ------------------------------------------------------------------------
  wire [9:0] dx    = pix_x - $unsigned(pipe_x);   // position relative to near pipe
  wire       in_n  = near_on & (dx[9:6] == 4'd0);
  wire       in_f  = (dx[9:6] == 4'd6);           // far pipe is 384 px = 6*64 further right
  wire [5:0] dxo   = dx[5:0];
  wire       front_col = (dxo[5:4] != 2'b11);
  wire       side_col  = ~front_col;
  wire [2:0] gidx  = in_n ? gap_n : gap_f;

  wire [5:0] yr = pix_y[9:4];                     // 16 px rows
  // gap top   = 16*gk   (= 48 + 32*gidx)
  // gap bottom= 16*hk   (= gap top + 144)
  wire [4:0] gk = {1'b0, gidx, 1'b0} + 5'd3;
  wire [4:0] hk = gk + 5'd9;

  // upper pipe (hangs from the ceiling)
  wire       above_gap = (yr < {1'b0, gk});
  wire [5:0] jh        = {1'b0, gk} - yr;         // >= 1 inside the upper pipe rows
  wire [4:0] ysum      = {1'b0, pix_y[3:0]} + {1'b0, dxo[3:0]};
  wire       hang_front = above_gap & front_col;
  wire       hang_side  = above_gap & side_col & ((jh >= 6'd2) | ~ysum[4]);

  // lower pipe (stands on the ground)
  wire [5:0] ubh        = yr - {1'b0, hk};
  wire       below_top  = ~ubh[5];
  wire       row_above  = (ubh == 6'h3F);         // 16 rows just above the front top edge
  wire [6:0] tsum       = {1'b0, dxo} + {3'b000, pix_y[3:0]};
  wire       stand_front = below_top & front_col;
  wire       stand_side  = (below_top & side_col) | (row_above & tsum[6]);
  wire       stand_top   = row_above & ~tsum[6] & (tsum[5:4] != 2'b00);

  wire pipe_x_hit = in_n | in_f;
  wire pipe_px    = pipe_x_hit & (hang_front | hang_side | stand_front | stand_side | stand_top);

  // shading
  wire is_front = pipe_x_hit & (hang_front | stand_front);
  wire outline  = (dxo[5:1] == 5'd0) |                                   // left edge
                  (dxo[5:1] == 5'b10111) |                               // edge towards side face
                  (stand_front & (yr == {1'b0, hk}) & (pix_y[3:1] == 3'd0)) |   // top edge
                  (hang_front & (jh == 6'd1) & (pix_y[3:1] == 3'b111));         // bottom edge
  wire [5:0] pipe_col = (is_front & outline)      ? 6'b00_00_00 :
                        (is_front & dxo[5:2] == 4'd2)  ? 6'b10_11_00 :   // highlight stripe
                        (is_front & dxo[5:2] == 4'd10) ? 6'b00_10_00 :   // shadow stripe
                         is_front                ? 6'b01_11_00 :         // front (lime)
                        (stand_top & ~stand_side & ~stand_front) ? 6'b10_11_01 : // top (light)
                                                  6'b00_01_00;           // side (dark)

  // ------------------------------------------------------------------------
  // Bird sprite: 8x6 cells of 4x4 px = 32x24 px at x = 160
  // ------------------------------------------------------------------------
  wire [9:0] by = pix_y - {1'b0, bird_y};
  wire in_bird_box = (pix_x[9:5] == 5'd5) && (by[9:5] == 5'd0) && (by[4:3] != 2'b11);
  wire [2:0] bc = pix_x[4:2];
  wire [2:0] br = by[4:2];

  reg [7:0] body_mask;
  always @* begin
    case (br)
      3'd0, 3'd5: body_mask = 8'b0011_1100;
      3'd1, 3'd4: body_mask = 8'b0111_1110;
      default:    body_mask = 8'b1111_1111;
    endcase
  end
  wire body_px  = body_mask[~bc];
  wire eye_px   = ((br == 3'd1) || (br == 3'd2)) && ((bc == 3'd5) || (bc == 3'd6));
  wire pupil_px = (br == 3'd2) && (bc == 3'd6);
  wire beak_px  = ((br == 3'd3) || (br == 3'd4)) && (bc[2:1] == 2'b11);
  wire wing_up  = vel[4];                                  // rising -> wing up
  wire [2:0] wr = br - (wing_up ? 3'd2 : 3'd3);
  wire wing_px  = (bc >= 3'd1) && (bc <= 3'd3) && (wr[2:1] == 2'b00);

  wire bird_px  = in_bird_box & (body_px | beak_px);
  wire dead     = (state == S_DEAD);
  wire [5:0] bird_col = pupil_px ? 6'b00_00_00 :
                        eye_px   ? 6'b11_11_11 :
                        beak_px  ? 6'b11_01_00 :
                        wing_px  ? 6'b11_10_00 :
                        dead     ? 6'b11_00_00 :
                                   6'b11_11_00;

  assign hit_now = bird_px & pipe_px;

  // ------------------------------------------------------------------------
  // Background: sky gradient + scrolling ground
  // ------------------------------------------------------------------------
  wire [5:0] sky_col = (yr < 6'd10) ? 6'b00_10_11 :
                       (yr < 6'd20) ? 6'b01_10_11 :
                                      6'b10_11_11;

  wire       ground     = (yr >= 6'd27);                     // y >= 432
  wire [5:0] gx         = pix_x[5:0] + gscroll;
  wire       grass      = (pix_y[9:3] == 7'd54);             // 432..439
  wire       grass_line = (pix_y[9:1] == 9'd216);            // 432..433
  wire [5:0] ground_col = grass_line ? 6'b00_01_00 :
                          grass      ? ((gx[4] ^ pix_y[2]) ? 6'b01_11_00 : 6'b00_11_00) :
                                       ((gx[5] ^ pix_y[4]) ? 6'b10_01_00 : 6'b01_01_00);

  // ------------------------------------------------------------------------
  // Score: two 7-segment digits (5x9 cells of 4x4 px) at the top centre
  // ------------------------------------------------------------------------
  wire [7:0] cx  = pix_x[9:2];
  wire [6:0] cy  = pix_y[9:2];
  wire [7:0] rel = cx - 8'd75;
  wire       in_rows = (cy >= 7'd2) && (cy < 7'd11);
  wire [3:0] srow = cy[3:0] - 4'd2;                          // 0..8
  wire       in_tens = (rel < 8'd5) && (score_t != 4'd0);
  wire       in_ones = (rel >= 8'd6) && (rel < 8'd11);
  wire [3:0] rel_o   = rel[3:0] - 4'd6;
  wire [2:0] scol    = in_tens ? rel[2:0] : rel_o[2:0];
  wire [3:0] digit   = in_tens ? score_t : score_o;

  reg [6:0] seg;  // {a,b,c,d,e,f,g}
  always @* begin
    case (digit)
      4'd0: seg = 7'b1111110;
      4'd1: seg = 7'b0110000;
      4'd2: seg = 7'b1101101;
      4'd3: seg = 7'b1111001;
      4'd4: seg = 7'b0110011;
      4'd5: seg = 7'b1011011;
      4'd6: seg = 7'b1011111;
      4'd7: seg = 7'b1110000;
      4'd8: seg = 7'b1111111;
      4'd9: seg = 7'b1111011;
      default: seg = 7'b0000000;
    endcase
  end

  wire digit_px = in_rows & (in_tens | in_ones) & (
                  (seg[6] & (srow == 4'd0)) |
                  (seg[0] & (srow == 4'd4)) |
                  (seg[3] & (srow == 4'd8)) |
                  (seg[1] & (scol == 3'd0) & (srow <= 4'd4)) |
                  (seg[5] & (scol == 3'd4) & (srow <= 4'd4)) |
                  (seg[2] & (scol == 3'd0) & (srow >= 4'd4)) |
                  (seg[4] & (scol == 3'd4) & (srow >= 4'd4)));

  // ------------------------------------------------------------------------
  // Compose the picture (score > bird > pipes > ground > sky) and register it
  // ------------------------------------------------------------------------
  wire [5:0] world_col = pipe_px ? pipe_col : ground ? ground_col : sky_col;
  wire [5:0] pix_col   = digit_px ? 6'b11_11_11 : bird_px ? bird_col : world_col;
  wire [5:0] out_col   = video_active ? pix_col : 6'b000000;

  reg [5:0] rgb_q;
  reg       hs_q, vs_q;
  always @(posedge clk) begin
    rgb_q <= out_col;
    hs_q  <= hsync;
    vs_q  <= vsync;
  end

  wire [1:0] R = rgb_q[5:4];
  wire [1:0] G = rgb_q[3:2];
  wire [1:0] B = rgb_q[1:0];

  // TinyVGA PMOD
  assign uo_out = {hs_q, B[0], G[0], R[0], vs_q, B[1], G[1], R[1]};

endmodule