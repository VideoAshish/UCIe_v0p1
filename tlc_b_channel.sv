//==============================================================================
// tlc_b_channel.sv
//
// Production-grade TileLink B-channel transport.
//
// Direction:
//                    Manager
//                       |
//                       | B
//                       v
//                    Client
//
// B-channel operations:
//
//   Probe
//
// This module provides:
//
//   * Fully parameterized address/source/size/data widths
//   * Independent ready/valid handshake
//   * 2-entry skid buffering
//   * Stable payload under backpressure
//   * Opcode validation
//   * Alignment checking
//   * Size checking
//   * Source-ID validation
//   * Reset-clean state
//   * Overflow/underflow diagnostics
//   * Assertion support
//   * No combinational ready -> valid path through the buffer
//   * Synthesis-friendly implementation
//
// IMPORTANT:
//   B-channel routing / probe generation is intentionally outside this
//   module. This module is only the transport/validation boundary.
//
//==============================================================================

module tlc_b_channel #(
  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 : $clog2((DATA_W / 8) + 1),

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter bit ENABLE_CHECKS     = 1'b1,
  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // MANAGER-SIDE INPUT
  //
  // Manager -> B channel
  //==========================================================================

  input  logic                   in_valid,
  output logic                   in_ready,

  input  logic [2:0]              in_opcode,
  input  logic [2:0]              in_param,
  input  logic [SIZE_W-1:0]       in_size,

  input  logic [SOURCE_W-1:0]     in_source,

  input  logic [ADDR_W-1:0]       in_address,

  input  logic [DATA_W-1:0]       in_data,

  input  logic [(DATA_W/8)-1:0]   in_mask,

  input  logic                   in_corrupt,


  //==========================================================================
  // CLIENT-SIDE OUTPUT
  //
  // B channel -> Client
  //==========================================================================

  output logic                   out_valid,
  input  logic                   out_ready,

  output logic [2:0]              out_opcode,
  output logic [2:0]              out_param,
  output logic [SIZE_W-1:0]       out_size,

  output logic [SOURCE_W-1:0]     out_source,

  output logic [ADDR_W-1:0]       out_address,

  output logic [DATA_W-1:0]       out_data,

  output logic [(DATA_W/8)-1:0]   out_mask,

  output logic                   out_corrupt,


  //==========================================================================
  // Diagnostics
  //==========================================================================

  output logic                   protocol_error,
  output logic                   illegal_opcode,
  output logic                   bad_alignment,
  output logic                   bad_size,
  output logic                   bad_source,

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

  localparam int unsigned BYTE_W = DATA_W / 8;
  localparam int unsigned SKID_DEPTH = 2;

  localparam int unsigned PAYLOAD_W =
      3 +                 // opcode
      3 +                 // param
      SIZE_W +
      SOURCE_W +
      ADDR_W +
      DATA_W +
      BYTE_W +
      1;                  // corrupt


  //==========================================================================
  // B-channel opcode
  //
  // TileLink B Probe.
  //==========================================================================

  localparam logic [2:0] OP_PROBE = 3'd6;


  //==========================================================================
  // Payload
  //==========================================================================

  typedef struct packed {

    logic [2:0]            opcode;
    logic [2:0]            param;
    logic [SIZE_W-1:0]     size;
    logic [SOURCE_W-1:0]   source;
    logic [ADDR_W-1:0]     address;
    logic [DATA_W-1:0]     data;
    logic [BYTE_W-1:0]     mask;
    logic                  corrupt;

  } b_payload_t;


  b_payload_t in_payload;
  b_payload_t out_payload;


  //==========================================================================
  // Input payload construction
  //==========================================================================

  assign in_payload = '{
    opcode  : in_opcode,
    param   : in_param,
    size    : in_size,
    source  : in_source,
    address : in_address,
    data    : in_data,
    mask    : in_mask,
    corrupt : in_corrupt
  };


  //==========================================================================
  // Skid-buffer interface
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


  assign skid_in_data = in_payload;


  //--------------------------------------------------------------------------
  // Do not silently discard an illegal B transaction.
  //
  // The probe is still accepted so the protocol monitor / error handling
  // machinery can observe it.
  //--------------------------------------------------------------------------

  assign skid_in_valid = in_valid;

  assign in_ready = skid_in_ready;

  assign in_fire = in_valid && in_ready;


  assign skid_out_ready = out_ready;

  assign out_valid = skid_out_valid;

  assign out_fire = out_valid && out_ready;


  //==========================================================================
  // Unpack output
  //==========================================================================

  assign out_payload = b_payload_t'(skid_out_data);

  assign out_opcode  = out_payload.opcode;
  assign out_param   = out_payload.param;
  assign out_size    = out_payload.size;
  assign out_source  = out_payload.source;
  assign out_address = out_payload.address;
  assign out_data    = out_payload.data;
  assign out_mask    = out_payload.mask;
  assign out_corrupt = out_payload.corrupt;


  //==========================================================================
  // B-channel skid buffer
  //==========================================================================

  tlc_skid_buffer #(
    .DATA_W (PAYLOAD_W),
    .DEPTH  (SKID_DEPTH)
  ) u_b_skid_buffer (
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
  // Opcode legality
  //==========================================================================

  logic opcode_valid;

  always_comb begin

    case (in_opcode)

      OP_PROBE:
        opcode_valid = 1'b1;

      default:
        opcode_valid = 1'b0;

    endcase

  end


  assign illegal_opcode =
      in_valid && !opcode_valid;


  //==========================================================================
  // Size validation
  //
  // Probe size must represent a legal transfer/cache-block granularity.
  //==========================================================================

  logic size_valid;

  always_comb begin

    size_valid = 1'b1;

    if (in_size >= SIZE_W'(32)) begin

      size_valid = 1'b0;

    end
    else if ((64'h1 << in_size) > BYTE_W) begin

      size_valid = 1'b0;

    end

  end


  assign bad_size =
      in_valid && !size_valid;


  //==========================================================================
  // Alignment checking
  //
  // Probe requests are expected to be aligned to their transfer size.
  //==========================================================================

  logic alignment_valid;

  always_comb begin

    alignment_valid = 1'b1;

    if (size_valid && (in_size != 0)) begin

      for (int unsigned i = 0;
           i < ADDR_W;
           i++) begin

        if (i < in_size) begin

          if (in_address[i])
            alignment_valid = 1'b0;

        end

      end

    end

  end


  assign bad_alignment =
      in_valid && !alignment_valid;


  //==========================================================================
  // Source-ID validation
  //==========================================================================

  logic source_valid;

  always_comb begin

    if (NUM_SOURCES >= (1 << SOURCE_W))
      source_valid = 1'b1;
    else
      source_valid = (in_source < NUM_SOURCES);

  end


  assign bad_source =
      in_valid && !source_valid;


  //==========================================================================
  // Probe cache-line alignment
  //
  // In the coherence implementation we expect Probe addresses to identify
  // the beginning of a cache block.
  //==========================================================================

  logic probe_alignment_valid;

  always_comb begin

    probe_alignment_valid = 1'b1;

    if (in_opcode == OP_PROBE) begin

      if ((in_address % CACHE_LINE_BYTES) != 0)
        probe_alignment_valid = 1'b0;

    end

  end


  //==========================================================================
  // Aggregate protocol error
  //==========================================================================

  assign protocol_error =
      illegal_opcode ||
      bad_alignment ||
      bad_size ||
      bad_source ||
      !probe_alignment_valid;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_B_ASSERTIONS

      //----------------------------------------------------------------------  
      // Input stability while stalled
      //----------------------------------------------------------------------

      property p_b_input_stable;

        @(posedge clk)
        disable iff (!rst_n)

        in_valid && !in_ready
        |=> in_valid &&
            $stable(in_opcode) &&
            $stable(in_param) &&
            $stable(in_size) &&
            $stable(in_source) &&
            $stable(in_address) &&
            $stable(in_data) &&
            $stable(in_mask) &&
            $stable(in_corrupt);

      endproperty

      assert property (p_b_input_stable)
        else $error(
          "TLC B: input payload changed while stalled"
        );


      //----------------------------------------------------------------------  
      // Output stability while stalled
      //----------------------------------------------------------------------

      property p_b_output_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid &&
            $stable(out_opcode) &&
            $stable(out_param) &&
            $stable(out_size) &&
            $stable(out_source) &&
            $stable(out_address) &&
            $stable(out_data) &&
            $stable(out_mask) &&
            $stable(out_corrupt);

      endproperty

      assert property (p_b_output_stable)
        else $error(
          "TLC B: output payload changed while stalled"
        );


      //----------------------------------------------------------------------  
      // VALID cannot disappear while stalled
      //----------------------------------------------------------------------

      property p_b_valid_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid;

      endproperty

      assert property (p_b_valid_stable)
        else $error(
          "TLC B: VALID dropped during backpressure"
        );


      //----------------------------------------------------------------------  
      // Only Probe is legal on this B-channel implementation.
      //----------------------------------------------------------------------

      property p_b_opcode_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> (in_opcode == OP_PROBE);

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_b_opcode_legal)
          else $error(
            "TLC B: unsupported B-channel opcode"
          );

      end


      //----------------------------------------------------------------------  
      // Probe address must be cache-line aligned.
      //----------------------------------------------------------------------

      property p_b_probe_alignment;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire &&
        (in_opcode == OP_PROBE)
        |-> probe_alignment_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_b_probe_alignment)
          else $error(
            "TLC B: Probe address is not cache-line aligned"
          );

      end


      //----------------------------------------------------------------------  
      // Size must be legal.
      //----------------------------------------------------------------------

      property p_b_size_valid;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> size_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_b_size_valid)
          else $error(
            "TLC B: invalid Probe size"
          );

      end


      //----------------------------------------------------------------------  
      // Source ID must be legal.
      //----------------------------------------------------------------------

      property p_b_source_valid;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> source_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_b_source_valid)
          else $error(
            "TLC B: invalid Probe source ID"
          );

      end


      //----------------------------------------------------------------------  
      // No X/Z on handshake signals.
      //----------------------------------------------------------------------

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
        "TLC B: X/Z on ready/valid"
      );


      //----------------------------------------------------------------------  
      // Reset-clean
      //----------------------------------------------------------------------

      property p_b_reset_clean;

        @(posedge clk)
        !rst_n |-> !out_valid;

      endproperty

      assert property (p_b_reset_clean)
        else $error(
          "TLC B: output valid during reset"
        );


      //----------------------------------------------------------------------  
      // A Probe must remain a Probe while stalled.
      //----------------------------------------------------------------------

      property p_b_probe_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid &&
        !out_ready &&
        (out_opcode == OP_PROBE)
        |=> out_valid &&
            (out_opcode == OP_PROBE);

      endproperty

      assert property (p_b_probe_stable)
        else $error(
          "TLC B: Probe opcode changed while stalled"
        );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC B: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC B: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC B: DATA_W must be a multiple of 8"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC B: SOURCE_W must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC B: CACHE_LINE_BYTES must be > 0"
      );

    if ((CACHE_LINE_BYTES &
         (CACHE_LINE_BYTES - 1)) != 0)
      $error(
        "TLC B: CACHE_LINE_BYTES must be power-of-two"
      );

  end

endmodule