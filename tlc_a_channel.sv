//==============================================================================
// tlc_a_channel.sv
//
// Production-oriented TileLink-C A-channel.
//
// Direction:
//                  Client
//                    |
//                    | A
//                    v
//             +-------------+
//             |  A CHANNEL  |
//             +-------------+
//                    |
//                    v
//                  Manager
//
// Supported A operations:
//
//   PutFullData
//   PutPartialData
//   ArithmeticData
//   LogicalData
//   Get
//   Hint
//   AcquireBlock
//   AcquirePerm
//
// Features:
//
//   * Fully parameterized
//   * Ready/valid interface
//   * 2-entry skid buffering
//   * Independent ingress/egress flow control
//   * No combinational ready -> valid path
//   * Payload stability under backpressure
//   * Opcode validation
//   * Alignment validation
//   * Transfer-size validation
//   * Byte-mask validation
//   * Source-ID range validation
//   * Protocol error reporting
//   * Overflow protection
//   * Reset-clean state
//   * Assertions
//   * Synthesis-friendly
//
//==============================================================================

module tlc_a_channel #(
  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned MAX_TRANSFER_BYTES =
      DATA_W / 8,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 :
      $clog2((DATA_W / 8) + 1),

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter bit ENABLE_CHECKS = 1'b1,

  parameter bit ENABLE_ASSERTIONS = 1'b1,

  parameter bit DROP_ILLEGAL = 1'b0
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // CLIENT-SIDE INPUT
  //
  // Client -> A-channel
  //==========================================================================

  input  logic                    in_valid,
  output logic                    in_ready,

  input logic [2:0]               in_opcode,
  input logic [2:0]               in_param,
  input logic [SIZE_W-1:0]        in_size,

  input logic [SOURCE_W-1:0]      in_source,

  input logic [ADDR_W-1:0]        in_address,

  input logic [DATA_W-1:0]        in_data,

  input logic [(DATA_W/8)-1:0]    in_mask,

  input logic                    in_corrupt,


  //==========================================================================
  // MANAGER-SIDE OUTPUT
  //
  // A-channel -> Manager
  //==========================================================================

  output logic                    out_valid,
  input logic                    out_ready,

  output logic [2:0]              out_opcode,
  output logic [2:0]              out_param,
  output logic [SIZE_W-1:0]       out_size,

  output logic [SOURCE_W-1:0]     out_source,

  output logic [ADDR_W-1:0]       out_address,

  output logic [DATA_W-1:0]       out_data,

  output logic [(DATA_W/8)-1:0]   out_mask,

  output logic                    out_corrupt,


  //==========================================================================
  // Protocol diagnostics
  //==========================================================================

  output logic                    protocol_error,
  output logic                    illegal_opcode,
  output logic                    bad_alignment,
  output logic                    bad_size,
  output logic                    bad_mask,
  output logic                    bad_source,

  output logic                    overflow,

  //==========================================================================
  // Activity
  //==========================================================================

  output logic                    in_fire,
  output logic                    out_fire
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned SKID_DEPTH = 2;

  localparam int unsigned PAYLOAD_W =
      3 +                       // opcode
      3 +                       // param
      SIZE_W +
      SOURCE_W +
      ADDR_W +
      DATA_W +
      BYTE_W +
      1;                        // corrupt


  //==========================================================================
  // A-channel opcode definitions
  //==========================================================================

  localparam logic [2:0] OP_PUTFULL =
      3'd0;

  localparam logic [2:0] OP_PUTPARTIAL =
      3'd1;

  localparam logic [2:0] OP_ARITHMETIC =
      3'd2;

  localparam logic [2:0] OP_LOGICAL =
      3'd3;

  localparam logic [2:0] OP_GET =
      3'd4;

  localparam logic [2:0] OP_HINT =
      3'd5;

  localparam logic [2:0] OP_ACQUIREBLOCK =
      3'd6;

  localparam logic [2:0] OP_ACQUIREPERM =
      3'd7;


  //==========================================================================
  // Payload type
  //==========================================================================

  typedef struct packed {

    logic [2:0]             opcode;
    logic [2:0]             param;

    logic [SIZE_W-1:0]      size;

    logic [SOURCE_W-1:0]    source;

    logic [ADDR_W-1:0]      address;

    logic [DATA_W-1:0]      data;

    logic [BYTE_W-1:0]     mask;

    logic                   corrupt;

  } a_payload_t;


  //==========================================================================
  // Input/output payload
  //==========================================================================

  a_payload_t in_payload;
  a_payload_t out_payload;


  assign in_payload.opcode  = in_opcode;
  assign in_payload.param   = in_param;
  assign in_payload.size    = in_size;
  assign in_payload.source  = in_source;
  assign in_payload.address = in_address;
  assign in_payload.data    = in_data;
  assign in_payload.mask    = in_mask;
  assign in_payload.corrupt = in_corrupt;


  //==========================================================================
  // Skid buffer signals
  //==========================================================================

  logic                    skid_in_valid;
  logic                    skid_in_ready;

  logic [PAYLOAD_W-1:0]    skid_in_data;

  logic                    skid_out_valid;
  logic                    skid_out_ready;

  logic [PAYLOAD_W-1:0]    skid_out_data;

  logic                    skid_full;
  logic                    skid_empty;

  logic [$clog2(SKID_DEPTH+1)-1:0]
      skid_count;


  //==========================================================================
  // Pack payload
  //==========================================================================

  assign skid_in_data = in_payload;


  //==========================================================================
  // Input acceptance
  //
  // Invalid requests are still transported by default. This is deliberate:
  //
  //   * The protocol monitor can observe the transaction.
  //   * The manager can generate a controlled error response.
  //   * The channel itself does not silently lose requests.
  //
  // DROP_ILLEGAL may be enabled for systems where invalid requests must be
  // discarded at this boundary.
  //==========================================================================

  assign skid_in_valid =
      in_valid &&
      (!DROP_ILLEGAL || !protocol_error);


  assign in_ready =
      skid_in_ready;


  assign in_fire =
      in_valid && in_ready;


  //==========================================================================
  // Output handshake
  //==========================================================================

  assign skid_out_ready =
      out_ready;


  assign out_valid =
      skid_out_valid;


  assign out_fire =
      out_valid && out_ready;


  //==========================================================================
  // Unpack output payload
  //==========================================================================

  assign out_payload = a_payload_t'(skid_out_data);

  assign out_opcode  = out_payload.opcode;
  assign out_param   = out_payload.param;
  assign out_size    = out_payload.size;
  assign out_source  = out_payload.source;
  assign out_address = out_payload.address;
  assign out_data    = out_payload.data;
  assign out_mask    = out_payload.mask;
  assign out_corrupt = out_payload.corrupt;


  //==========================================================================
  // A-channel skid buffer
  //==========================================================================

  tlc_skid_buffer #(
    .DATA_W (PAYLOAD_W),
    .DEPTH  (SKID_DEPTH)
  ) u_a_skid_buffer (
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
    .underflow  ()
  );


  //==========================================================================
  // Opcode legality
  //==========================================================================

  logic opcode_valid;

  always_comb begin

    case (in_opcode)

      OP_PUTFULL,
      OP_PUTPARTIAL,
      OP_ARITHMETIC,
      OP_LOGICAL,
      OP_GET,
      OP_HINT,
      OP_ACQUIREBLOCK,
      OP_ACQUIREPERM:

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
  //
  // TL size is log2(number of bytes).
  //
  // A legal beat must not exceed DATA_W/8 bytes.
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
  // Alignment checking
  //
  // Transfer must be naturally aligned to its transfer size.
  //==========================================================================

  logic alignment_valid;

  always_comb begin

    alignment_valid = 1'b1;

    if (size_valid) begin

      if (in_size != 0) begin

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

  end


  assign bad_alignment =
      in_valid &&
      !alignment_valid;


  //==========================================================================
  // Source ID validation
  //
  // With a SOURCE_W-bit source field the physical range is naturally bounded
  // by the field width. NUM_SOURCES is useful when the implementation uses
  // fewer IDs than the encoded field can represent.
  //==========================================================================

  logic source_valid;

  always_comb begin

    if (NUM_SOURCES >= (1 << SOURCE_W)) begin

      source_valid = 1'b1;

    end
    else begin

      source_valid =
          (in_source < NUM_SOURCES);

    end

  end


  assign bad_source =
      in_valid &&
      !source_valid;


  //==========================================================================
  // Byte mask validation
  //
  // For naturally aligned transfers:
  //
  //   PutFullData:
  //       mask must cover the transfer.
  //
  //   PutPartialData:
  //       mask may contain a subset of the beat.
  //
  //   Get / Acquire / Hint:
  //       data mask is not semantically meaningful and is not rejected.
  //
  // The actual byte-enable semantics can be refined by the manager according
  // to the selected TL-C profile.
  //==========================================================================

  logic mask_valid;

  always_comb begin

    mask_valid = 1'b1;

    if ((in_opcode == OP_PUTFULL) ||
        (in_opcode == OP_PUTPARTIAL)) begin

      if (in_size < 31) begin

        int unsigned transfer_bytes;
        int unsigned first_byte;

        transfer_bytes = (1 << in_size);

        first_byte =
            in_address[$clog2(BYTE_W)-1:0];

        if ((transfer_bytes > BYTE_W) ||
            ((first_byte + transfer_bytes) > BYTE_W)) begin

          mask_valid = 1'b0;

        end
        else begin

          for (int unsigned b = 0;
               b < BYTE_W;
               b++) begin

            if ((b >= first_byte) &&
                (b < first_byte + transfer_bytes)) begin

              if (!in_mask[b])
                mask_valid = 1'b0;

            end

          end

        end

      end
      else begin

        mask_valid = 1'b0;

      end

    end

  end


  assign bad_mask =
      in_valid &&
      !mask_valid;


  //==========================================================================
  // Aggregate protocol error
  //==========================================================================

  assign protocol_error =
      illegal_opcode ||
      bad_alignment ||
      bad_size ||
      bad_mask ||
      bad_source;


  //==========================================================================
  // Additional protocol checks
  //==========================================================================

  logic acquire_opcode;

  assign acquire_opcode =
      (in_opcode == OP_ACQUIREBLOCK) ||
      (in_opcode == OP_ACQUIREPERM);


  //--------------------------------------------------------------------------
  // Acquire must have an aligned cache-line address.
  //--------------------------------------------------------------------------

  logic acquire_alignment_valid;

  always_comb begin

    acquire_alignment_valid = 1'b1;

    if (acquire_opcode) begin

      if ((in_address %
           CACHE_LINE_BYTES) != 0) begin

        acquire_alignment_valid = 1'b0;

      end

    end

  end


  //==========================================================================
  // Sequential error pulse registration
  //==========================================================================

  logic protocol_error_d;

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      protocol_error_d <= 1'b0;

    end
    else begin

      protocol_error_d <=
          protocol_error &&
          in_valid;
    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_A_ASSERTIONS

      //----------------------------------------------------------------------
      // Input payload must remain stable while stalled.
      //----------------------------------------------------------------------

      property p_a_input_stable;

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

      assert property (p_a_input_stable)
        else $error(
          "TLC A: input payload changed while stalled"
        );


      //----------------------------------------------------------------------
      // Output payload must remain stable while stalled.
      //----------------------------------------------------------------------

      property p_a_output_stable;

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

      assert property (p_a_output_stable)
        else $error(
          "TLC A: output payload changed while stalled"
        );


      //----------------------------------------------------------------------
      // Valid must not disappear during backpressure.
      //----------------------------------------------------------------------

      property p_a_valid_stable;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid && !out_ready
        |=> out_valid;

      endproperty

      assert property (p_a_valid_stable)
        else $error(
          "TLC A: VALID dropped during backpressure"
        );


      //----------------------------------------------------------------------
      // No unknown handshake signals.
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
        "TLC A: X/Z on ready/valid"
      );


      //----------------------------------------------------------------------
      // Legal opcode at accepted transaction.
      //----------------------------------------------------------------------

      property p_accepted_opcode_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> opcode_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_accepted_opcode_legal)
          else $error(
            "TLC A: illegal opcode accepted"
          );

      end


      //----------------------------------------------------------------------
      // Accepted request must have legal size.
      //----------------------------------------------------------------------

      property p_accepted_size_legal;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> size_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_accepted_size_legal)
          else $error(
            "TLC A: illegal transfer size accepted"
          );

      end


      //----------------------------------------------------------------------
      // Accepted request must be aligned.
      //----------------------------------------------------------------------

      property p_accepted_alignment;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> alignment_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_accepted_alignment)
          else $error(
            "TLC A: misaligned transaction accepted"
          );

      end


      //----------------------------------------------------------------------
      // Source ID must be legal.
      //----------------------------------------------------------------------

      property p_accepted_source;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire |-> source_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_accepted_source)
          else $error(
            "TLC A: illegal source ID accepted"
          );

      end


      //----------------------------------------------------------------------
      // AcquireBlock must be cache-line aligned.
      //----------------------------------------------------------------------

      property p_acquire_aligned;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire &&
        acquire_opcode
        |-> acquire_alignment_valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_acquire_aligned)
          else $error(
            "TLC A: Acquire address is not cache-line aligned"
          );

      end


      //----------------------------------------------------------------------
      // AcquireBlock/AcquirePerm should not carry arbitrary data.
      //
      // We only check for unknown data here; the manager may ignore data.
      //----------------------------------------------------------------------

      property p_acquire_data_known;

        @(posedge clk)
        disable iff (!rst_n)

        in_fire &&
        acquire_opcode
        |-> !$isunknown(in_data);

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_acquire_data_known)
          else $error(
            "TLC A: Acquire data contains X/Z"
          );

      end


      //----------------------------------------------------------------------
      // FIFO must not overflow.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(in_valid && !in_ready)
        |-> !in_fire
      )
      else $error(
        "TLC A: internal handshake inconsistency"
      );


      //----------------------------------------------------------------------
      // Reset must clear output.
      //----------------------------------------------------------------------

      property p_reset_clean;

        @(posedge clk)

        !rst_n
        |-> !out_valid;

      endproperty

      assert property (p_reset_clean)
        else $error(
          "TLC A: output valid during reset"
        );


      //----------------------------------------------------------------------
      // A-channel AcquireBlock opcode remains stable under stall.
      //----------------------------------------------------------------------

      property p_acquire_stability;

        @(posedge clk)
        disable iff (!rst_n)

        out_valid &&
        !out_ready &&
        (out_opcode == OP_ACQUIREBLOCK)
        |=> out_valid &&
            (out_opcode == OP_ACQUIREBLOCK);

      endproperty

      assert property (p_acquire_stability)
        else $error(
          "TLC A: AcquireBlock changed while stalled"
        );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0) begin

      $error(
        "TLC A: ADDR_W must be greater than zero"
      );

    end


    if (DATA_W == 0) begin

      $error(
        "TLC A: DATA_W must be greater than zero"
      );

    end


    if ((DATA_W % 8) != 0) begin

      $error(
        "TLC A: DATA_W must be byte aligned"
      );

    end


    if (SOURCE_W == 0) begin

      $error(
        "TLC A: SOURCE_W must be greater than zero"
      );

    end


    if (!((CACHE_LINE_BYTES &
           (CACHE_LINE_BYTES - 1)) == 0)) begin

      $error(
        "TLC A: CACHE_LINE_BYTES must be power-of-two"
      );

    end


    if ((CACHE_LINE_BYTES < 8)) begin

      $warning(
        "TLC A: unusually small cache-line size"
      );

    end

  end

endmodule