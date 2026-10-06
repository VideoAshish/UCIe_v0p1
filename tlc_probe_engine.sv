//==============================================================================
// tlc_probe_engine.sv
//
// TileLink-C Probe Engine
//
// Production-oriented coherence probe controller.
//
// Responsibilities
// ----------------
//   * Accept a probe transaction from the directory
//   * Snapshot target-client fanout
//   * Issue one Probe at a time
//   * Maintain per-client sent/acknowledged state
//   * Accept ProbeAck / ProbeAckData responses
//   * Collect dirty-data indication
//   * Track data-returning ProbeAckData
//   * Detect duplicate / unexpected acknowledgements
//   * Provide transaction-level completion
//   * Provide timeout detection
//   * Prevent combinational ready/valid loops
//
// Architectural separation
// ------------------------
//   tlc_directory      : coherence state / ownership
//   tlc_permission_mgr : permission policy
//   tlc_probe_engine   : probe fanout + response collection
//   tlc_txn_table      : transaction bookkeeping
//   tlc_b_channel      : B transport
//   tlc_c_channel      : C transport
//
// The probe engine does NOT directly update the directory.
//
//==============================================================================

module tlc_probe_engine #(
  parameter int unsigned ADDR_W       = 48,
  parameter int unsigned DATA_W       = 256,
  parameter int unsigned SOURCE_W     = 8,
  parameter int unsigned CLIENT_W     = 4,

  parameter int unsigned NUM_CLIENTS  = 8,

  parameter int unsigned MAX_PROBES   = NUM_CLIENTS,

  parameter int unsigned TIMEOUT_CYCLES = 100000,

  parameter bit ENABLE_TIMEOUT        = 1'b1,
  parameter bit ENABLE_ASSERTIONS     = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Probe transaction request
  //==========================================================================

  input  logic                    req_valid,
  output logic                    req_ready,

  input  logic [ADDR_W-1:0]       req_address,
  input  logic [SOURCE_W-1:0]     req_source,

  input  logic [CLIENT_W-1:0]     req_requester,

  input  logic [NUM_CLIENTS-1:0]  req_targets,

  input  logic [2:0]              req_param,

  input  logic                    req_dirty_required,

  //==========================================================================
  // B-channel Probe output
  //
  // One probe is emitted at a time.
  //==========================================================================

  output logic                    b_valid,
  input  logic                    b_ready,

  output logic [ADDR_W-1:0]       b_address,
  output logic [SOURCE_W-1:0]     b_source,
  output logic [CLIENT_W-1:0]     b_client_id,
  output logic [2:0]              b_param,

  //==========================================================================
  // C-channel ProbeAck input
  //
  // The C-channel adapter must decode the actual TileLink C opcode and
  // present a normalized response here.
  //==========================================================================

  input  logic                    c_valid,
  output logic                    c_ready,

  input  logic [SOURCE_W-1:0]     c_source,
  input  logic [CLIENT_W-1:0]     c_client_id,

  input  logic [2:0]              c_opcode,
  input  logic [2:0]              c_param,

  input  logic                    c_data_valid,

  input  logic [DATA_W-1:0]       c_data,

  input  logic                    c_dirty,

  //==========================================================================
  // Completion
  //==========================================================================

  output logic                    complete_valid,
  output logic [SOURCE_W-1:0]     complete_source,

  output logic                    complete_dirty,

  output logic                    complete_data_valid,
  output logic [DATA_W-1:0]       complete_data,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy,

  output logic                    probe_active,

  output logic [NUM_CLIENTS-1:0]  target_bitmap,

  output logic [NUM_CLIENTS-1:0]  sent_bitmap,

  output logic [NUM_CLIENTS-1:0]  ack_bitmap,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  target_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  sent_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  ack_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  remaining_count,

  output logic                    dirty_required,

  output logic                    dirty_received,

  output logic                    data_received,

  //==========================================================================
  // Error reporting
  //==========================================================================

  output logic                    unexpected_ack,

  output logic                    duplicate_ack,

  output logic                    source_mismatch,

  output logic                    client_error,

  output logic                    overflow_error,

  output logic                    timeout_valid,

  output logic [SOURCE_W-1:0]     timeout_source,

  output logic                    protocol_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned COUNT_W =
      (NUM_CLIENTS <= 1) ? 1 :
      $clog2(NUM_CLIENTS + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // TileLink C-channel opcodes
  //
  // Normalized values used by this module.
  //
  // The physical C-channel adapter should perform the exact TL opcode
  // decoding before presenting c_opcode here.
  //==========================================================================

  localparam logic [2:0] C_RELEASE =
      3'd4;

  localparam logic [2:0] C_PROBEACK =
      3'd4;

  localparam logic [2:0] C_PROBEACKDATA =
      3'd5;


  //==========================================================================
  // Internal FSM
  //==========================================================================

  typedef enum logic [2:0] {
    ST_IDLE       = 3'd0,
    ST_ISSUE      = 3'd1,
    ST_WAIT_ACK   = 3'd2,
    ST_COMPLETE   = 3'd3,
    ST_ERROR      = 3'd4
  } state_e;

  state_e state_q;
  state_e state_d;


  //==========================================================================
  // Latched transaction
  //==========================================================================

  logic [ADDR_W-1:0]      address_q;
  logic [SOURCE_W-1:0]    source_q;

  logic [CLIENT_W-1:0]    requester_q;

  logic [2:0]             param_q;

  logic [NUM_CLIENTS-1:0] targets_q;
  logic [NUM_CLIENTS-1:0] sent_q;
  logic [NUM_CLIENTS-1:0] ack_q;

  logic                   dirty_required_q;
  logic                   dirty_received_q;

  logic                   data_received_q;
  logic [DATA_W-1:0]      data_q;

  logic [TIMEOUT_W-1:0]   age_q;


  //==========================================================================
  // Combinational next state
  //==========================================================================

  logic [NUM_CLIENTS-1:0] next_unsent;
  logic [NUM_CLIENTS-1:0] next_unacked;

  logic                   next_probe_found;
  logic [CLIENT_W-1:0]    next_probe_client;

  logic                   req_fire;
  logic                   b_fire;
  logic                   c_fire;


  //==========================================================================
  // Current fanout calculations
  //==========================================================================

  always_comb begin

    next_unsent =
        targets_q &
        ~sent_q;

    next_unacked =
        targets_q &
        ~ack_q;

  end


  //==========================================================================
  // Select next probe
  //
  // Fixed priority is deliberately used here. A separate arbiter can be
  // substituted later if weighted/fair probe scheduling is required.
  //==========================================================================

  always_comb begin

    next_probe_found  = 1'b0;
    next_probe_client = '0;

    for (int unsigned i = 0;
         i < NUM_CLIENTS;
         i++) begin

      if (!next_probe_found &&
          next_unsent[i]) begin

        next_probe_found =
            1'b1;

        next_probe_client =
            CLIENT_W'(i);

      end

    end

  end


  //==========================================================================
  // Request interface
  //==========================================================================

  assign req_ready =
      (state_q == ST_IDLE);

  assign req_fire =
      req_valid &&
      req_ready;


  //==========================================================================
  // B-channel output
  //
  // Registered state determines whether the engine is issuing probes.
  // There is no combinational dependency from B ready back to req ready.
  //==========================================================================

  always_comb begin

    b_valid =
        1'b0;

    b_address =
        address_q;

    b_source =
        source_q;

    b_client_id =
        next_probe_client;

    b_param =
        param_q;

    if (state_q == ST_ISSUE &&
        next_probe_found) begin

      b_valid =
          1'b1;

    end

  end


  assign b_fire =
      b_valid &&
      b_ready;


  //==========================================================================
  // C-channel acceptance
  //
  // We only consume responses belonging to the active probe transaction.
  //
  // Keeping c_ready asserted only while waiting for acknowledgements avoids
  // accepting unrelated C traffic.
  //==========================================================================

  assign c_ready =
      (state_q == ST_WAIT_ACK);

  assign c_fire =
      c_valid &&
      c_ready;


  //==========================================================================
  // Response validation
  //==========================================================================

  always_comb begin

    unexpected_ack =
        1'b0;

    duplicate_ack =
        1'b0;

    source_mismatch =
        1'b0;

    client_error =
        1'b0;

    overflow_error =
        1'b0;


    if (c_fire) begin

      //====================================================================
      // Source must match active probe transaction.
      //====================================================================

      if (c_source != source_q) begin

        source_mismatch =
            1'b1;

      end


      //====================================================================
      // Client must be valid.
      //====================================================================

      if (c_client_id >= NUM_CLIENTS) begin

        client_error =
            1'b1;

      end
      else begin

        //==============================================================
        // Response must come from a target.
        //==============================================================

        if (!targets_q[c_client_id]) begin

          unexpected_ack =
              1'b1;

        end

        //==============================================================
        // Duplicate ProbeAck.
        //==============================================================

        if (ack_q[c_client_id]) begin

          duplicate_ack =
              1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Protocol error
  //==========================================================================

  assign protocol_error =
      unexpected_ack ||
      duplicate_ack ||
      source_mismatch ||
      client_error ||
      overflow_error;


  //==========================================================================
  // Completion condition
  //==========================================================================

  logic all_acks_received;

  always_comb begin

    all_acks_received =
        (targets_q == ack_q);

  end


  //==========================================================================
  // Counts
  //==========================================================================

  always_comb begin

    target_count =
        '0;

    sent_count =
        '0;

    ack_count =
        '0;

    remaining_count =
        '0;

    for (int unsigned i = 0;
         i < NUM_CLIENTS;
         i++) begin

      if (targets_q[i])
        target_count++;

      if (sent_q[i])
        sent_count++;

      if (ack_q[i])
        ack_count++;

      if (targets_q[i] &&
          !ack_q[i])
        remaining_count++;

    end

  end


  //==========================================================================
  // Status
  //==========================================================================

  assign busy =
      (state_q != ST_IDLE);

  assign probe_active =
      (state_q == ST_ISSUE) ||
      (state_q == ST_WAIT_ACK);

  assign target_bitmap =
      targets_q;

  assign sent_bitmap =
      sent_q;

  assign ack_bitmap =
      ack_q;

  assign dirty_required =
      dirty_required_q;

  assign dirty_received =
      dirty_received_q;

  assign data_received =
      data_received_q;


  //==========================================================================
  // Timeout detection
  //==========================================================================

  always_comb begin

    timeout_valid =
        1'b0;

    timeout_source =
        source_q;

    if (ENABLE_TIMEOUT &&
        busy) begin

      if (age_q >=
          TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

        timeout_valid =
            1'b1;

      end

    end

  end


  //==========================================================================
  // State transition logic
  //==========================================================================

  always_comb begin

    state_d =
        state_q;

    case (state_q)

      //====================================================================
      // IDLE
      //====================================================================

      ST_IDLE: begin

        if (req_fire) begin

          if (req_targets == '0) begin

            // No probes required.
            state_d =
                ST_COMPLETE;

          end
          else begin

            state_d =
                ST_ISSUE;

          end

        end

      end


      //====================================================================
      // ISSUE
      //====================================================================

      ST_ISSUE: begin

        if (protocol_error) begin

          state_d =
              ST_ERROR;

        end
        else if (timeout_valid) begin

          state_d =
              ST_ERROR;

        end
        else if (!next_probe_found) begin

          if (all_acks_received) begin

            state_d =
                ST_COMPLETE;

          end
          else begin

            state_d =
                ST_WAIT_ACK;

          end

        end
        else if (b_fire) begin

          // If this was the final unsent probe, transition to wait for
          // acknowledgements.
          //
          // The sent bitmap is updated sequentially, so the next cycle
          // observes the new state.

          if (
            (sent_count + 1'b1) >= target_count
          ) begin

            state_d =
                ST_WAIT_ACK;

          end

        end

      end


      //====================================================================
      // WAIT ACK
      //====================================================================

      ST_WAIT_ACK: begin

        if (protocol_error) begin

          state_d =
              ST_ERROR;

        end
        else if (timeout_valid) begin

          state_d =
              ST_ERROR;

        end
        else if (c_fire) begin

          // Final acknowledgement is checked against the current bitmap.
          if (
            ack_count + 1'b1 >= target_count
          ) begin

            state_d =
                ST_COMPLETE;

          end

        end

      end


      //====================================================================
      // COMPLETE
      //====================================================================

      ST_COMPLETE: begin

        state_d =
            ST_IDLE;

      end


      //====================================================================
      // ERROR
      //====================================================================

      ST_ERROR: begin

        // Error recovery is intentionally explicit.
        //
        // The transaction remains blocked until reset. A production system
        // may replace this with an explicit abort/replay interface.
        state_d =
            ST_ERROR;

      end


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

      targets_q <=
          '0;

      sent_q <=
          '0;

      ack_q <=
          '0;

      dirty_required_q <=
          1'b0;

      dirty_received_q <=
          1'b0;

      data_received_q <=
          1'b0;

      data_q <=
          '0;

      age_q <=
          '0;

    end
    else begin

      //====================================================================
      // State
      //====================================================================

      state_q <=
          state_d;


      //====================================================================
      // Timeout age
      //
      // Saturating counter.
      //====================================================================

      if (busy) begin

        if (ENABLE_TIMEOUT) begin

          if (age_q <
              TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

            age_q <=
                age_q + 1'b1;

          end

        end

      end


      //====================================================================
      // New transaction
      //====================================================================

      if (req_fire) begin

        address_q <=
            req_address;

        source_q <=
            req_source;

        requester_q <=
            req_requester;

        param_q <=
            req_param;

        targets_q <=
            req_targets;

        sent_q <=
            '0;

        ack_q <=
            '0;

        dirty_required_q <=
            req_dirty_required;

        dirty_received_q <=
            1'b0;

        data_received_q <=
            1'b0;

        data_q <=
            '0;

        age_q <=
            '0;

      end


      //====================================================================
      // B Probe accepted
      //====================================================================

      if (b_fire) begin

        if (next_probe_client < NUM_CLIENTS) begin

          sent_q[next_probe_client] <=
              1'b1;

        end
        else begin

          overflow_error <=
              1'b1;

        end

      end


      //====================================================================
      // C ProbeAck accepted
      //====================================================================

      if (c_fire) begin

        if (
          (c_client_id < NUM_CLIENTS) &&
          targets_q[c_client_id] &&
          !ack_q[c_client_id] &&
          (c_source == source_q)
        ) begin

          ack_q[c_client_id] <=
              1'b1;

          //==============================================================
          // Dirty ownership indication.
          //==============================================================

          if (c_dirty) begin

            dirty_received_q <=
                1'b1;

          end

          //==============================================================
          // ProbeAckData
          //==============================================================

          if (c_data_valid) begin

            data_received_q <=
                1'b1;

            data_q <=
                c_data;

            dirty_received_q <=
                1'b1;

          end

        end

      end


      //====================================================================
      // Completion cleanup
      //====================================================================

      if (state_q == ST_COMPLETE) begin

        targets_q <=
            '0;

        sent_q <=
            '0;

        ack_q <=
            '0;

        dirty_required_q <=
            1'b0;

        age_q <=
            '0;

      end

    end

  end


  //==========================================================================
  // Completion outputs
  //
  // Completion is a one-cycle indication generated while the FSM is in
  // ST_COMPLETE.
  //==========================================================================

  always_comb begin

    complete_valid =
        (state_q == ST_COMPLETE);

    complete_source =
        source_q;

    complete_dirty =
        dirty_received_q;

    complete_data_valid =
        data_received_q;

    complete_data =
        data_q;

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_PROBE_ASSERTIONS

      //====================================================================
      // Cannot accept a request while busy.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        busy
        |-> !req_ready
      )
      else $error(
        "TLC PROBE ENGINE: request accepted while engine busy"
      );


      //====================================================================
      // Probe output only valid for a target.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        b_valid
        |-> targets_q[b_client_id]
      )
      else $error(
        "TLC PROBE ENGINE: probe issued to non-target client"
      );


      //====================================================================
      // Probe output must not target requester.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        b_valid
        |-> (b_client_id != requester_q)
      )
      else $error(
        "TLC PROBE ENGINE: probe sent to requester"
      );


      //====================================================================
      // Every sent probe must have been a target.
      //====================================================================

      for (genvar g = 0;
           g < NUM_CLIENTS;
           g++) begin : GEN_BITMAP_ASSERTS

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          sent_q[g]
          |-> targets_q[g]
        )
        else $error(
          "TLC PROBE ENGINE: sent bitmap contains non-target"
        );


        //==================================================================
        // Every acknowledgement must have a corresponding target.
        //==================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          ack_q[g]
          |-> targets_q[g]
        )
        else $error(
          "TLC PROBE ENGINE: ack bitmap contains non-target"
        );


        //==================================================================
        // Ack cannot occur before probe was sent.
        //==================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          ack_q[g]
          |-> sent_q[g]
        )
        else $error(
          "TLC PROBE ENGINE: acknowledgement before Probe"
        );

      end


      //====================================================================
      // Ack count cannot exceed target count.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_count <= target_count
      )
      else $error(
        "TLC PROBE ENGINE: acknowledgement count overflow"
      );


      //====================================================================
      // Sent count cannot exceed target count.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        sent_count <= target_count
      )
      else $error(
        "TLC PROBE ENGINE: probe count overflow"
      );


      //====================================================================
      // Dirty data implies dirty response.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        data_received_q
        |-> dirty_received_q
      )
      else $error(
        "TLC PROBE ENGINE: data received without dirty indication"
      );


      //====================================================================
      // Completion only after all acknowledgements.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid &&
        (target_count != 0)
        |-> (ack_count == target_count)
      )
      else $error(
        "TLC PROBE ENGINE: completion before all ProbeAcks"
      );


      //====================================================================
      // Completion source remains stable.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> !$isunknown(complete_source)
      )
      else $error(
        "TLC PROBE ENGINE: completion source is X"
      );


      //====================================================================
      // ProbeAck source must match transaction source.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_fire
        |-> (c_source == source_q)
      )
      else $error(
        "TLC PROBE ENGINE: ProbeAck source mismatch"
      );


      //====================================================================
      // ProbeAck must come from a target.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_fire
        |-> targets_q[c_client_id]
      )
      else $error(
        "TLC PROBE ENGINE: ProbeAck from non-target"
      );


      //====================================================================
      // No duplicate acknowledgement.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_fire
        |-> !ack_q[c_client_id]
      )
      else $error(
        "TLC PROBE ENGINE: duplicate ProbeAck"
      );


      //====================================================================
      // Reset leaves engine idle.
      //====================================================================

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (state_q == ST_IDLE)
      )
      else $error(
        "TLC PROBE ENGINE: reset did not return to IDLE"
      );


      //====================================================================
      // Busy implies valid transaction context.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        busy
        |-> !$isunknown(source_q)
      )
      else $error(
        "TLC PROBE ENGINE: busy without valid source"
      );


      //====================================================================
      // Timeout cannot happen while idle.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        (state_q == ST_IDLE)
        |-> !timeout_valid
      )
      else $error(
        "TLC PROBE ENGINE: timeout while idle"
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
        "TLC PROBE ENGINE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC PROBE ENGINE: DATA_W must be > 0"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC PROBE ENGINE: SOURCE_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC PROBE ENGINE: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC PROBE ENGINE: NUM_CLIENTS must be > 0"
      );

    if (MAX_PROBES < NUM_CLIENTS)
      $error(
        "TLC PROBE ENGINE: MAX_PROBES must cover NUM_CLIENTS"
      );

    if (NUM_CLIENTS > (1 << CLIENT_W))
      $error(
        "TLC PROBE ENGINE: CLIENT_W insufficient for NUM_CLIENTS"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC PROBE ENGINE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule