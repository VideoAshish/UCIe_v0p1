//==============================================================================
// tlc_grant_engine.sv
//
// TileLink-C Grant Engine
//
// Responsibilities
// ----------------
// * Generate Grant / GrantData on D channel
// * Correlate Grant with Acquire source
// * Allocate/track sink ID
// * Support GrantAck through E channel
// * Hold GrantData stable under backpressure
// * Support dirty-data forwarding
// * Support configurable DATA_W / SOURCE_W / SINK_W
// * Detect malformed Grant requests
// * Detect source/sink mismatches
// * Timeout detection
// * Reset-clean FSM
// * No combinational ready/valid dependency
// * SVA protocol checks
//
// Architectural position:
//
//       Acquire Engine
//             |
//             v
//       Transaction Table
//             |
//             v
//       +------------------+
//       | tlc_grant_engine |
//       +--------+---------+
//                |
//          +-----+-----+
//          |           |
//          v           v
//       D Channel    E Channel
//       Grant        GrantAck
//
//==============================================================================

module tlc_grant_engine #(
  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned SINK_W =
      8,

  parameter int unsigned CLIENT_W =
      4,

  parameter int unsigned NUM_CLIENTS =
      8,

  parameter int unsigned MAX_OUTSTANDING =
      16,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_TIMEOUT =
      1'b1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1,

  parameter bit REQUIRE_GRANT_ACK =
      1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Grant request from Acquire / transaction machinery
  //==========================================================================

  input  logic                    grant_req_valid,
  output logic                    grant_req_ready,

  input  logic [ADDR_W-1:0]       grant_req_address,

  input  logic [SOURCE_W-1:0]     grant_req_source,

  input  logic [CLIENT_W-1:0]     grant_req_requester,

  input  logic [2:0]              grant_req_opcode,

  input  logic [2:0]              grant_req_param,

  input  logic [DATA_W-1:0]       grant_req_data,

  input  logic [DATA_W/8-1:0]     grant_req_mask,

  input  logic                    grant_req_data_valid,

  input  logic                    grant_req_requires_ack,

  //==========================================================================
  // Permission / coherence result
  //==========================================================================

  input  logic [2:0]              grant_permission,

  input  logic                    grant_dirty,

  //==========================================================================
  // Sink allocation interface
  //
  // tlc_sink_table owns sink allocation.
  //==========================================================================

  output logic                    sink_alloc_valid,
  input  logic                    sink_alloc_ready,

  input  logic [SINK_W-1:0]       sink_alloc_id,

  output logic                    sink_alloc_free_valid,
  output logic [SINK_W-1:0]       sink_alloc_free_id,
  input  logic                    sink_alloc_free_ready,

  //==========================================================================
  // D channel
  //==========================================================================

  output logic                    d_valid,
  input  logic                    d_ready,

  output logic [2:0]              d_opcode,
  output logic [2:0]              d_param,

  output logic [2:0]              d_size,

  output logic [SINK_W-1:0]       d_sink,

  output logic [SOURCE_W-1:0]     d_source,

  output logic                    d_denied,

  output logic                    d_data_valid,

  output logic [DATA_W-1:0]       d_data,

  output logic [DATA_W/8-1:0]     d_mask,

  //==========================================================================
  // E channel GrantAck input
  //==========================================================================

  input  logic                    e_valid,
  output logic                    e_ready,

  input  logic [SINK_W-1:0]       e_sink,

  //==========================================================================
  // Completion
  //==========================================================================

  output logic                    complete_valid,
  input  logic                    complete_ready,

  output logic [SOURCE_W-1:0]     complete_source,

  output logic [SINK_W-1:0]       complete_sink,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy,

  output logic                    d_pending,

  output logic                    ack_pending,

  output logic                    grant_sent,

  //==========================================================================
  // Error reporting
  //==========================================================================

  output logic                    illegal_opcode,

  output logic                    malformed_transaction,

  output logic                    alignment_error,

  output logic                    source_error,

  output logic                    sink_error,

  output logic                    mask_error,

  output logic                    timeout_error,

  output logic                    protocol_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);

  localparam int unsigned SIZE_W =
      3;


  //==========================================================================
  // TileLink normalized D-channel opcodes
  //
  // Keep these synchronized with tlc_pkg.sv.
  //
  // Typical TileLink encoding:
  //
  //   AccessAck      = 0
  //   AccessAckData  = 1
  //   HintAck        = 2
  //   Grant          = 4
  //   GrantData      = 5
  //   ReleaseAck     = 6
  //
  //==========================================================================

  localparam logic [2:0] D_GRANT =
      3'd4;

  localparam logic [2:0] D_GRANT_DATA =
      3'd5;


  //==========================================================================
  // FSM
  //==========================================================================

  typedef enum logic [3:0] {

    ST_IDLE        = 4'd0,

    ST_SINK_ALLOC  = 4'd1,

    ST_VALIDATE    = 4'd2,

    ST_SEND_GRANT  = 4'd3,

    ST_WAIT_ACK    = 4'd4,

    ST_COMPLETE    = 4'd5,

    ST_ERROR       = 4'd6

  } state_e;

  state_e state_q;
  state_e state_d;


  //==========================================================================
  // Latched Grant transaction
  //==========================================================================

  logic [ADDR_W-1:0] address_q;

  logic [SOURCE_W-1:0] source_q;

  logic [CLIENT_W-1:0] requester_q;

  logic [2:0] param_q;

  logic [DATA_W-1:0] data_q;

  logic [BYTE_W-1:0] mask_q;

  logic data_valid_q;

  logic requires_ack_q;

  logic dirty_q;

  logic [2:0] permission_q;


  //==========================================================================
  // Sink ID
  //==========================================================================

  logic [SINK_W-1:0] sink_q;

  logic sink_allocated_q;


  //==========================================================================
  // Progress tracking
  //==========================================================================

  logic grant_sent_q;

  logic ack_received_q;

  logic completion_q;


  //==========================================================================
  // Error state
  //==========================================================================

  logic illegal_opcode_q;

  logic malformed_q;

  logic alignment_error_q;

  logic source_error_q;

  logic sink_error_q;

  logic mask_error_q;

  logic timeout_error_q;


  //==========================================================================
  // Timeout
  //==========================================================================

  logic [TIMEOUT_W-1:0] age_q;


  //==========================================================================
  // Handshakes
  //==========================================================================

  logic grant_req_fire;

  logic sink_alloc_fire;

  logic d_fire;

  logic e_fire;

  logic complete_fire;

  logic sink_free_fire;


  assign grant_req_fire =
      grant_req_valid &&
      grant_req_ready;


  assign sink_alloc_fire =
      sink_alloc_valid &&
      sink_alloc_ready;


  assign d_fire =
      d_valid &&
      d_ready;


  assign e_fire =
      e_valid &&
      e_ready;


  assign complete_fire =
      complete_valid &&
      complete_ready;


  assign sink_free_fire =
      sink_alloc_free_valid &&
      sink_alloc_free_ready;


  //==========================================================================
  // Request acceptance
  //==========================================================================

  assign grant_req_ready =
      (state_q == ST_IDLE);


  //==========================================================================
  // Sink allocation
  //==========================================================================

  always_comb begin

    sink_alloc_valid =
        1'b0;

    if (state_q == ST_SINK_ALLOC) begin

      sink_alloc_valid =
          1'b1;

    end

  end


  //==========================================================================
  // Sink free
  //
  // The sink remains owned by this transaction until GrantAck completion.
  //==========================================================================

  always_comb begin

    sink_alloc_free_valid =
        1'b0;

    sink_alloc_free_id =
        sink_q;

    if (
      state_q == ST_COMPLETE &&
      ack_received_q &&
      sink_allocated_q
    ) begin

      sink_alloc_free_valid =
          1'b1;

    end

  end


  //==========================================================================
  // Grant opcode selection
  //==========================================================================

  always_comb begin

    d_opcode =
        data_valid_q ?
        D_GRANT_DATA :
        D_GRANT;

    d_param =
        param_q;

    d_size =
        $clog2(CACHE_LINE_BYTES);

    d_sink =
        sink_q;

    d_source =
        source_q;

    d_denied =
        1'b0;

    d_data_valid =
        data_valid_q;

    d_data =
        data_q;

    d_mask =
        mask_q;

    d_valid =
        1'b0;


    if (
      state_q == ST_SEND_GRANT &&
      !grant_sent_q
    ) begin

      d_valid =
          1'b1;

    end

  end


  //==========================================================================
  // GrantAck
  //==========================================================================

  assign e_ready =
      (state_q == ST_WAIT_ACK);


  //==========================================================================
  // Validation
  //==========================================================================

  always_comb begin

    illegal_opcode =
        1'b0;

    malformed_transaction =
        1'b0;

    alignment_error =
        1'b0;

    source_error =
        1'b0;

    sink_error =
        1'b0;

    mask_error =
        1'b0;


    //-----------------------------------------------------------------------
    // Source validation
    //-----------------------------------------------------------------------

    if (grant_req_fire) begin

      if ($isunknown(grant_req_source)) begin

        source_error =
            1'b1;

      end

      if (
        grant_req_requester >= NUM_CLIENTS
      ) begin

        malformed_transaction =
            1'b1;

      end

    end


    //-----------------------------------------------------------------------
    // Address alignment
    //-----------------------------------------------------------------------

    if (grant_req_fire) begin

      if (
        (grant_req_address % CACHE_LINE_BYTES) != 0
      ) begin

        alignment_error =
            1'b1;

      end

    end


    //-----------------------------------------------------------------------
    // Data-mask validation
    //-----------------------------------------------------------------------

    if (grant_req_fire) begin

      if (grant_req_data_valid) begin

        if (grant_req_mask == '0) begin

          mask_error =
              1'b1;

        end

      end
      else begin

        if (grant_req_mask != '0) begin

          mask_error =
              1'b1;

        end

      end

    end


    //-----------------------------------------------------------------------
    // Grant request must not have unknown control fields.
    //-----------------------------------------------------------------------

    if (grant_req_fire) begin

      if (
        $isunknown(grant_req_opcode) ||
        $isunknown(grant_req_param)
      ) begin

        malformed_transaction =
            1'b1;

      end

    end

  end


  //==========================================================================
  // FSM
  //==========================================================================

  always_comb begin

    state_d =
        state_q;

    case (state_q)

      //----------------------------------------------------------------------
      // IDLE
      //----------------------------------------------------------------------

      ST_IDLE: begin

        if (grant_req_fire) begin

          if (
            illegal_opcode ||
            malformed_transaction ||
            alignment_error ||
            source_error ||
            mask_error
          ) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_SINK_ALLOC;

          end

        end

      end


      //----------------------------------------------------------------------
      // Allocate sink ID
      //----------------------------------------------------------------------

      ST_SINK_ALLOC: begin

        if (sink_alloc_fire) begin

          state_d =
              ST_VALIDATE;

        end

      end


      //----------------------------------------------------------------------
      // Validate grant after sink allocation
      //----------------------------------------------------------------------

      ST_VALIDATE: begin

        if (
          illegal_opcode_q ||
          malformed_q ||
          alignment_error_q ||
          source_error_q ||
          mask_error_q
        ) begin

          state_d =
              ST_ERROR;

        end
        else begin

          state_d =
              ST_SEND_GRANT;

        end

      end


      //----------------------------------------------------------------------
      // Send D Grant
      //----------------------------------------------------------------------

      ST_SEND_GRANT: begin

        if (d_fire) begin

          if (
            requires_ack_q &&
            REQUIRE_GRANT_ACK
          ) begin

            state_d =
                ST_WAIT_ACK;

          end
          else begin

            state_d =
                ST_COMPLETE;

          end

        end

      end


      //----------------------------------------------------------------------
      // Wait for E GrantAck
      //----------------------------------------------------------------------

      ST_WAIT_ACK: begin

        if (e_fire) begin

          if (e_sink != sink_q) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_COMPLETE;

          end

        end

      end


      //----------------------------------------------------------------------
      // Completion
      //----------------------------------------------------------------------

      ST_COMPLETE: begin

        if (
          !sink_allocated_q ||
          sink_free_fire
        ) begin

          if (complete_fire) begin

            state_d =
                ST_IDLE;

          end

        end

      end


      //----------------------------------------------------------------------
      // Error
      //----------------------------------------------------------------------

      ST_ERROR: begin

        // Hold error state until reset.
        //
        // A top-level error-response manager can optionally convert this
        // state into a protocol error response.

        state_d =
            ST_ERROR;

      end


      //----------------------------------------------------------------------
      // Default
      //----------------------------------------------------------------------

      default: begin

        state_d =
            ST_ERROR;

      end

    endcase

  end


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state_q <=
          ST_IDLE;

      address_q <=
          '0;

      source_q <=
          '0;

      requester_q <=
          '0;

      param_q <=
          '0;

      data_q <=
          '0;

      mask_q <=
          '0;

      data_valid_q <=
          1'b0;

      requires_ack_q <=
          1'b0;

      dirty_q <=
          1'b0;

      permission_q <=
          '0;

      sink_q <=
          '0;

      sink_allocated_q <=
          1'b0;

      grant_sent_q <=
          1'b0;

      ack_received_q <=
          1'b0;

      completion_q <=
          1'b0;

      illegal_opcode_q <=
          1'b0;

      malformed_q <=
          1'b0;

      alignment_error_q <=
          1'b0;

      source_error_q <=
          1'b0;

      sink_error_q <=
          1'b0;

      mask_error_q <=
          1'b0;

      timeout_error_q <=
          1'b0;

      age_q <=
          '0;

    end
    else begin

      //======================================================================
      // Default one-cycle completion pulse.
      //======================================================================

      completion_q <=
          1'b0;


      //======================================================================
      // Timeout counter.
      //======================================================================

      if (state_q != ST_IDLE) begin

        if (ENABLE_TIMEOUT) begin

          if (
            age_q <
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]
          ) begin

            age_q <=
                age_q + 1'b1;

          end

        end

      end
      else begin

        age_q <=
            '0;

      end


      //======================================================================
      // Capture Grant request.
      //======================================================================

      if (grant_req_fire) begin

        address_q <=
            grant_req_address;

        source_q <=
            grant_req_source;

        requester_q <=
            grant_req_requester;

        param_q <=
            grant_req_param;

        data_q <=
            grant_req_data;

        mask_q <=
            grant_req_mask;

        data_valid_q <=
            grant_req_data_valid;

        requires_ack_q <=
            grant_req_requires_ack;

        dirty_q <=
            grant_dirty;

        permission_q <=
            grant_permission;

        illegal_opcode_q <=
            illegal_opcode;

        malformed_q <=
            malformed_transaction;

        alignment_error_q <=
            alignment_error;

        source_error_q <=
            source_error;

        sink_error_q <=
            1'b0;

        mask_error_q <=
            mask_error;

        timeout_error_q <=
            1'b0;

        sink_allocated_q <=
            1'b0;

        grant_sent_q <=
            1'b0;

        ack_received_q <=
            1'b0;

      end


      //======================================================================
      // Sink allocated.
      //======================================================================

      if (sink_alloc_fire) begin

        sink_q <=
            sink_alloc_id;

        sink_allocated_q <=
            1'b1;

      end


      //======================================================================
      // Grant transmitted.
      //======================================================================

      if (d_fire) begin

        grant_sent_q <=
            1'b1;

      end


      //======================================================================
      // GrantAck received.
      //======================================================================

      if (e_fire) begin

        if (e_sink == sink_q) begin

          ack_received_q <=
              1'b1;

        end
        else begin

          sink_error_q <=
              1'b1;

        end

      end


      //======================================================================
      // Sink released.
      //======================================================================

      if (sink_free_fire) begin

        sink_allocated_q <=
            1'b0;

      end


      //======================================================================
      // Completion.
      //======================================================================

      if (
        state_q == ST_COMPLETE &&
        complete_fire
      ) begin

        completion_q <=
            1'b1;

      end


      //======================================================================
      // Timeout.
      //======================================================================

      if (
        ENABLE_TIMEOUT &&
        age_q >= TIMEOUT_CYCLES[TIMEOUT_W-1:0]
      ) begin

        timeout_error_q <=
            1'b1;

      end

    end

  end


  //==========================================================================
  // Completion interface
  //==========================================================================

  assign complete_valid =
      (state_q == ST_COMPLETE) &&
      grant_sent_q &&
      (
        !requires_ack_q ||
        !REQUIRE_GRANT_ACK ||
        ack_received_q
      ) &&
      !protocol_error;


  assign complete_source =
      source_q;


  assign complete_sink =
      sink_q;


  //==========================================================================
  // Status
  //==========================================================================

  assign busy =
      (state_q != ST_IDLE);

  assign d_pending =
      (state_q == ST_SEND_GRANT) &&
      !grant_sent_q;

  assign ack_pending =
      (state_q == ST_WAIT_ACK);

  assign grant_sent =
      grant_sent_q;


  //==========================================================================
  // Error outputs
  //==========================================================================

  assign illegal_opcode =
      illegal_opcode_q;

  assign malformed_transaction =
      malformed_q;

  assign alignment_error =
      alignment_error_q;

  assign source_error =
      source_error_q;

  assign sink_error =
      sink_error_q;

  assign mask_error =
      mask_error_q;

  assign timeout_error =
      timeout_error_q;


  assign protocol_error =
      illegal_opcode_q ||
      malformed_q ||
      alignment_error_q ||
      source_error_q ||
      sink_error_q ||
      mask_error_q ||
      timeout_error_q;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_GRANT_ASSERTIONS

      //----------------------------------------------------------------------
      // Grant request only accepted while idle.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_req_fire
        |-> (state_q == ST_IDLE)
      )
      else $error(
        "TLC GRANT: request accepted outside IDLE"
      );


      //----------------------------------------------------------------------
      // Grant D-channel valid only after sink allocation.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid
        |-> sink_allocated_q
      )
      else $error(
        "TLC GRANT: D Grant issued without sink allocation"
      );


      //----------------------------------------------------------------------
      // D source must remain stable.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid && !d_ready
        |=> d_valid &&
            $stable(d_source) &&
            $stable(d_sink) &&
            $stable(d_opcode) &&
            $stable(d_param) &&
            $stable(d_data) &&
            $stable(d_mask)
      )
      else $error(
        "TLC GRANT: D channel changed while stalled"
      );


      //----------------------------------------------------------------------
      // D data-valid consistency.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid &&
        d_data_valid
        |-> (d_opcode == D_GRANT_DATA)
      )
      else $error(
        "TLC GRANT: GrantData opcode mismatch"
      );


      //----------------------------------------------------------------------
      // Grant without data must use Grant opcode.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid &&
        !d_data_valid
        |-> (d_opcode == D_GRANT)
      )
      else $error(
        "TLC GRANT: Grant opcode mismatch"
      );


      //----------------------------------------------------------------------
      // GrantAck only accepted while waiting for Ack.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        e_fire
        |-> (state_q == ST_WAIT_ACK)
      )
      else $error(
        "TLC GRANT: unexpected GrantAck"
      );


      //----------------------------------------------------------------------
      // GrantAck sink must match Grant sink.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        e_fire
        |-> (e_sink == sink_q)
      )
      else $error(
        "TLC GRANT: GrantAck sink mismatch"
      );


      //----------------------------------------------------------------------
      // GrantAck cannot precede Grant.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        e_valid
        |-> grant_sent_q
      )
      else $error(
        "TLC GRANT: GrantAck received before Grant"
      );


      //----------------------------------------------------------------------
      // Completion requires Grant transmission.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> grant_sent_q
      )
      else $error(
        "TLC GRANT: completion before Grant"
      );


      //----------------------------------------------------------------------
      // If Ack is required, completion requires Ack.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid &&
        requires_ack_q &&
        REQUIRE_GRANT_ACK
        |-> ack_received_q
      )
      else $error(
        "TLC GRANT: completion without GrantAck"
      );


      //----------------------------------------------------------------------
      // No completion while protocol error is active.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(complete_valid && protocol_error)
      )
      else $error(
        "TLC GRANT: completion with protocol error"
      );


      //----------------------------------------------------------------------
      // Busy prevents a second Grant request.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        busy
        |-> !grant_req_ready
      )
      else $error(
        "TLC GRANT: request accepted while busy"
      );


      //----------------------------------------------------------------------
      // Sink ID must remain stable while D is stalled.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid && !d_ready
        |=> $stable(d_sink)
      )
      else $error(
        "TLC GRANT: sink changed while D stalled"
      );


      //----------------------------------------------------------------------
      // Reset state.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (state_q == ST_IDLE)
      )
      else $error(
        "TLC GRANT: reset did not return to IDLE"
      );


      //----------------------------------------------------------------------
      // Grant must not be duplicated.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_sent_q
        |-> !d_valid
      )
      else $error(
        "TLC GRANT: duplicate Grant transmission"
      );


      //----------------------------------------------------------------------
      // GrantAck is only relevant when Grant was sent.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_received_q
        |-> grant_sent_q
      )
      else $error(
        "TLC GRANT: Ack recorded before Grant"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC GRANT: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC GRANT: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC GRANT: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC GRANT: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC GRANT: SINK_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC GRANT: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC GRANT: NUM_CLIENTS must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC GRANT: CACHE_LINE_BYTES must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC GRANT: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule