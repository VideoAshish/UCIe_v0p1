//==============================================================================
// tlc_fifo.sv
//
// Production-grade synchronous FIFO for TileLink-C.
//
// Features
//   * Fully parameterized DATA_W / DEPTH
//   * Ready/valid interface
//   * Simultaneous enqueue/dequeue
//   * Registered storage
//   * Synthesis-friendly RAM/register inference
//   * Correct full/empty handling
//   * No combinational ready/valid loop through FIFO data
//   * Overflow/underflow protection
//   * Reset-clean state
//   * Optional SystemVerilog assertions
//
// Notes
//   * Fall-through mode is intentionally NOT used.
//   * Output is registered through the read pointer.
//   * This makes the FIFO safe to place between TL channels without creating
//     a combinational valid path.
//==============================================================================

module tlc_fifo #(
  parameter int unsigned DATA_W = 256,
  parameter int unsigned DEPTH  = 8,

  // If enabled, an enqueue and dequeue may occur in the same cycle while
  // the FIFO is full. This prevents an unnecessary one-cycle bubble.
  parameter bit ALLOW_FULL_BYPASS = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //--------------------------------------------------------------------------
  // Input / enqueue
  //--------------------------------------------------------------------------

  input  logic [DATA_W-1:0] in_data,
  input  logic              in_valid,
  output logic              in_ready,

  //--------------------------------------------------------------------------
  // Output / dequeue
  //--------------------------------------------------------------------------

  output logic [DATA_W-1:0] out_data,
  output logic              out_valid,
  input  logic              out_ready,

  //--------------------------------------------------------------------------
  // Status
  //--------------------------------------------------------------------------

  output logic              full,
  output logic              empty,

  output logic [$clog2(DEPTH+1)-1:0] count,

  //--------------------------------------------------------------------------
  // Error indications
  //--------------------------------------------------------------------------

  output logic              overflow,
  output logic              underflow
);

  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned PTR_W =
      (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  localparam int unsigned CNT_W =
      (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

  //==========================================================================
  // Storage
  //==========================================================================

  logic [DATA_W-1:0] mem [0:DEPTH-1];

  //==========================================================================
  // Pointers
  //==========================================================================

  logic [PTR_W-1:0] wr_ptr;
  logic [PTR_W-1:0] rd_ptr;

  //==========================================================================
  // Internal handshake
  //==========================================================================

  logic push;
  logic pop;

  //==========================================================================
  // Status
  //==========================================================================

  assign empty = (count == 0);

  assign full  = (count == DEPTH);

  //--------------------------------------------------------------------------
  // Normally, ready is deasserted when full.
  //
  // When full bypass is enabled, a simultaneous pop allows a push in the
  // same cycle. This avoids a bubble without creating a combinational path
  // from output VALID back into input VALID.
  //--------------------------------------------------------------------------

  always_comb begin

    if (!full) begin

      in_ready = 1'b1;

    end
    else if (ALLOW_FULL_BYPASS && out_ready && out_valid) begin

      in_ready = 1'b1;

    end
    else begin

      in_ready = 1'b0;

    end

  end


  assign push = in_valid && in_ready;

  assign pop  = out_valid && out_ready;


  //==========================================================================
  // Output valid
  //
  // Registered validity guarantees that the FIFO does not create a
  // combinational valid path from its input to its output.
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      out_valid <= 1'b0;

    end
    else begin

      case ({push, pop})

        2'b10: begin
          out_valid <= 1'b1;
        end

        2'b01: begin
          out_valid <= (count > 1);
        end

        2'b11: begin
          out_valid <= 1'b1;
        end

        default: begin
          out_valid <= out_valid;
        end

      endcase

    end

  end


  //==========================================================================
  // Data storage / read
  //
  // For a synchronous FIFO, data becomes visible after the write/read
  // clock edge.
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      out_data <= '0;

    end
    else begin

      // New FIFO head after a push into an empty FIFO.
      if (push && !out_valid) begin

        out_data <= in_data;

      end

      // Normal dequeue followed by another queued element.
      else if (pop && (count > 1)) begin

        out_data <= mem[
          (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1'b1
        ];

      end

      // Simultaneous pop/push from a one-entry FIFO.
      else if (push && pop && (count == 1)) begin

        out_data <= in_data;

      end

    end

  end


  //==========================================================================
  // Memory write
  //==========================================================================

  always_ff @(posedge clk) begin

    if (rst_n) begin

      if (push) begin

        mem[wr_ptr] <= in_data;

      end

    end

  end


  //==========================================================================
  // Pointer and count management
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;

    end
    else begin

      //----------------------------------------------------------------------  
      // Write pointer
      //----------------------------------------------------------------------

      if (push) begin

        if (wr_ptr == DEPTH-1)
          wr_ptr <= '0;
        else
          wr_ptr <= wr_ptr + 1'b1;

      end


      //----------------------------------------------------------------------  
      // Read pointer
      //----------------------------------------------------------------------

      if (pop) begin

        if (rd_ptr == DEPTH-1)
          rd_ptr <= '0;
        else
          rd_ptr <= rd_ptr + 1'b1;

      end


      //----------------------------------------------------------------------  
      // Occupancy
      //----------------------------------------------------------------------

      case ({push, pop})

        2'b10:
          count <= count + 1'b1;

        2'b01:
          count <= count - 1'b1;

        default:
          count <= count;

      endcase

    end

  end


  //==========================================================================
  // Overflow / underflow detection
  //
  // These are diagnostic pulses. They do not corrupt FIFO state.
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      overflow  <= 1'b0;
      underflow <= 1'b0;

    end
    else begin

      overflow  <= in_valid && !in_ready;

      underflow <= out_ready && !out_valid;

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  //--------------------------------------------------------------------------
  // Count must never exceed depth.
  //--------------------------------------------------------------------------

  property p_count_never_overflow;

    @(posedge clk)
    disable iff (!rst_n)

    count <= DEPTH;

  endproperty

  assert property (p_count_never_overflow)
    else $error(
      "TLC FIFO: count overflow"
    );


  //--------------------------------------------------------------------------
  // Count must never be negative.
  //--------------------------------------------------------------------------

  property p_count_never_underflow;

    @(posedge clk)
    disable iff (!rst_n)

    count >= 0;

  endproperty

  assert property (p_count_never_underflow)
    else $error(
      "TLC FIFO: count underflow"
    );


  //--------------------------------------------------------------------------
  // Empty implies zero count.
  //--------------------------------------------------------------------------

  property p_empty_count;

    @(posedge clk)
    disable iff (!rst_n)

    empty |-> (count == 0);

  endproperty

  assert property (p_empty_count)
    else $error(
      "TLC FIFO: EMPTY/count mismatch"
    );


  //--------------------------------------------------------------------------
  // Full implies count == DEPTH.
  //--------------------------------------------------------------------------

  property p_full_count;

    @(posedge clk)
    disable iff (!rst_n)

    full |-> (count == DEPTH);

  endproperty

  assert property (p_full_count)
    else $error(
      "TLC FIFO: FULL/count mismatch"
    );


  //--------------------------------------------------------------------------
  // Output must remain stable while stalled.
  //--------------------------------------------------------------------------

  property p_output_stable_when_stalled;

    @(posedge clk)
    disable iff (!rst_n)

    out_valid && !out_ready
    |=> out_valid && $stable(out_data);

  endproperty

  assert property (p_output_stable_when_stalled)
    else $error(
      "TLC FIFO: output changed while stalled"
    );


  //--------------------------------------------------------------------------
  // Empty FIFO must not assert output valid.
  //--------------------------------------------------------------------------

  property p_empty_no_valid;

    @(posedge clk)
    disable iff (!rst_n)

    empty |-> !out_valid;

  endproperty

  assert property (p_empty_no_valid)
    else $error(
      "TLC FIFO: empty FIFO has valid output"
    );


  //--------------------------------------------------------------------------
  // Full FIFO must not accept data unless simultaneous dequeue is occurring
  // and full bypass is enabled.
  //--------------------------------------------------------------------------

  property p_full_ready_condition;

    @(posedge clk)
    disable iff (!rst_n)

    full && in_ready
    |-> (ALLOW_FULL_BYPASS && out_valid && out_ready);

  endproperty

  assert property (p_full_ready_condition)
    else $error(
      "TLC FIFO: illegal READY while full"
    );


  //--------------------------------------------------------------------------
  // Reset clears FIFO.
  //--------------------------------------------------------------------------

  property p_reset_clean;

    @(posedge clk)

    !rst_n
    |-> (!out_valid &&
         empty &&
         !full &&
         (count == 0));

  endproperty

  assert property (p_reset_clean)
    else $error(
      "TLC FIFO: reset state is not clean"
    );

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (DATA_W == 0) begin
      $error("TLC FIFO: DATA_W must be > 0");
    end

    if (DEPTH == 0) begin
      $error("TLC FIFO: DEPTH must be > 0");
    end

  end

endmodule