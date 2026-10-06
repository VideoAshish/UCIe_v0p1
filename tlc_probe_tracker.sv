//==============================================================================
// tlc_probe_tracker.sv
//
// TileLink-C Probe Transaction Tracker
//
// Purpose
// -------
// Tracks one outstanding Probe transaction:
//
//   * requester/client
//   * transaction/source ID
//   * target fanout
//   * Probe-sent bitmap
//   * ProbeAck-received bitmap
//   * outstanding count
//   * dirty-data collection
//   * returned data
//   * duplicate/unexpected ACK detection
//   * source/client mismatch detection
//   * timeout detection
//
// This block intentionally does NOT drive the B or C channels.
//
// Recommended hierarchy:
//
//   tlc_txn_table
//        |
//        +---- tlc_probe_tracker
//                    |
//                    +---- tlc_probe_engine
//
// For multiple outstanding probe transactions, instantiate one tracker
// per transaction-table entry, or place this tracker logic into an array.
//
//==============================================================================

module tlc_probe_tracker #(
  parameter int unsigned ADDR_W          = 48,
  parameter int unsigned DATA_W          = 256,
  parameter int unsigned SOURCE_W        = 8,
  parameter int unsigned CLIENT_W        = 4,
  parameter int unsigned NUM_CLIENTS     = 8,

  parameter int unsigned TIMEOUT_CYCLES  = 100000,

  parameter bit ENABLE_TIMEOUT           = 1'b1,
  parameter bit ENABLE_ASSERTIONS        = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Transaction allocation / initialization
  //==========================================================================

  input  logic                    alloc_valid,
  output logic                    alloc_ready,

  input  logic [ADDR_W-1:0]       alloc_address,
  input  logic [SOURCE_W-1:0]     alloc_source,
  input  logic [CLIENT_W-1:0]     alloc_requester,

  input  logic [2:0]              alloc_param,

  input  logic [NUM_CLIENTS-1:0]  alloc_targets,

  input  logic                    alloc_dirty_required,

  //==========================================================================
  // Probe transmission notification
  //
  // probe_send_valid is asserted by tlc_probe_engine when it is actually
  // sending a Probe.
  //
  // probe_send_client identifies the target.
  //==========================================================================

  input  logic                    probe_send_valid,
  input  logic [CLIENT_W-1:0]     probe_send_client,

  //==========================================================================
  // ProbeAck / ProbeAckData notification
  //
  // These are normalized responses from tlc_c_channel.
  //==========================================================================

  input  logic                    ack_valid,

  input  logic [SOURCE_W-1:0]     ack_source,
  input  logic [CLIENT_W-1:0]     ack_client,

  input  logic [2:0]              ack_opcode,
  input  logic [2:0]              ack_param,

  input  logic                    ack_data_valid,
  input  logic [DATA_W-1:0]       ack_data,

  input  logic                    ack_dirty,

  //==========================================================================
  // Transaction status
  //==========================================================================

  output logic                    active,

  output logic                    complete,

  output logic                    error,

  output logic                    timeout,

  output logic                    all_probes_sent,

  output logic                    all_acks_received,

  //==========================================================================
  // Transaction identity
  //==========================================================================

  output logic [ADDR_W-1:0]       address,

  output logic [SOURCE_W-1:0]     source,

  output logic [CLIENT_W-1:0]     requester,

  output logic [2:0]              param,

  //==========================================================================
  // Fanout tracking
  //==========================================================================

  output logic [NUM_CLIENTS-1:0]  target_bitmap,

  output logic [NUM_CLIENTS-1:0]  sent_bitmap,

  output logic [NUM_CLIENTS-1:0]  ack_bitmap,

  output logic [NUM_CLIENTS-1:0]  outstanding_bitmap,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  target_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  sent_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  ack_count,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  outstanding_count,

  //==========================================================================
  // Dirty data collection
  //==========================================================================

  output logic                    dirty_required,

  output logic                    dirty_received,

  output logic                    data_received,

  output logic [DATA_W-1:0]       data,

  //==========================================================================
  // Error status
  //==========================================================================

  output logic                    unexpected_ack,

  output logic                    duplicate_ack,

  output logic                    source_mismatch,

  output logic                    client_error,

  output logic                    send_error,

  output logic                    protocol_error,

  //==========================================================================
  // Timeout
  //==========================================================================

  output logic [$clog2(TIMEOUT_CYCLES+1)-1:0]
                                  age
);


  //==========================================================================
  // Local widths
  //==========================================================================

  localparam int unsigned COUNT_W =
      (NUM_CLIENTS <= 1) ? 1 :
      $clog2(NUM_CLIENTS + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // C-channel opcode definitions
  //
  // These are normalized values. Exact TileLink opcode decoding should
  // remain centralized in tlc_pkg.sv / tlc_c_channel.sv.
  //==========================================================================

  localparam logic [2:0] C_PROBEACK =
      3'd4;

  localparam logic [2:0] C_PROBEACKDATA =
      3'd5;


  //==========================================================================
  // Internal state
  //==========================================================================

  logic active_q;
  logic complete_q;
  logic error_q;

  logic [ADDR_W-1:0]    address_q;
  logic [SOURCE_W-1:0]  source_q;
  logic [CLIENT_W-1:0]  requester_q;

  logic [2:0]           param_q;

  logic [NUM_CLIENTS-1:0] target_q;
  logic [NUM_CLIENTS-1:0] sent_q;
  logic [NUM_CLIENTS-1:0] ack_q;

  logic dirty_required_q;
  logic dirty_received_q;

  logic data_received_q;
  logic [DATA_W-1:0] data_q;

  logic [TIMEOUT_W-1:0] age_q;


  //==========================================================================
  // Derived signals
  //==========================================================================

  logic [NUM_CLIENTS-1:0] outstanding_q;

  logic all_sent_w;
  logic all_ack_w;

  logic ack_is_legal;

  logic alloc_fire;
  logic send_fire;
  logic ack_fire;


  assign alloc_ready =
      !active_q;


  assign alloc_fire =
      alloc_valid &&
      alloc_ready;


  assign send_fire =
      probe_send_valid;


  assign ack_fire =
      ack_valid &&
      active_q;


  //==========================================================================
  // Outstanding bitmap
  //
  // Outstanding = target AND sent AND NOT acknowledged.
  //==========================================================================

  always_comb begin

    outstanding_q =
        target_q &
        sent_q &
        ~ack_q;

  end


  //==========================================================================
  // Completion conditions
  //==========================================================================

  always_comb begin

    all_sent_w =
        (sent_q == target_q);

    all_ack_w =
        (ack_q == target_q);

  end


  //==========================================================================
  // ACK legality
  //==========================================================================

  always_comb begin

    ack_is_legal =
        1'b1;

    if (!active_q)
      ack_is_legal = 1'b0;

    if (ack_source != source_q)
      ack_is_legal = 1'b0;

    if (ack_client >= NUM_CLIENTS)
      ack_is_legal = 1'b0;

    else begin

      if (!target_q[ack_client])
        ack_is_legal = 1'b0;

      if (!sent_q[ack_client])
        ack_is_legal = 1'b0;

      if (ack_q[ack_client])
        ack_is_legal = 1'b0;

    end

  end


  //==========================================================================
  // Error classification
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

    send_error =
        1'b0;


    //======================================================================
    // ACK validation
    //======================================================================

    if (ack_fire) begin

      if (ack_source != source_q)
        source_mismatch = 1'b1;

      if (ack_client >= NUM_CLIENTS) begin

        client_error = 1'b1;

      end
      else begin

        if (!target_q[ack_client])
          unexpected_ack = 1'b1;

        if (!sent_q[ack_client])
          unexpected_ack = 1'b1;

        if (ack_q[ack_client])
          duplicate_ack = 1'b1;

      end

    end


    //======================================================================
    // Probe transmission validation
    //======================================================================

    if (send_fire) begin

      if (probe_send_client >= NUM_CLIENTS) begin

        send_error = 1'b1;

      end
      else begin

        if (!target_q[probe_send_client])
          send_error = 1'b1;

        if (sent_q[probe_send_client])
          send_error = 1'b1;

      end

    end

  end


  assign protocol_error =
      unexpected_ack ||
      duplicate_ack ||
      source_mismatch ||
      client_error ||
      send_error;


  //==========================================================================
  // Count outputs
  //==========================================================================

  always_comb begin

    target_count =
        '0;

    sent_count =
        '0;

    ack_count =
        '0;

    outstanding_count =
        '0;

    for (int unsigned i = 0;
         i < NUM_CLIENTS;
         i++) begin

      if (target_q[i])
        target_count++;

      if (sent_q[i])
        sent_count++;

      if (ack_q[i])
        ack_count++;

      if (outstanding_q[i])
        outstanding_count++;

    end

  end


  //==========================================================================
  // Timeout
  //==========================================================================

  always_comb begin

    timeout =
        1'b0;

    if (ENABLE_TIMEOUT &&
        active_q) begin

      if (age_q >=
          TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

        timeout =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      active_q <=
          1'b0;

      complete_q <=
          1'b0;

      error_q <=
          1'b0;

      address_q <=
          '0;

      source_q <=
          '0;

      requester_q <=
          '0;

      param_q <=
          '0;

      target_q <=
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

      //--------------------------------------------------------------------
      // Default pulse behavior
      //--------------------------------------------------------------------

      complete_q <=
          1'b0;


      //--------------------------------------------------------------------
      // Timeout age
      //--------------------------------------------------------------------

      if (active_q &&
          ENABLE_TIMEOUT) begin

        if (age_q <
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

          age_q <=
              age_q + 1'b1;

        end

      end


      //--------------------------------------------------------------------
      // Allocate new probe transaction
      //--------------------------------------------------------------------

      if (alloc_fire) begin

        active_q <=
            1'b1;

        complete_q <=
            1'b0;

        error_q <=
            1'b0;

        address_q <=
            alloc_address;

        source_q <=
            alloc_source;

        requester_q <=
            alloc_requester;

        param_q <=
            alloc_param;

        target_q <=
            alloc_targets;

        sent_q <=
            '0;

        ack_q <=
            '0;

        dirty_required_q <=
            alloc_dirty_required;

        dirty_received_q <=
            1'b0;

        data_received_q <=
            1'b0;

        data_q <=
            '0;

        age_q <=
            '0;

      end


      //--------------------------------------------------------------------
      // Probe was physically accepted by B channel
      //--------------------------------------------------------------------

      if (send_fire) begin

        if (probe_send_client < NUM_CLIENTS) begin

          if (
            target_q[probe_send_client] &&
            !sent_q[probe_send_client]
          ) begin

            sent_q[probe_send_client] <=
                1'b1;

          end
          else begin

            error_q <=
                1'b1;

          end

        end
        else begin

          error_q <=
              1'b1;

        end

      end


      //--------------------------------------------------------------------
      // ProbeAck / ProbeAckData
      //--------------------------------------------------------------------

      if (ack_fire) begin

        if (ack_is_legal) begin

          ack_q[ack_client] <=
              1'b1;


          //----------------------------------------------------------------
          // Dirty indication
          //----------------------------------------------------------------

          if (ack_dirty) begin

            dirty_received_q <=
                1'b1;

          end


          //----------------------------------------------------------------
          // ProbeAckData
          //----------------------------------------------------------------

          if (ack_data_valid) begin

            data_received_q <=
                1'b1;

            data_q <=
                ack_data;

            dirty_received_q <=
                1'b1;

          end

        end
        else begin

          error_q <=
              1'b1;

        end

      end


      //--------------------------------------------------------------------
      // Protocol error
      //--------------------------------------------------------------------

      if (protocol_error) begin

        error_q <=
            1'b1;

      end


      //--------------------------------------------------------------------
      // Timeout
      //--------------------------------------------------------------------

      if (timeout) begin

        error_q <=
            1'b1;

      end


      //--------------------------------------------------------------------
      // Transaction completion
      //
      // ack_fire is included because the final ACK becomes visible in the
      // sequential block on this edge.
      //--------------------------------------------------------------------

      if (
        active_q &&
        all_ack_w
      ) begin

        active_q <=
            1'b0;

        complete_q <=
            1'b1;

      end


      if (
        active_q &&
        ack_fire &&
        ack_is_legal &&
        (ack_count + 1'b1 >= target_count)
      ) begin

        active_q <=
            1'b0;

        complete_q <=
            1'b1;

      end


      //--------------------------------------------------------------------
      // Error terminates the transaction.
      //--------------------------------------------------------------------

      if (protocol_error ||
          timeout) begin

        active_q <=
            1'b0;

      end

    end

  end


  //==========================================================================
  // Outputs
  //==========================================================================

  assign active =
      active_q;

  assign complete =
      complete_q;

  assign error =
      error_q;

  assign all_probes_sent =
      all_sent_w;

  assign all_acks_received =
      all_ack_w;


  assign address =
      address_q;

  assign source =
      source_q;

  assign requester =
      requester_q;

  assign param =
      param_q;


  assign target_bitmap =
      target_q;

  assign sent_bitmap =
      sent_q;

  assign ack_bitmap =
      ack_q;

  assign outstanding_bitmap =
      outstanding_q;


  assign dirty_required =
      dirty_required_q;

  assign dirty_received =
      dirty_received_q;

  assign data_received =
      data_received_q;

  assign data =
      data_q;


  assign age =
      age_q;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_TLC_PROBE_TRACKER_ASSERTIONS

      //--------------------------------------------------------------------
      // Sent probe must always belong to target set.
      //--------------------------------------------------------------------

      for (genvar g = 0;
           g < NUM_CLIENTS;
           g++) begin : GEN_CLIENT_ASSERT

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          sent_q[g]
          |-> target_q[g]
        )
        else $error(
          "TLC PROBE TRACKER: sent[%0d] is not a target",
          g
        );


        //------------------------------------------------------------------
        // ACK must always belong to target set.
        //------------------------------------------------------------------

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          ack_q[g]
          |-> target_q[g]
        )
        else $error(
          "TLC PROBE TRACKER: ack[%0d] is not a target",
          g
        );


        //------------------------------------------------------------------
        // ACK cannot exist without Probe having been sent.
        //------------------------------------------------------------------

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          ack_q[g]
          |-> sent_q[g]
        )
        else $error(
          "TLC PROBE TRACKER: ACK[%0d] before Probe",
          g
        );


        //------------------------------------------------------------------
        // Outstanding means sent but not acknowledged.
        //------------------------------------------------------------------

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          outstanding_q[g]
          == (target_q[g] && sent_q[g] && !ack_q[g])
        )
        else $error(
          "TLC PROBE TRACKER: outstanding bitmap mismatch"
        );

      end


      //--------------------------------------------------------------------
      // ACK count <= sent count <= target count.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_count <= sent_count
      )
      else $error(
        "TLC PROBE TRACKER: ACK count exceeds sent count"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        sent_count <= target_count
      )
      else $error(
        "TLC PROBE TRACKER: sent count exceeds target count"
      );


      //--------------------------------------------------------------------
      // Outstanding count cannot exceed target count.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        outstanding_count <= target_count
      )
      else $error(
        "TLC PROBE TRACKER: outstanding count overflow"
      );


      //--------------------------------------------------------------------
      // Active transaction must have a non-empty target set.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        active_q
        |-> (target_q != '0)
      )
      else $error(
        "TLC PROBE TRACKER: active transaction has no targets"
      );


      //--------------------------------------------------------------------
      // Data implies dirty response.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        data_received_q
        |-> dirty_received_q
      )
      else $error(
        "TLC PROBE TRACKER: data received without dirty indication"
      );


      //--------------------------------------------------------------------
      // Completion requires all ACKs.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_q
        |-> all_ack_w
      )
      else $error(
        "TLC PROBE TRACKER: completion before all ProbeAcks"
      );


      //--------------------------------------------------------------------
      // Error and completion should never occur together.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(complete_q && error_q)
      )
      else $error(
        "TLC PROBE TRACKER: completion and error simultaneously asserted"
      );


      //--------------------------------------------------------------------
      // Probe send must reference a legal client.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_send_valid
        |-> (probe_send_client < NUM_CLIENTS)
      )
      else $error(
        "TLC PROBE TRACKER: illegal probe client"
      );


      //--------------------------------------------------------------------
      // ACK must belong to the active source.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_valid && active_q
        |-> (ack_source == source_q)
      )
      else $error(
        "TLC PROBE TRACKER: ProbeAck source mismatch"
      );


      //--------------------------------------------------------------------
      // ACK client must have been probed.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_valid && active_q &&
        (ack_client < NUM_CLIENTS)
        |-> sent_q[ack_client]
      )
      else $error(
        "TLC PROBE TRACKER: ACK received before Probe"
      );


      //--------------------------------------------------------------------
      // Duplicate ACK is illegal.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_valid && active_q &&
        (ack_client < NUM_CLIENTS)
        |-> !ack_q[ack_client]
      )
      else $error(
        "TLC PROBE TRACKER: duplicate ProbeAck"
      );


      //--------------------------------------------------------------------
      // Reset must clear tracker.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        !active_q
      )
      else $error(
        "TLC PROBE TRACKER: active during reset"
      );


      //--------------------------------------------------------------------
      // No transaction should remain active after timeout.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        timeout
        |=> !active_q
      )
      else $error(
        "TLC PROBE TRACKER: transaction remained active after timeout"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC PROBE TRACKER: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC PROBE TRACKER: DATA_W must be > 0"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC PROBE TRACKER: SOURCE_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC PROBE TRACKER: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC PROBE TRACKER: NUM_CLIENTS must be > 0"
      );

    if (NUM_CLIENTS > (1 << CLIENT_W))
      $error(
        "TLC PROBE TRACKER: CLIENT_W insufficient for NUM_CLIENTS"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC PROBE TRACKER: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule