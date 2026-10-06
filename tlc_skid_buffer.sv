//==============================================================================
// tlc_skid_buffer.sv
//
// Production-grade 2-entry ready/valid skid / elastic buffer.
//
// Intended for:
//   TileLink A/B/C/D/E channel ingress/egress timing isolation.
//
// Features:
//   * Parameterized payload width
//   * 2-entry storage
//   * One transfer per cycle sustained throughput
//   * Simultaneous push/pop
//   * No combinational path from downstream ready to upstream ready
//   * Stable output while stalled
//   * Registered occupancy
//   * Reset-clean state
//   * Overflow/underflow protection
//   * Assertions
//   * Synthesis-friendly
//
// Timing behavior:
//
//             upstream                    downstream
//
//        in_valid/data                    out_valid/data
//              |                               |
//              v                               v
//        +-------------------------------------------+
//        |              TLC SKID BUFFER             |
//        |                                           |
//        |       [entry0] --> [entry1]              |
//        |                                           |
//        +-------------------------------------------+
//              ^                               ^
//              |                               |
//           in_ready                        out_ready
//
//==============================================================================

module tlc_skid_buffer #(
  parameter int unsigned DATA_W = 256,

  // Normally 2. Kept parameterized for reuse.
  parameter int unsigned DEPTH = 2
) (
  input  logic             clk,
  input  logic             rst_n,

  //--------------------------------------------------------------------------
  // Upstream interface
  //--------------------------------------------------------------------------

  input  logic [DATA_W-1:0] in_data,
  input  logic              in_valid,
  output logic              in_ready,

  //--------------------------------------------------------------------------
  // Downstream interface
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
  // Diagnostics
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

  logic [DATA_W-1:0] data_mem [0:DEPTH-1];

  logic [PTR_W-1:0] wr_ptr;
  logic [PTR_W-1:0] rd_ptr;


  //==========================================================================
  // Handshake
  //==========================================================================

  logic push;
  logic pop;

  assign push = in_valid && in_ready;
  assign pop  = out_valid && out_ready;


  //==========================================================================
  // Status
  //==========================================================================

  assign empty = (count == 0);
  assign full  = (count == DEPTH);


  //==========================================================================
  // READY generation
  //
  // IMPORTANT:
  //
  // in_ready is based ONLY on registered occupancy.
  //
  // There is therefore no combinational:
  //
  //     downstream ready
  //             |
  //             v
  //         in_ready
  //
  // path through the skid buffer.
  //
  // A full buffer will accept a new item only after a subsequent cycle in
  // which space becomes available.
  //
  // This is intentionally conservative and is useful for timing isolation.
  //==========================================================================

  always_comb begin

    in_ready = !full;

  end


  //==========================================================================
  // Output valid
  //
  // Registered occupancy drives output validity.
  //==========================================================================

  always_comb begin

    out_valid = !empty;

  end


  //==========================================================================
  // Output data
  //
  // Data is read from the current read pointer.
  //
  // Since the memory is implemented as registers for DEPTH=2, this is
  // synthesis-friendly and has predictable timing.
  //==========================================================================

  always_comb begin

    if (!empty)
      out_data = data_mem[rd_ptr];
    else
      out_data = '0;

  end


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;

    end
    else begin

      //----------------------------------------------------------------------
      // Write
      //----------------------------------------------------------------------

      if (push) begin

        data_mem[wr_ptr] <= in_data;

        if (wr_ptr == DEPTH-1)
          wr_ptr <= '0;
        else
          wr_ptr <= wr_ptr + 1'b1;

      end


      //----------------------------------------------------------------------
      // Read
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

        2'b10: begin
          count <= count + 1'b1;
        end

        2'b01: begin
          count <= count - 1'b1;
        end

        2'b11: begin
          count <= count;
        end

        default: begin
          count <= count;
        end

      endcase

    end

  end


  //==========================================================================
  // Overflow / underflow diagnostics
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

  //---------------------------------------------------------------------------
  // Count range
  //---------------------------------------------------------------------------

  property p_count_range;

    @(posedge clk)
    disable iff (!rst_n)

    count <= DEPTH;

  endproperty

  assert property (p_count_range)
    else $error(
      "TLC_SKID: count exceeded DEPTH"
    );


  //---------------------------------------------------------------------------
  // Empty/count consistency
  //---------------------------------------------------------------------------

  property p_empty_consistent;

    @(posedge clk)
    disable iff (!rst_n)

    empty == (count == 0);

  endproperty

  assert property (p_empty_consistent)
    else $error(
      "TLC_SKID: empty/count inconsistency"
    );


  //---------------------------------------------------------------------------
  // Full/count consistency
  //---------------------------------------------------------------------------

  property p_full_consistent;

    @(posedge clk)
    disable iff (!rst_n)

    full == (count == DEPTH);

  endproperty

  assert property (p_full_consistent)
    else $error(
      "TLC_SKID: full/count inconsistency"
    );


  //---------------------------------------------------------------------------
  // Output stability under backpressure.
  //---------------------------------------------------------------------------

  property p_output_stable;

    @(posedge clk)
    disable iff (!rst_n)

    out_valid && !out_ready
    |=> out_valid && $stable(out_data);

  endproperty

  assert property (p_output_stable)
    else $error(
      "TLC_SKID: output changed while stalled"
    );


  //---------------------------------------------------------------------------
  // VALID must remain asserted while stalled.
  //---------------------------------------------------------------------------

  property p_valid_stable;

    @(posedge clk)
    disable iff (!rst_n)

    out_valid && !out_ready
    |=> out_valid;

  endproperty

  assert property (p_valid_stable)
    else $error(
      "TLC_SKID: VALID dropped while stalled"
    );


  //---------------------------------------------------------------------------
  // Cannot push when full.
  //---------------------------------------------------------------------------

  property p_no_push_when_full;

    @(posedge clk)
    disable iff (!rst_n)

    full |-> !push;

  endproperty

  assert property (p_no_push_when_full)
    else $error(
      "TLC_SKID: push occurred while full"
    );


  //---------------------------------------------------------------------------
  // Cannot pop when empty.
  //---------------------------------------------------------------------------

  property p_no_pop_when_empty;

    @(posedge clk)
    disable iff (!rst_n)

    empty |-> !pop;

  endproperty

  assert property (p_no_pop_when_empty)
    else $error(
      "TLC_SKID: pop occurred while empty"
    );


  //---------------------------------------------------------------------------
  // Reset-clean.
  //---------------------------------------------------------------------------

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
      "TLC_SKID: reset state not clean"
    );


  //---------------------------------------------------------------------------
  // No unknown handshake signals.
  //---------------------------------------------------------------------------

  assert property (
    @(posedge clk)
    !$isunknown({
      in_valid,
      in_ready,
      out_valid,
      out_ready
    })
  )
  else $error(
    "TLC_SKID: X/Z on ready/valid"
  );


`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (DATA_W == 0) begin
      $error(
        "TLC_SKID: DATA_W must be greater than zero"
      );
    end

    if (DEPTH < 2) begin
      $warning(
        "TLC_SKID: DEPTH < 2; this is no longer a true 2-entry skid buffer"
      );
    end

  end

endmodule