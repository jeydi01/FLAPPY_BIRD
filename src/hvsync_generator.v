/*
 * Standard hvsync_generator used in Tiny Tapeout VGA examples (Uri Shaked).
 * 640x480 @ 60Hz, 25.175MHz pixel clock (approximated with 25MHz).
 */
`default_nettype none

module hvsync_generator(
    input wire clk,
    input wire reset,
    output reg hsync,
    output reg vsync,
    output wire display_on,
    output wire [9:0] hpos,
    output wire [9:0] vpos
);

  // horizontal timing
  parameter H_DISPLAY       = 640;
  parameter H_BACK          = 48;
  parameter H_FRONT         = 16;
  parameter H_SYNC          = 96;
  localparam H_TOTAL = H_DISPLAY + H_BACK + H_FRONT + H_SYNC; // 800

  // vertical timing
  parameter V_DISPLAY       = 480;
  parameter V_TOP           = 33;
  parameter V_BOTTOM        = 10;
  parameter V_SYNC          = 2;
  localparam V_TOTAL = V_DISPLAY + V_TOP + V_BOTTOM + V_SYNC; // 525

  reg [9:0] h_count;
  reg [9:0] v_count;

  wire hmaxxed = (h_count == H_TOTAL - 1);
  wire vmaxxed = (v_count == V_TOTAL - 1);

  always @(posedge clk) begin
    if (reset) begin
      h_count <= 0;
    end else if (hmaxxed) begin
      h_count <= 0;
    end else begin
      h_count <= h_count + 1;
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      v_count <= 0;
    end else if (hmaxxed) begin
      if (vmaxxed) v_count <= 0;
      else v_count <= v_count + 1;
    end
  end

  always @(posedge clk) begin
    if (reset) hsync <= 1'b0;
    else hsync <= (h_count >= (H_DISPLAY + H_FRONT)) && (h_count < (H_DISPLAY + H_FRONT + H_SYNC));
  end

  always @(posedge clk) begin
    if (reset) vsync <= 1'b0;
    else vsync <= (v_count >= (V_DISPLAY + V_BOTTOM)) && (v_count < (V_DISPLAY + V_BOTTOM + V_SYNC));
  end

  assign display_on = (h_count < H_DISPLAY) && (v_count < V_DISPLAY);
  assign hpos = h_count;
  assign vpos = v_count;

endmodule