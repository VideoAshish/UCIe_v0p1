//==============================================================================
// tlc_e_channel.sv
//
// Production-oriented TileLink E-channel transport.
//
// Direction:
//
//                         Client
//                           |
//                           | E
//                           v
//                         Manager
//
// Supported E operation:
//
//   GrantAck
//
// Features:
//
//   * Parameterized SINK_W
//   * Independent ready/valid handshake
//   * 2-entry skid buffering
//   * Sink-ID preservation
//   * Sink-ID validation
//   * Reset-clean state
//   * Overflow / underflow diagnostics
//   * SVA assertions
//   * No combinational ready -> valid path
//   * Synthesis-friendly
//
// IMPORTANT:
//
//   This module transports GrantAck.
//
//   It does NOT itself decide whether a sink ID is currently allocated.
//
//   Sink allocation / ownership / freeing belongs to:
//
//       tlc_sink_table.sv
//
//   The normal lifecycle is:
//
//       Acquire
//          |
//          v
//       Grant / GrantData
//          |
//          v
//       client accepts Grant
//          |
//          v
//       GrantAck(sink)
//          |
//          v
//       tlc_e_channel
//          |
//          v
//       tlc_sink_table.free(sink)
//
//==============================================================================

module tlc_e_channel #(
  parameter int unsigned SINK_W = 8,

  parameter int unsigned NUM_SINKS =
      (1 << SINK_W),

  parameter bit ENABLE_CHECKS     = 1'b1,
  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // CLIENT-SIDE INPUT
  //
  // Client -> E channel
  //==========================================================================

  input logic                   in_valid,
  output logic                  in_ready,

  input logic [SINK_W-1:0]      in_sink,


  //==========================================================================
  // MANAGER-SIDE OUTPUT
  //
  // E channel -> Manager
  //==========================================================================

  output logic                   out_valid,
  input logic                    out_ready,

  output logic [SINK_W-1:0]      out_sink,


  //==========================================================================
  // Diagnostics
  //==========================================================================

  output logic                   protocol_error,
  output logic                   bad_sink,

  output logic                   overflow,
  output logic                   underflow,


  //==========================================================================
  // Handshake indicators
  //==========================================================================

  output logic                   in_fire,
  output logic                   out_fire
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned SKID_DEPTH = 2;

  localparam int unsigned PAYLOAD_W =
      SINK_W;


  //==========================================================================
  // E-channel payload
  //
  // E contains only sink.
  //==========================================================================

  typedef struct packed {

    logic [SINK_W-1:0] sink;

  } e_payload_t;


  e_payload_t in_payload;
  e_payload_t out_payload;


  assign in_payload.sink = in_sink;


  //==========================================================================
  // Skid buffer
  //==========================================================================

  logic                   skid_in_valid;
  logic                   skid_in_ready;
  logic [PAYLOAD_W-1:0]   skid_in_data;

  logic                   skid_out_valid;
  logic                   skid_out_ready;
  logic [PAYLOAD_W-1:0]   skid_out_data;

  logic                   skid_full;
  logic                   skid_empty;

  logic [$clog2(SKID_DEPTH+1)-1:0]
      skid_count;


  //==========================================================================
  // Input
  //==========================================================================

  assign skid_in_data =
      in_payload;

  assign skid_in_valid =
      in_valid;

  assign in_ready =
      skid_in_ready;

  assign in_fire =
      in_valid &&
      in_ready;


  //==========================================================================
  // Output
  //==========================================================================

  assign skid_out_ready =
      out_ready;

  assign out_valid =
      skid_out_valid;

  assign out_fire =
      out_valid &&
      out_ready;


  //==========================================================================
  // Output payload
  //==========================================================================

  assign out_payload =
      e_payload_t'(skid_out_data);

  assign out_sink =
      out_payload.sink;


  //==========================================================================
  // E-channel skid buffer
  //==========================================================================

  tlc_skid_buffer #(
    .DATA_W (PAYLOAD_W),
    .DEPTH  (SKID_DEPTH)
  ) u_e_skid_buffer (
    .clk        (clk),
    .rst_n      (rst_n),

    .in_data    (skid_in_data),
    .in_valid   (skid_in_valid),
    .in_ready   (skid_in_ready),

    .out_data   (skid_out_data),
    .out_valid  (skid_out_valid),
    .out_ready  (skid_out_ready),

    .full       (skid_full),
    .empty      (skid_empty),

    .count      (skid_count),

    .overflow   (overflow),
    .underflow  (underflow)
  );


  //==========================================================================
  // Sink validation
  //
  // This is only a structural range check.
  //
  // Whether the sink is CURRENTLY allocated and whether it corresponds to
  // the outstanding Grant is checked by tlc_sink_table.sv.
  //==========================================================================

  logic sink_valid;

  always_comb begin

    if (NUM_SINKS >= (1 << SINK_W))
      sink_valid = 1'b1;
    else
      sink_valid = (in_sink < NUM_SINKS);

  end


  assign bad_sink =
      in_valid &&
      !sink_valid;


  //==========================================================================
  // Aggregate protocol error
  //==========================================================================

  assign protocol_error =
      bad_sink;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_E_ASSERTIONS

      //======================================================================
      // Input stability while stalled
      //======================================================================

      property p_e_input_stable;

        @(posedge clk)
        disable iff (!rst_n)

        in_valid && !in_ready
        |=> in_valid &&
            $stable(in_sink);

      endproperty

      assert property (p_e_input_stable)
        else $error(
          "TLC E: sink changed while input was stalled"
        );


      //======================================================================
      // Output stability while stalled
      //======================================================================

      property p_e_output_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid &&
            $stable(out_sink);

      endproperty

      assert property (p_e_output_stable)
        else $error(
          "TLC E: sink changed while output was stalled"
        );


      //======================================================================
      // VALID stability under backpressure
      //======================================================================

      property p_e_valid_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid;

      endproperty

      assert property (p_e_valid_stable)
        else $error(
          "TLC E: VALID dropped during backpressure"
        );


      //======================================================================
      // Sink must be structurally valid when accepted
      //======================================================================

      property p_e_sink_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> sink_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_e_sink_legal)
          else $error(
            "TLC E: illegal sink ID accepted"
          );

      end


      //======================================================================
      // Handshake signals must not be X/Z
      //======================================================================

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
        "TLC E: X/Z on ready/valid"
      );


      //======================================================================
      // Sink must not contain X/Z on accepted transaction.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> !$isunknown(in_sink)
      )
      else $error(
        "TLC E: GrantAck contains X/Z sink ID"
      );


      //======================================================================
      // Reset-clean
      //======================================================================

      property p_e_reset_clean;

        @(posedge clk)
        !rst_n |-> !out_valid;

      endproperty

      assert property (p_e_reset_clean)
        else $error(
          "TLC E: output valid during reset"
        );


      //======================================================================
      // Sink must remain stable while GrantAck is stalled.
      //======================================================================

      property p_grantack_sink_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid &&
            $stable(out_sink);

      endproperty

      assert property (p_grantack_sink_stable)
        else $error(
          "TLC E: GrantAck sink changed while stalled"
        );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (SINK_W == 0)
      $error(
        "TLC E: SINK_W must be > 0"
      );

  end

endmodule