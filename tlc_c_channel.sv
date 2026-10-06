//==============================================================================
// tlc_c_channel.sv
//
// Production-grade TileLink C-channel transport.
//
// Direction:
//
//                         Client
//                           |
//                           | C
//                           v
//                    +--------------+
//                    | TLC C CHANNEL|
//                    +--------------+
//                           |
//                           v
//                         Manager
//
// Supported C operations:
//
//   ProbeAck
//   ProbeAckData
//   Release
//   ReleaseData
//
// Features:
//
//   * Fully parameterized ADDR/DATA/SOURCE/SIZE widths
//   * Independent ready/valid
//   * 2-entry skid buffer
//   * Complete payload preservation
//   * ProbeAck / ProbeAckData support
//   * Release / ReleaseData support
//   * Dirty-data indication
//   * Partial-write byte-mask support
//   * Opcode validation
//   * Alignment validation
//   * Size validation
//   * Source-ID validation
//   * Cache-line alignment validation
//   * Corrupt-data propagation
//   * No combinational ready -> valid path
//   * Reset-clean operation
//   * Overflow/underflow diagnostics
//   * SVA protocol checks
//   * Synthesis-friendly
//
// IMPORTANT:
//
//   Coherence state transitions are NOT performed here.
//
//   This module is the transport boundary. The following modules consume
//   the accepted C transaction:
//
//       tlc_probe_tracker.sv
//       tlc_directory.sv
//       tlc_release_engine.sv
//
//==============================================================================

module tlc_c_channel #(
  parameter int unsigned ADDR_W = 48,
  parameter int unsigned DATA_W = 256,
  parameter int unsigned SOURCE_W = 8,

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 : $clog2((DATA_W / 8) + 1),

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter bit ENABLE_CHECKS = 1'b1,

  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // CLIENT-SIDE INPUT
  //
  // Client -> C-channel
  //==========================================================================

  input logic                    in_valid,
  output logic                   in_ready,

  input logic [2:0]              in_opcode,
  input logic [2:0]              in_param,
  input logic [SIZE_W-1:0]       in_size,

  input logic [SOURCE_W-1:0]     in_source,

  input logic [ADDR_W-1:0]       in_address,

  input logic [DATA_W-1:0]       in_data,

  input logic [(DATA_W/8)-1:0]   in_mask,

  input logic                    in_corrupt,


  //==========================================================================
  // MANAGER-SIDE OUTPUT
  //
  // C-channel -> Manager
  //==========================================================================

  output logic                   out_valid,
  input logic                    out_ready,

  output logic [2:0]             out_opcode,
  output logic [2:0]             out_param,
  output logic [SIZE_W-1:0]      out_size,

  output logic [SOURCE_W-1:0]    out_source,

  output logic [ADDR_W-1:0]      out_address,

  output logic [DATA_W-1:0]      out_data,

  output logic [(DATA_W/8)-1:0]  out_mask,

  output logic                   out_corrupt,


  //==========================================================================
  // Transaction classification
  //==========================================================================

  output logic                   is_probe_ack,
  output logic                   is_probe_ack_data,
  output logic                   is_release,
  output logic                   is_release_data,

  output logic                   has_data,
  output logic                   has_dirty_data,


  //==========================================================================
  // Diagnostics
  //==========================================================================

  output logic                   protocol_error,
  output logic                   illegal_opcode,
  output logic                   bad_alignment,
  output logic                   bad_size,
  output logic                   bad_source,
  output logic                   bad_mask,

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

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned SKID_DEPTH = 2;

  localparam int unsigned PAYLOAD_W =
      3 +                  // opcode
      3 +                  // param
      SIZE_W +
      SOURCE_W +
      ADDR_W +
      DATA_W +
      BYTE_W +
      1;                   // corrupt


  //==========================================================================
  // C-channel opcodes
  //
  // TileLink C opcode encoding.
  //==========================================================================

  localparam logic [2:0] OP_PROBEACK =
      3'd4;

  localparam logic [2:0] OP_PROBEACKDATA =
      3'd5;

  localparam logic [2:0] OP_RELEASE =
      3'd6;

  localparam logic [2:0] OP_RELEASEDATA =
      3'd7;


  //==========================================================================
  // Payload
  //==========================================================================

  typedef struct packed {

    logic [2:0]             opcode;
    logic [2:0]             param;

    logic [SIZE_W-1:0]      size;

    logic [SOURCE_W-1:0]    source;

    logic [ADDR_W-1:0]      address;

    logic [DATA_W-1:0]      data;

    logic [BYTE_W-1:0]      mask;

    logic                   corrupt;

  } c_payload_t;


  c_payload_t in_payload;
  c_payload_t out_payload;


  //==========================================================================
  // Input payload
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


  assign skid_in_data = in_payload;

  assign skid_in_valid = in_valid;

  assign in_ready = skid_in_ready;

  assign in_fire =
      in_valid && in_ready;


  assign skid_out_ready = out_ready;

  assign out_valid = skid_out_valid;

  assign out_fire =
      out_valid && out_ready;


  //==========================================================================
  // Unpack output
  //==========================================================================

  assign out_payload =
      c_payload_t'(skid_out_data);

  assign out_opcode =
      out_payload.opcode;

  assign out_param =
      out_payload.param;

  assign out_size =
      out_payload.size;

  assign out_source =
      out_payload.source;

  assign out_address =
      out_payload.address;

  assign out_data =
      out_payload.data;

  assign out_mask =
      out_payload.mask;

  assign out_corrupt =
      out_payload.corrupt;


  //==========================================================================
  // C-channel skid buffer
  //==========================================================================

  tlc_skid_buffer #(
    .DATA_W (PAYLOAD_W),
    .DEPTH  (SKID_DEPTH)
  ) u_c_skid_buffer (
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
  // Opcode classification
  //==========================================================================

  assign is_probe_ack =
      (in_opcode == OP_PROBEACK);

  assign is_probe_ack_data =
      (in_opcode == OP_PROBEACKDATA);

  assign is_release =
      (in_opcode == OP_RELEASE);

  assign is_release_data =
      (in_opcode == OP_RELEASEDATA);


  assign has_data =
      is_probe_ack_data ||
      is_release_data;


  //--------------------------------------------------------------------------
  // For a coherence manager, ProbeAckData and ReleaseData represent the
  // data-bearing responses from a client.
  //
  // Whether the data is actually "dirty" is determined by the coherence
  // state/transaction context. This module therefore exposes a conservative
  // data-bearing indication rather than making a directory-state decision.
  //--------------------------------------------------------------------------
  assign has_dirty_data =
      is_probe_ack_data ||
      is_release_data;


  //==========================================================================
  // Opcode validation
  //==========================================================================

  logic opcode_valid;

  always_comb begin

    case (in_opcode)

      OP_PROBEACK,
      OP_PROBEACKDATA,
      OP_RELEASE,
      OP_RELEASEDATA:

        opcode_valid = 1'b1;

      default:

        opcode_valid = 1'b0;

    endcase

  end


  assign illegal_opcode =
      in_valid &&
      !opcode_valid;


  //==========================================================================
  // Size validation
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
      in_valid &&
      !size_valid;


  //==========================================================================
  // Natural alignment validation
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
      in_valid &&
      !alignment_valid;


  //==========================================================================
  // Cache-line alignment
  //
  // Release / ReleaseData normally identify a cache block.
  // ProbeAck / ProbeAckData are associated with a previously issued Probe.
  //==========================================================================

  logic cacheline_alignment_valid;

  always_comb begin

    cacheline_alignment_valid = 1'b1;

    if (is_release || is_release_data) begin

      if ((in_address % CACHE_LINE_BYTES) != 0)
        cacheline_alignment_valid = 1'b0;

    end

  end


  //==========================================================================
  // Source validation
  //==========================================================================

  logic source_valid;

  always_comb begin

    if (NUM_SOURCES >= (1 << SOURCE_W))
      source_valid = 1'b1;
    else
      source_valid = (in_source < NUM_SOURCES);

  end


  assign bad_source =
      in_valid &&
      !source_valid;


  //==========================================================================
  // Data-mask validation
  //
  // ProbeAck / Release without data:
  //     mask is ignored.
  //
  // ProbeAckData / ReleaseData:
  //     mask identifies valid bytes.
  //
  // A zero mask is allowed structurally because the transaction context
  // determines whether a data-bearing response is semantically legal.
  //==========================================================================

  logic mask_valid;

  always_comb begin

    mask_valid = 1'b1;

    if (has_data) begin

      if (^in_mask === 1'bx)
        mask_valid = 1'b0;

    end

  end


  assign bad_mask =
      in_valid &&
      !mask_valid;


  //==========================================================================
  // Aggregate error
  //==========================================================================

  assign protocol_error =
      illegal_opcode ||
      bad_alignment ||
      bad_size ||
      bad_source ||
      bad_mask ||
      !cacheline_alignment_valid;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_C_ASSERTIONS

      //----------------------------------------------------------------------  
      // Input stability under backpressure
      //----------------------------------------------------------------------

      property p_c_input_stable;

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

      assert property (p_c_input_stable)
        else $error(
          "TLC C: input payload changed while stalled"
        );


      //----------------------------------------------------------------------  
      // Output stability under backpressure
      //----------------------------------------------------------------------

      property p_c_output_stable;

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

      assert property (p_c_output_stable)
        else $error(
          "TLC C: output payload changed while stalled"
        );


      //----------------------------------------------------------------------  
      // VALID cannot disappear during stall
      //----------------------------------------------------------------------

      property p_c_valid_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid;

      endproperty

      assert property (p_c_valid_stable)
        else $error(
          "TLC C: VALID dropped during backpressure"
        );


      //----------------------------------------------------------------------  
      // Only legal C opcodes can be accepted.
      //----------------------------------------------------------------------

      property p_c_opcode_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> opcode_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_c_opcode_legal)
          else $error(
            "TLC C: illegal C-channel opcode accepted"
          );

      end


      //----------------------------------------------------------------------  
      // Source must be legal.
      //----------------------------------------------------------------------

      property p_c_source_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> source_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_c_source_legal)
          else $error(
            "TLC C: invalid source ID"
          );

      end


      //----------------------------------------------------------------------  
      // Size must be legal.
      //----------------------------------------------------------------------

      property p_c_size_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> size_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_c_size_legal)
          else $error(
            "TLC C: invalid transfer size"
          );

      end


      //----------------------------------------------------------------------  
      // Natural alignment.
      //----------------------------------------------------------------------

      property p_c_alignment_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> alignment_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_c_alignment_legal)
          else $error(
            "TLC C: misaligned C transaction"
          );

      end


      //----------------------------------------------------------------------  
      // Release must be cache-line aligned.
      //----------------------------------------------------------------------

      property p_release_cacheline_alignment;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire &&
        ((in_opcode == OP_RELEASE) ||
         (in_opcode == OP_RELEASEDATA))
        |-> cacheline_alignment_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_release_cacheline_alignment)
          else $error(
            "TLC C: Release address is not cache-line aligned"
          );

      end


      //----------------------------------------------------------------------  
      // Data-bearing operations must contain known data/mask.
      //----------------------------------------------------------------------

      property p_data_response_known;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire &&
        has_data
        |-> !$isunknown({
          in_data,
          in_mask
        });

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_data_response_known)
          else $error(
            "TLC C: data-bearing response contains X/Z"
          );

      end


      //----------------------------------------------------------------------  
      // Handshake signals must not be X/Z.
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
        "TLC C: X/Z on ready/valid"
      );


      //----------------------------------------------------------------------  
      // Reset-clean.
      //----------------------------------------------------------------------

      property p_c_reset_clean;

        @(posedge clk)
        !rst_n |-> !out_valid;

      endproperty

      assert property (p_c_reset_clean)
        else $error(
          "TLC C: output valid during reset"
        );


      //----------------------------------------------------------------------  
      // ProbeAck must remain ProbeAck while stalled.
      //----------------------------------------------------------------------

      property p_probeack_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid &&
        !out_ready &&
        (out_opcode == OP_PROBEACK)
        |=> out_valid &&
            (out_opcode == OP_PROBEACK);

      endproperty

      assert property (p_probeack_stable)
        else $error(
          "TLC C: ProbeAck opcode changed while stalled"
        );


      //----------------------------------------------------------------------  
      // ReleaseData must remain ReleaseData while stalled.
      //----------------------------------------------------------------------

      property p_releasedata_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid &&
        !out_ready &&
        (out_opcode == OP_RELEASEDATA)
        |=> out_valid &&
            (out_opcode == OP_RELEASEDATA);

      endproperty

      assert property (p_releasedata_stable)
        else $error(
          "TLC C: ReleaseData opcode changed while stalled"
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
        "TLC C: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC C: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC C: DATA_W must be a multiple of 8"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC C: SOURCE_W must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC C: CACHE_LINE_BYTES must be > 0"
      );

    if ((CACHE_LINE_BYTES &
         (CACHE_LINE_BYTES - 1)) != 0)
      $error(
        "TLC C: CACHE_LINE_BYTES must be power-of-two"
      );

  end

endmodule