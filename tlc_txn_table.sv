//==============================================================================
// tlc_txn_table.sv
//
// TileLink-C Transaction Table / Outstanding Transaction Scoreboard
//
// Purpose
// -------
// Maintains transaction-level metadata independent of the physical
// TileLink channel.
//
// The source table answers:
//
//      "Which A transaction owns this source ID?"
//
// The sink table answers:
//
//      "Which Grant owns this sink ID?"
//
// This transaction table answers:
//
//      "What is the complete coherence transaction state?"
//
// It tracks:
//   * source ID
//   * sink ID
//   * A-channel opcode/param
//   * address
//   * size
//   * byte mask
//   * Acquire/Release classification
//   * Probe state
//   * Grant state
//   * dirty-data requirement
//   * dirty-data collection
//   * D response state
//   * E GrantAck state
//   * timeout age
//
// Design principles
// -----------------
//   * Fully parameterized
//   * One transaction per source entry
//   * Source ownership is retained until final completion
//   * Sink ownership is independent
//   * No automatic source/sink reuse
//   * No automatic timeout recovery
//   * Synthesis-friendly register/RAM implementation
//   * Assertions for ownership and lifecycle invariants
//
// IMPORTANT
// ---------
// This module is a scoreboard/metadata table.
// It does NOT itself perform channel arbitration.
//
//==============================================================================

module tlc_txn_table #(
  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 8,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 :
      $clog2((DATA_W / 8) + 1),

  parameter int unsigned BYTE_W =
      DATA_W / 8,

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter int unsigned NUM_SINKS =
      (1 << SINK_W),

  parameter int unsigned MAX_PROBES = 16,

  parameter int unsigned TIMEOUT_CYCLES = 100000,

  parameter bit ENABLE_TIMEOUT    = 1'b1,
  parameter bit ENABLE_CHECKS     = 1'b1,
  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Transaction allocation
  //
  // Usually connected to A-channel handshake.
  //==========================================================================

  input  logic                    alloc_valid,
  output logic                    alloc_ready,

  input logic [SOURCE_W-1:0]      alloc_source,

  input logic [2:0]               alloc_opcode,
  input logic [2:0]               alloc_param,

  input logic [SIZE_W-1:0]        alloc_size,

  input logic [ADDR_W-1:0]        alloc_address,

  input logic [BYTE_W-1:0]        alloc_mask,

  input logic                     alloc_is_get,
  input logic                     alloc_is_put,
  input logic                     alloc_is_acquire,
  input logic                     alloc_is_release,

  //==========================================================================
  // Sink association
  //
  // Associates a previously allocated source transaction with a sink.
  //==========================================================================

  input logic                     sink_bind_valid,
  input logic [SOURCE_W-1:0]      sink_bind_source,
  input logic [SINK_W-1:0]        sink_bind_sink,

  //==========================================================================
  // Probe tracking
  //
  // Probe fanout count and completion count are maintained here.
  //==========================================================================

  input logic                     probe_start_valid,
  input logic [SOURCE_W-1:0]      probe_start_source,
  input logic [$clog2(MAX_PROBES+1)-1:0]
                                  probe_count,

  input logic                     probe_ack_valid,
  input logic [SOURCE_W-1:0]      probe_ack_source,

  input logic                     probe_ack_dirty,
  input logic                     probe_ack_data_valid,

  //==========================================================================
  // Dirty-data collection
  //==========================================================================

  input logic                     dirty_data_valid,
  input logic [SOURCE_W-1:0]      dirty_data_source,

  //==========================================================================
  // Grant state
  //==========================================================================

  input logic                     grant_valid,
  input logic [SOURCE_W-1:0]      grant_source,

  input logic [SINK_W-1:0]        grant_sink,

  input logic                     grant_is_data,

  //==========================================================================
  // GrantAck / E channel
  //==========================================================================

  input logic                     grant_ack_valid,
  input logic [SINK_W-1:0]        grant_ack_sink,

  //==========================================================================
  // D-channel completion
  //==========================================================================

  input logic                     d_complete_valid,
  input logic [SOURCE_W-1:0]      d_complete_source,

  input logic [2:0]               d_complete_opcode,

  //==========================================================================
  // External transaction abort/flush
  //
  // This is intentionally explicit. Timeout does NOT automatically abort
  // transactions.
  //==========================================================================

  input logic                     abort_valid,
  input logic [SOURCE_W-1:0]      abort_source,

  //==========================================================================
  // Lookup
  //==========================================================================

  input logic [SOURCE_W-1:0]      lookup_source,

  output logic                    lookup_valid,

  output logic [SINK_W-1:0]       lookup_sink,
  output logic                    lookup_sink_valid,

  output logic [2:0]              lookup_opcode,
  output logic [2:0]              lookup_param,

  output logic [SIZE_W-1:0]       lookup_size,

  output logic [ADDR_W-1:0]       lookup_address,

  output logic [BYTE_W-1:0]       lookup_mask,

  output logic                    lookup_is_get,
  output logic                    lookup_is_put,
  output logic                    lookup_is_acquire,
  output logic                    lookup_is_release,

  output logic                    lookup_probe_active,
  output logic                    lookup_probe_done,

  output logic                    lookup_dirty_required,
  output logic                    lookup_dirty_received,

  output logic                    lookup_grant_sent,
  output logic                    lookup_grant_data,

  output logic                    lookup_grant_ack,

  output logic                    lookup_d_complete,

  //==========================================================================
  // Probe status
  //==========================================================================

  output logic [$clog2(MAX_PROBES+1)-1:0]
                                  lookup_probe_expected,

  output logic [$clog2(MAX_PROBES+1)-1:0]
                                  lookup_probe_received,

  output logic [$clog2(MAX_PROBES+1)-1:0]
                                  lookup_probe_remaining,

  //==========================================================================
  // Completion
  //==========================================================================

  output logic                    txn_complete_valid,
  output logic [SOURCE_W-1:0]     txn_complete_source,

  //==========================================================================
  // Timeout
  //==========================================================================

  output logic                    timeout_valid,
  output logic [SOURCE_W-1:0]     timeout_source,

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                    duplicate_source,
  output logic                    invalid_source,
  output logic                    invalid_sink,
  output logic                    invalid_probe_ack,
  output logic                    probe_overflow,
  output logic                    probe_underflow,
  output logic                    protocol_error,

  //==========================================================================
  // Status
  //==========================================================================

  output logic [$clog2(NUM_SOURCES+1)-1:0]
                                  outstanding_count,

  output logic                    full,
  output logic                    empty,

  output logic                    alloc_fire
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned COUNT_W =
      $clog2(NUM_SOURCES + 1);

  localparam int unsigned PROBE_W =
      (MAX_PROBES <= 1) ? 1 :
      $clog2(MAX_PROBES + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // TileLink opcodes
  //==========================================================================

  localparam logic [2:0] A_PUTFULL =
      3'd0;

  localparam logic [2:0] A_PUTPARTIAL =
      3'd1;

  localparam logic [2:0] A_ARITHMETIC =
      3'd2;

  localparam logic [2:0] A_LOGICAL =
      3'd3;

  localparam logic [2:0] A_GET =
      3'd4;

  localparam logic [2:0] A_ACQUIREBLOCK =
      3'd6;

  localparam logic [2:0] A_ACQUIREPERM =
      3'd7;


  //==========================================================================
  // Transaction states
  //==========================================================================

  typedef enum logic [3:0] {

    TXN_FREE = 4'd0,

    TXN_A_ACCEPTED = 4'd1,

    TXN_WAIT_PROBE = 4'd2,

    TXN_WAIT_DIRTY = 4'd3,

    TXN_WAIT_GRANT = 4'd4,

    TXN_GRANT_SENT = 4'd5,

    TXN_WAIT_GRANT_ACK = 4'd6,

    TXN_WAIT_D = 4'd7,

    TXN_COMPLETE = 4'd8,

    TXN_ABORTED = 4'd9

  } txn_state_e;


  //==========================================================================
  // Transaction entry
  //==========================================================================

  typedef struct packed {

    logic                   valid;

    txn_state_e             state;

    logic [SINK_W-1:0]      sink;
    logic                   sink_valid;

    logic [2:0]             opcode;
    logic [2:0]             param;

    logic [SIZE_W-1:0]      size;

    logic [ADDR_W-1:0]      address;

    logic [BYTE_W-1:0]      mask;

    logic                   is_get;
    logic                   is_put;
    logic                   is_acquire;
    logic                   is_release;

    //----------------------------------------------------------------------//
    // Probe state
    //----------------------------------------------------------------------//

    logic [PROBE_W-1:0]     probe_expected;
    logic [PROBE_W-1:0]     probe_received;

    logic                   probe_active;
    logic                   probe_done;

    //----------------------------------------------------------------------//
    // Dirty data
    //----------------------------------------------------------------------//

    logic                   dirty_required;
    logic                   dirty_received;

    logic                   dirty_data_valid;

    //----------------------------------------------------------------------//
    // Grant
    //----------------------------------------------------------------------//

    logic                   grant_sent;
    logic                   grant_data;

    logic                   grant_ack;

    //----------------------------------------------------------------------//
    // D response
    //----------------------------------------------------------------------//

    logic                   d_complete;

    logic [2:0]             d_opcode;

    //----------------------------------------------------------------------//
    // Timeout
    //----------------------------------------------------------------------//

    logic [TIMEOUT_W-1:0]   age;

  } txn_entry_t;


  txn_entry_t table [0:NUM_SOURCES-1];


  //==========================================================================
  // Allocation
  //==========================================================================

  assign invalid_source =
      alloc_valid &&
      (alloc_source >= NUM_SOURCES);

  assign duplicate_source =
      alloc_valid &&
      table[alloc_source].valid;


  assign alloc_ready =
      !table[alloc_source].valid;


  assign alloc_fire =
      alloc_valid &&
      alloc_ready;


  //==========================================================================
  // Sink validation
  //==========================================================================

  assign invalid_sink =
      sink_bind_valid &&
      (sink_bind_sink >= NUM_SINKS);


  //==========================================================================
  // Lookup
  //==========================================================================

  always_comb begin

    lookup_valid =
        table[lookup_source].valid;

    lookup_sink =
        table[lookup_source].sink;

    lookup_sink_valid =
        table[lookup_source].sink_valid;

    lookup_opcode =
        table[lookup_source].opcode;

    lookup_param =
        table[lookup_source].param;

    lookup_size =
        table[lookup_source].size;

    lookup_address =
        table[lookup_source].address;

    lookup_mask =
        table[lookup_source].mask;

    lookup_is_get =
        table[lookup_source].is_get;

    lookup_is_put =
        table[lookup_source].is_put;

    lookup_is_acquire =
        table[lookup_source].is_acquire;

    lookup_is_release =
        table[lookup_source].is_release;

    lookup_probe_active =
        table[lookup_source].probe_active;

    lookup_probe_done =
        table[lookup_source].probe_done;

    lookup_dirty_required =
        table[lookup_source].dirty_required;

    lookup_dirty_received =
        table[lookup_source].dirty_received;

    lookup_grant_sent =
        table[lookup_source].grant_sent;

    lookup_grant_data =
        table[lookup_source].grant_data;

    lookup_grant_ack =
        table[lookup_source].grant_ack;

    lookup_d_complete =
        table[lookup_source].d_complete;

    lookup_probe_expected =
        table[lookup_source].probe_expected;

    lookup_probe_received =
        table[lookup_source].probe_received;

    if (table[lookup_source].probe_expected >=
        table[lookup_source].probe_received) begin

      lookup_probe_remaining =
          table[lookup_source].probe_expected -
          table[lookup_source].probe_received;

    end
    else begin

      lookup_probe_remaining = '0;

    end

  end


  //==========================================================================
  // Probe overflow / underflow detection
  //==========================================================================

  always_comb begin

    probe_overflow = 1'b0;
    probe_underflow = 1'b0;
    invalid_probe_ack = 1'b0;

    if (probe_start_valid) begin

      if (!table[probe_start_source].valid) begin

        invalid_probe_ack = 1'b1;

      end
      else if (probe_count > MAX_PROBES) begin

        probe_overflow = 1'b1;

      end

    end


    if (probe_ack_valid) begin

      if (!table[probe_ack_source].valid) begin

        invalid_probe_ack = 1'b1;

      end
      else if (!table[probe_ack_source].probe_active) begin

        invalid_probe_ack = 1'b1;

      end
      else if (
        table[probe_ack_source].probe_received >=
        table[probe_ack_source].probe_expected
      ) begin

        probe_underflow = 1'b1;

      end

    end

  end


  //==========================================================================
  // Transaction completion determination
  //
  // The transaction is considered complete according to its class:
  //
  //   Get/Put:
  //       D completion
  //
  //   Acquire:
  //       GrantAck + required coherence work
  //
  // The coherence engine may additionally impose stronger policy.
  //==========================================================================

  logic txn_done_comb;

  always_comb begin

    txn_done_comb = 1'b0;

    for (int unsigned i = 0;
         i < NUM_SOURCES;
         i++) begin

      if (table[i].valid) begin

        if (table[i].is_acquire) begin

          if (table[i].grant_ack &&
              (
                !table[i].probe_active ||
                table[i].probe_done
              ) &&
              (
                !table[i].dirty_required ||
                table[i].dirty_received
              )) begin

            txn_done_comb = 1'b1;

          end

        end
        else begin

          if (table[i].d_complete)
            txn_done_comb = 1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Completion pulse
  //==========================================================================

  always_comb begin

    txn_complete_valid  = 1'b0;
    txn_complete_source = '0;

    for (int unsigned i = 0;
         i < NUM_SOURCES;
         i++) begin

      if (table[i].valid) begin

        if (table[i].is_acquire) begin

          if (table[i].grant_ack &&
              (
                !table[i].probe_active ||
                table[i].probe_done
              ) &&
              (
                !table[i].dirty_required ||
                table[i].dirty_received
              )) begin

            txn_complete_valid  = 1'b1;
            txn_complete_source = SOURCE_W'(i);

          end

        end
        else if (table[i].d_complete) begin

          txn_complete_valid  = 1'b1;
          txn_complete_source = SOURCE_W'(i);

        end

      end

    end

  end


  //==========================================================================
  // Outstanding transaction count
  //==========================================================================

  always_comb begin

    outstanding_count = '0;

    for (int unsigned i = 0;
         i < NUM_SOURCES;
         i++) begin

      if (table[i].valid)
        outstanding_count++;

    end

  end


  assign full =
      outstanding_count == NUM_SOURCES;

  assign empty =
      outstanding_count == 0;


  //==========================================================================
  // Timeout detection
  //==========================================================================

  always_comb begin

    timeout_valid  = 1'b0;
    timeout_source = '0;

    if (ENABLE_TIMEOUT) begin

      for (int unsigned i = 0;
           i < NUM_SOURCES;
           i++) begin

        if (table[i].valid) begin

          if (table[i].age >=
              TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

            timeout_valid  = 1'b1;
            timeout_source = SOURCE_W'(i);

          end

        end

      end

    end

  end


  //==========================================================================
  // Aggregate protocol error
  //==========================================================================

  assign protocol_error =
      duplicate_source ||
      invalid_source ||
      invalid_sink ||
      invalid_probe_ack ||
      probe_overflow ||
      probe_underflow;


  //==========================================================================
  // Sequential transaction table
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      for (int unsigned i = 0;
           i < NUM_SOURCES;
           i++) begin

        table[i] <= '0;

      end

    end
    else begin

      //======================================================================
      // Age outstanding transactions.
      //
      // Saturating counter.
      //======================================================================

      for (int unsigned i = 0;
           i < NUM_SOURCES;
           i++) begin

        if (table[i].valid) begin

          if (ENABLE_TIMEOUT) begin

            if (table[i].age <
                TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

              table[i].age <=
                  table[i].age + 1'b1;

            end

          end

        end

      end


      //======================================================================
      // Allocate new transaction.
      //======================================================================

      if (alloc_fire) begin

        table[alloc_source].valid =
            1'b1;

        table[alloc_source].state =
            TXN_A_ACCEPTED;

        table[alloc_source].sink_valid =
            1'b0;

        table[alloc_source].sink =
            '0;

        table[alloc_source].opcode =
            alloc_opcode;

        table[alloc_source].param =
            alloc_param;

        table[alloc_source].size =
            alloc_size;

        table[alloc_source].address =
            alloc_address;

        table[alloc_source].mask =
            alloc_mask;

        table[alloc_source].is_get =
            alloc_is_get;

        table[alloc_source].is_put =
            alloc_is_put;

        table[alloc_source].is_acquire =
            alloc_is_acquire;

        table[alloc_source].is_release =
            alloc_is_release;

        table[alloc_source].probe_expected =
            '0;

        table[alloc_source].probe_received =
            '0;

        table[alloc_source].probe_active =
            1'b0;

        table[alloc_source].probe_done =
            1'b0;

        table[alloc_source].dirty_required =
            1'b0;

        table[alloc_source].dirty_received =
            1'b0;

        table[alloc_source].dirty_data_valid =
            1'b0;

        table[alloc_source].grant_sent =
            1'b0;

        table[alloc_source].grant_data =
            1'b0;

        table[alloc_source].grant_ack =
            1'b0;

        table[alloc_source].d_complete =
            1'b0;

        table[alloc_source].d_opcode =
            '0;

        table[alloc_source].age =
            '0;

      end


      //======================================================================
      // Bind sink to transaction.
      //======================================================================

      if (sink_bind_valid) begin

        if (table[sink_bind_source].valid) begin

          table[sink_bind_source].sink =
              sink_bind_sink;

          table[sink_bind_source].sink_valid =
              1'b1;

          table[sink_bind_source].state =
              TXN_WAIT_GRANT;

        end

      end


      //======================================================================
      // Probe start.
      //======================================================================

      if (probe_start_valid) begin

        if (table[probe_start_source].valid) begin

          table[probe_start_source].probe_expected <=
              probe_count;

          table[probe_start_source].probe_received <=
              '0;

          table[probe_start_source].probe_active <=
              (probe_count != 0);

          table[probe_start_source].probe_done <=
              (probe_count == 0);

          table[probe_start_source].state <=
              (probe_count == 0) ?
                TXN_WAIT_GRANT :
                TXN_WAIT_PROBE;

          // A non-zero probe fanout generally means dirty data may be
          // returned by one of the probed clients. The coherence engine can
          // refine this requirement.
          table[probe_start_source].dirty_required <=
              (probe_count != 0);

        end

      end


      //======================================================================
      // Probe acknowledgement.
      //======================================================================

      if (probe_ack_valid) begin

        if (table[probe_ack_source].valid &&
            table[probe_ack_source].probe_active) begin

          if (table[probe_ack_source].probe_received <
              table[probe_ack_source].probe_expected) begin

            table[probe_ack_source].probe_received <=
                table[probe_ack_source].probe_received + 1'b1;

            if (
              table[probe_ack_source].probe_received + 1'b1 >=
              table[probe_ack_source].probe_expected
            ) begin

              table[probe_ack_source].probe_active <=
                  1'b0;

              table[probe_ack_source].probe_done <=
                  1'b1;

              table[probe_ack_source].state <=
                  TXN_WAIT_GRANT;

            end

          end

        end

      end


      //======================================================================
      // Dirty-data collection.
      //======================================================================

      if (dirty_data_valid) begin

        if (table[dirty_data_source].valid) begin

          table[dirty_data_source].dirty_received <=
              1'b1;

          table[dirty_data_source].dirty_data_valid <=
              1'b1;

          if (table[dirty_data_source].probe_active == 1'b0) begin

            table[dirty_data_source].state <=
                TXN_WAIT_GRANT;

          end

        end

      end


      //======================================================================
      // Grant accepted.
      //======================================================================

      if (grant_valid) begin

        if (table[grant_source].valid) begin

          table[grant_source].grant_sent <=
              1'b1;

          table[grant_source].grant_data <=
              grant_is_data;

          table[grant_source].state <=
              TXN_WAIT_GRANT_ACK;

        end

      end


      //======================================================================
      // GrantAck accepted.
      //======================================================================

      if (grant_ack_valid) begin

        // Search for the source associated with this sink.
        for (int unsigned i = 0;
             i < NUM_SOURCES;
             i++) begin

          if (table[i].valid &&
              table[i].sink_valid &&
              (table[i].sink == grant_ack_sink)) begin

            table[i].grant_ack <=
                1'b1;

            table[i].state <=
                TXN_COMPLETE;

          end

        end

      end


      //======================================================================
      // D completion.
      //======================================================================

      if (d_complete_valid) begin

        if (table[d_complete_source].valid) begin

          table[d_complete_source].d_complete <=
              1'b1;

          table[d_complete_source].d_opcode <=
              d_complete_opcode;

          table[d_complete_source].state <=
              TXN_COMPLETE;

        end

      end


      //======================================================================
      // Explicit abort.
      //
      // Abort is deliberately explicit and is not generated by timeout.
      //======================================================================

      if (abort_valid) begin

        if (table[abort_source].valid) begin

          table[abort_source].state <=
              TXN_ABORTED;

        end

      end


      //======================================================================
      // Final transaction retirement.
      //
      // The transaction table releases its source entry only after the
      // transaction has genuinely completed.
      //======================================================================

      for (int unsigned i = 0;
           i < NUM_SOURCES;
           i++) begin

        if (table[i].valid) begin

          if (table[i].is_acquire) begin

            if (
              table[i].grant_ack &&
              (!table[i].probe_active ||
               table[i].probe_done) &&
              (!table[i].dirty_required ||
               table[i].dirty_received)
            ) begin

              table[i].valid <=
                  1'b0;

              table[i].state <=
                  TXN_FREE;

              table[i].age <=
                  '0;

            end

          end
          else if (table[i].d_complete) begin

            table[i].valid <=
                1'b0;

            table[i].state <=
                TXN_FREE;

            table[i].age <=
                '0;

          end
          else if (table[i].state == TXN_ABORTED) begin

            table[i].valid <=
                1'b0;

            table[i].state <=
                TXN_FREE;

            table[i].age <=
                '0;

          end

        end

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_TXN_ASSERTIONS

      //======================================================================
      // No duplicate source.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |-> !table[alloc_source].valid
      )
      else $error(
        "TLC TXN TABLE: duplicate source allocation"
      );


      //======================================================================
      // Allocated transaction remains valid until completion/abort.
      //======================================================================

      property p_transaction_persistence;

        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid &&
        !abort_valid &&
        !(
          table[lookup_source].d_complete
        ) &&
        !(
          table[lookup_source].grant_ack &&
          table[lookup_source].is_acquire
        )
        |=> table[lookup_source].valid;

      endproperty

      assert property (p_transaction_persistence)
        else $error(
          "TLC TXN TABLE: transaction disappeared unexpectedly"
        );


      //======================================================================
      // Sink association only belongs to valid transaction.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].sink_valid
        |-> table[lookup_source].valid
      )
      else $error(
        "TLC TXN TABLE: sink associated with invalid transaction"
      );


      //======================================================================
      // Probe received cannot exceed expected.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid
        |-> (
          table[lookup_source].probe_received <=
          table[lookup_source].probe_expected
        )
      )
      else $error(
        "TLC TXN TABLE: probe acknowledgement overflow"
      );


      //======================================================================
      // Probe done implies all probes received.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].probe_done
        |-> (
          table[lookup_source].probe_received ==
          table[lookup_source].probe_expected
        )
      )
      else $error(
        "TLC TXN TABLE: probe_done asserted prematurely"
      );


      //======================================================================
      // GrantAck requires Grant.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].grant_ack
        |-> table[lookup_source].grant_sent
      )
      else $error(
        "TLC TXN TABLE: GrantAck without Grant"
      );


      //======================================================================
      // GrantAck requires sink.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].grant_ack
        |-> table[lookup_source].sink_valid
      )
      else $error(
        "TLC TXN TABLE: GrantAck without sink association"
      );


      //======================================================================
      // Dirty data cannot be marked received for an invalid transaction.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].dirty_received
        |-> table[lookup_source].valid
      )
      else $error(
        "TLC TXN TABLE: dirty data associated with invalid transaction"
      );


      //======================================================================
      // Acquire cannot complete before GrantAck.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid &&
        table[lookup_source].is_acquire &&
        table[lookup_source].state == TXN_COMPLETE
        |-> table[lookup_source].grant_ack
      )
      else $error(
        "TLC TXN TABLE: Acquire completed without GrantAck"
      );


      //======================================================================
      // Acquire with active probes cannot complete before ProbeDone.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid &&
        table[lookup_source].is_acquire &&
        table[lookup_source].state == TXN_COMPLETE
        |-> (
          !table[lookup_source].probe_active &&
          table[lookup_source].probe_done
        )
      )
      else $error(
        "TLC TXN TABLE: Acquire completed before probes completed"
      );


      //======================================================================
      // Outstanding count bounds.
      //======================================================================

      assert property (
        @(posedge clk)
        outstanding_count <= NUM_SOURCES
      )
      else $error(
        "TLC TXN TABLE: outstanding transaction overflow"
      );


      //======================================================================
      // Reset clears all transactions.
      //======================================================================

      assert property (
        @(posedge clk)
        !rst_n |-> (outstanding_count == 0)
      )
      else $error(
        "TLC TXN TABLE: transaction survives reset"
      );


      //======================================================================
      // No X/Z source during allocation.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_valid
        |-> !$isunknown(alloc_source)
      )
      else $error(
        "TLC TXN TABLE: X/Z allocation source"
      );


      //======================================================================
      // No X/Z sink during sink binding.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        sink_bind_valid
        |-> !$isunknown(sink_bind_sink)
      )
      else $error(
        "TLC TXN TABLE: X/Z sink binding"
      );


      //======================================================================
      // Probe counter safety.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid
        |-> (
          table[lookup_source].probe_expected <= MAX_PROBES
        )
      )
      else $error(
        "TLC TXN TABLE: probe count exceeds configured maximum"
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
        "TLC TXN TABLE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC TXN TABLE: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC TXN TABLE: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC TXN TABLE: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC TXN TABLE: SINK_W must be > 0"
      );

    if (NUM_SOURCES == 0)
      $error(
        "TLC TXN TABLE: NUM_SOURCES must be > 0"
      );

    if (NUM_SINKS == 0)
      $error(
        "TLC TXN TABLE: NUM_SINKS must be > 0"
      );

    if (MAX_PROBES == 0)
      $error(
        "TLC TXN TABLE: MAX_PROBES must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC TXN TABLE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule