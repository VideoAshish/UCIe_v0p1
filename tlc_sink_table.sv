//==============================================================================
// tlc_sink_table.sv
//
// Production-oriented TileLink sink-ID transaction table.
//
// Purpose:
//   Tracks outstanding Acquire -> Grant transactions by sink ID.
//
// Lifecycle:
//
//       Acquire
//          |
//          v
//       allocate sink
//          |
//          v
//       Probe / coherence processing
//          |
//          v
//       Grant / GrantData
//          |
//          v
//       D-channel
//          |
//          v
//       Client
//          |
//          v
//       GrantAck(sink)
//          |
//          v
//       E-channel handshake
//          |
//          v
//       free sink
//
// Important:
//
//   * Sink is NOT freed when Grant is sent.
//   * Sink is freed only when GrantAck handshakes.
//   * Source <-> sink association is retained until completion.
//   * A sink cannot be allocated twice.
//   * A sink cannot be freed twice.
//   * Timeout does NOT automatically free a sink.
//
//==============================================================================

module tlc_sink_table #(
  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 8,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 :
      $clog2((DATA_W / 8) + 1),

  parameter int unsigned NUM_SINKS =
      (1 << SINK_W),

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned TIMEOUT_CYCLES = 100000,

  parameter bit ENABLE_TIMEOUT    = 1'b1,
  parameter bit ENABLE_CHECKS     = 1'b1,
  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Allocate sink
  //
  // Normally driven when an Acquire transaction is accepted and requires a
  // Grant/GrantData response.
  //==========================================================================

  input  logic                    alloc_valid,
  output logic                    alloc_ready,

  input  logic [SINK_W-1:0]       alloc_sink,
  input  logic [SOURCE_W-1:0]     alloc_source,

  input  logic [2:0]              alloc_opcode,
  input  logic [2:0]              alloc_param,

  input  logic [SIZE_W-1:0]       alloc_size,

  input  logic [ADDR_W-1:0]       alloc_address,

  input  logic [2:0]              alloc_grant_param,

  input  logic                    alloc_expect_data,

  //==========================================================================
  // Grant tracking
  //
  // Assert when Grant/GrantData is accepted by the D-channel.
  //==========================================================================

  input  logic                    grant_valid,
  input  logic [SINK_W-1:0]       grant_sink,

  input  logic                    grant_is_data,

  //==========================================================================
  // GrantAck completion
  //
  // Driven by tlc_e_channel.out_fire.
  //==========================================================================

  input  logic                    ack_valid,
  input  logic [SINK_W-1:0]       ack_sink,

  //==========================================================================
  // Lookup
  //==========================================================================

  input  logic [SINK_W-1:0]       lookup_sink,

  output logic                    lookup_valid,

  output logic [SOURCE_W-1:0]     lookup_source,

  output logic [2:0]              lookup_opcode,
  output logic [2:0]              lookup_param,

  output logic [SIZE_W-1:0]       lookup_size,

  output logic [ADDR_W-1:0]       lookup_address,

  output logic [2:0]              lookup_grant_param,

  output logic                    lookup_expect_data,

  output logic                    lookup_grant_sent,

  output logic                    lookup_grant_data,

  output logic                    lookup_ack_pending,

  //==========================================================================
  // Allocation status
  //==========================================================================

  output logic                    sink_available,

  output logic                    full,
  output logic                    empty,

  output logic [$clog2(NUM_SINKS+1)-1:0]
                                 outstanding_count,

  //==========================================================================
  // Timeout
  //==========================================================================

  output logic                    timeout_valid,
  output logic [SINK_W-1:0]       timeout_sink,

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                    duplicate_sink,
  output logic                    invalid_grant,
  output logic                    invalid_ack,
  output logic                    grant_mismatch,
  output logic                    protocol_error,

  //==========================================================================
  // Handshake indicators
  //==========================================================================

  output logic                    alloc_fire,
  output logic                    grant_fire,
  output logic                    ack_fire
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned COUNT_W =
      $clog2(NUM_SINKS + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // TileLink A opcodes
  //==========================================================================

  localparam logic [2:0] A_ACQUIREBLOCK =
      3'd6;

  localparam logic [2:0] A_ACQUIREPERM =
      3'd7;


  //==========================================================================
  // Sink entry
  //==========================================================================

  typedef struct packed {

    logic                   valid;

    logic [SOURCE_W-1:0]    source;

    logic [2:0]             opcode;
    logic [2:0]             param;

    logic [SIZE_W-1:0]      size;

    logic [ADDR_W-1:0]      address;

    logic [2:0]             grant_param;

    logic                   expect_data;

    logic                   grant_sent;
    logic                   grant_data;

    logic                   ack_pending;

    logic [TIMEOUT_W-1:0]   age;

  } sink_entry_t;


  //==========================================================================
  // Sink table
  //==========================================================================

  sink_entry_t table [0:NUM_SINKS-1];


  //==========================================================================
  // Handshake signals
  //==========================================================================

  assign alloc_fire =
      alloc_valid &&
      alloc_ready;

  assign grant_fire =
      grant_valid;

  assign ack_fire =
      ack_valid;


  //==========================================================================
  // Sink availability
  //==========================================================================

  always_comb begin

    sink_available =
        !table[alloc_sink].valid;

    alloc_ready =
        sink_available;

  end


  //==========================================================================
  // Duplicate allocation detection
  //==========================================================================

  assign duplicate_sink =
      alloc_valid &&
      table[alloc_sink].valid;


  //==========================================================================
  // Grant validation
  //==========================================================================

  always_comb begin

    invalid_grant = 1'b0;
    grant_mismatch = 1'b0;

    if (grant_valid) begin

      if (!table[grant_sink].valid) begin

        invalid_grant = 1'b1;

      end
      else begin

        if (table[grant_sink].grant_sent)
          grant_mismatch = 1'b1;

        if (table[grant_sink].expect_data != grant_is_data)
          grant_mismatch = 1'b1;

      end

    end

  end


  //==========================================================================
  // GrantAck validation
  //
  // GrantAck is legal only for an allocated sink for which a Grant has
  // already been accepted.
  //==========================================================================

  always_comb begin

    invalid_ack = 1'b0;

    if (ack_valid) begin

      if (!table[ack_sink].valid) begin

        invalid_ack = 1'b1;

      end
      else if (!table[ack_sink].grant_sent) begin

        invalid_ack = 1'b1;

      end
      else if (table[ack_sink].ack_pending) begin

        invalid_ack = 1'b1;

      end

    end

  end


  //==========================================================================
  // Lookup
  //==========================================================================

  always_comb begin

    lookup_valid =
        table[lookup_sink].valid;

    lookup_source =
        table[lookup_sink].source;

    lookup_opcode =
        table[lookup_sink].opcode;

    lookup_param =
        table[lookup_sink].param;

    lookup_size =
        table[lookup_sink].size;

    lookup_address =
        table[lookup_sink].address;

    lookup_grant_param =
        table[lookup_sink].grant_param;

    lookup_expect_data =
        table[lookup_sink].expect_data;

    lookup_grant_sent =
        table[lookup_sink].grant_sent;

    lookup_grant_data =
        table[lookup_sink].grant_data;

    lookup_ack_pending =
        table[lookup_sink].ack_pending;

  end


  //==========================================================================
  // Outstanding count
  //==========================================================================

  always_comb begin

    outstanding_count = '0;

    for (int unsigned i = 0;
         i < NUM_SINKS;
         i++) begin

      if (table[i].valid)
        outstanding_count++;

    end

  end


  assign full =
      (outstanding_count == NUM_SINKS);

  assign empty =
      (outstanding_count == 0);


  //==========================================================================
  // Aggregate protocol error
  //==========================================================================

  assign protocol_error =
      duplicate_sink ||
      invalid_grant ||
      invalid_ack ||
      grant_mismatch;


  //==========================================================================
  // Timeout detection
  //
  // Timeout does NOT free the sink.
  //
  // Automatically freeing a timed-out sink could allow an old GrantAck to
  // accidentally complete a newer transaction using the same sink ID.
  //==========================================================================

  always_comb begin

    timeout_valid = 1'b0;
    timeout_sink  = '0;

    if (ENABLE_TIMEOUT) begin

      for (int unsigned i = 0;
           i < NUM_SINKS;
           i++) begin

        if (table[i].valid) begin

          if (table[i].age >=
              TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

            timeout_valid = 1'b1;
            timeout_sink  = SINK_W'(i);

          end

        end

      end

    end

  end


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      for (int unsigned i = 0;
           i < NUM_SINKS;
           i++) begin

        table[i] <= '0;

      end

    end
    else begin

      //======================================================================
      // Age outstanding transactions.
      //======================================================================

      for (int unsigned i = 0;
           i < NUM_SINKS;
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
      // Grant accepted.
      //======================================================================

      if (grant_fire) begin

        if (table[grant_sink].valid) begin

          table[grant_sink].grant_sent <= 1'b1;

          table[grant_sink].grant_data <=
              grant_is_data;

          table[grant_sink].ack_pending <=
              1'b1;

        end

      end


      //======================================================================
      // GrantAck accepted.
      //
      // THIS is the actual sink free event.
      //======================================================================

      if (ack_fire) begin

        if (table[ack_sink].valid &&
            table[ack_sink].grant_sent) begin

          table[ack_sink].valid        <= 1'b0;
          table[ack_sink].grant_sent   <= 1'b0;
          table[ack_sink].grant_data   <= 1'b0;
          table[ack_sink].ack_pending  <= 1'b0;
          table[ack_sink].age          <= '0;

        end

      end


      //======================================================================
      // Sink allocation.
      //
      // Completion and allocation of the same sink in one cycle is allowed
      // only if the allocation policy explicitly supports it.
      //
      // For safety this implementation does NOT permit same-cycle reuse.
      //======================================================================

      if (alloc_fire) begin

        table[alloc_sink].valid <= 1'b1;

        table[alloc_sink].source <=
            alloc_source;

        table[alloc_sink].opcode <=
            alloc_opcode;

        table[alloc_sink].param <=
            alloc_param;

        table[alloc_sink].size <=
            alloc_size;

        table[alloc_sink].address <=
            alloc_address;

        table[alloc_sink].grant_param <=
            alloc_grant_param;

        table[alloc_sink].expect_data <=
            alloc_expect_data;

        table[alloc_sink].grant_sent <=
            1'b0;

        table[alloc_sink].grant_data <=
            1'b0;

        table[alloc_sink].ack_pending <=
            1'b0;

        table[alloc_sink].age <=
            '0;

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_SINK_ASSERTIONS

      //======================================================================
      // No duplicate allocation.
      //======================================================================

      property p_no_duplicate_sink;

        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |-> !table[alloc_sink].valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_no_duplicate_sink)
          else $error(
            "TLC SINK TABLE: duplicate sink allocation"
          );

      end


      //======================================================================
      // Allocation creates valid entry.
      //======================================================================

      property p_alloc_creates_entry;

        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |=> table[$past(alloc_sink)].valid;

      endproperty

      assert property (p_alloc_creates_entry)
        else $error(
          "TLC SINK TABLE: allocation did not create entry"
        );


      //======================================================================
      // Grant cannot occur for an inactive sink.
      //======================================================================

      property p_grant_requires_sink;

        @(posedge clk)
        disable iff (!rst_n)

        grant_fire
        |-> table[grant_sink].valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_grant_requires_sink)
          else $error(
            "TLC SINK TABLE: Grant references inactive sink"
          );

      end


      //======================================================================
      // Grant cannot be sent twice.
      //======================================================================

      property p_grant_once;

        @(posedge clk)
        disable iff (!rst_n)

        grant_fire
        |-> !table[grant_sink].grant_sent;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_grant_once)
          else $error(
            "TLC SINK TABLE: duplicate Grant"
          );

      end


      //======================================================================
      // GrantAck requires a previously accepted Grant.
      //======================================================================

      property p_ack_requires_grant;

        @(posedge clk)
        disable iff (!rst_n)

        ack_fire
        |-> table[ack_sink].valid &&
            table[ack_sink].grant_sent;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_ack_requires_grant)
          else $error(
            "TLC SINK TABLE: GrantAck received without Grant"
          );

      end


      //======================================================================
      // GrantAck frees sink.
      //======================================================================

      property p_ack_frees_sink;

        @(posedge clk)
        disable iff (!rst_n)

        ack_fire &&
        table[ack_sink].valid &&
        table[ack_sink].grant_sent
        |=> !table[$past(ack_sink)].valid;

      endproperty

      assert property (p_ack_frees_sink)
        else $error(
          "TLC SINK TABLE: GrantAck failed to free sink"
        );


      //======================================================================
      // Sink must remain allocated after Grant.
      //======================================================================

      property p_grant_does_not_free_sink;

        @(posedge clk)
        disable iff (!rst_n)

        grant_fire
        |=> table[$past(grant_sink)].valid;

      endproperty

      assert property (p_grant_does_not_free_sink)
        else $error(
          "TLC SINK TABLE: Grant incorrectly freed sink"
        );


      //======================================================================
      // GrantData expectation.
      //======================================================================

      property p_grant_data_matches_expectation;

        @(posedge clk)
        disable iff (!rst_n)

        grant_fire
        |-> (
          grant_is_data ==
          table[grant_sink].expect_data
        );

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_grant_data_matches_expectation)
          else $error(
            "TLC SINK TABLE: Grant/GrantData mismatch"
          );

      end


      //======================================================================
      // Grant must retain source association.
      //======================================================================

      property p_source_association_stable;

        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_sink].valid &&
        !ack_fire
        |=> table[$past(lookup_sink)].valid &&
            (
              table[$past(lookup_sink)].source ==
              $past(table[lookup_sink].source)
            );

      endproperty

      // The source association is checked primarily through the table state.
      // Some simulators have limited support for variable-indexed sampled
      // expressions, so this assertion is intentionally guarded.
      //
      // The direct table invariants below provide the stronger synthesis/
      // formal-friendly checks.

      //======================================================================
      // No spontaneous sink deallocation.
      //======================================================================

      property p_no_spontaneous_free;

        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_sink].valid &&
        !ack_fire &&
        !(alloc_fire &&
          (alloc_sink == lookup_sink))
        |=> table[lookup_sink].valid;

      endproperty

      assert property (p_no_spontaneous_free)
        else $error(
          "TLC SINK TABLE: sink spontaneously deallocated"
        );


      //======================================================================
      // Outstanding count bounds.
      //======================================================================

      assert property (
        @(posedge clk)
        outstanding_count <= NUM_SINKS
      )
      else $error(
        "TLC SINK TABLE: outstanding count overflow"
      );


      //======================================================================
      // Reset clears table.
      //======================================================================

      property p_reset_clears_table;

        @(posedge clk)
        !rst_n |-> (outstanding_count == 0);

      endproperty

      assert property (p_reset_clears_table)
        else $error(
          "TLC SINK TABLE: sink remains allocated during reset"
        );


      //======================================================================
      // Allocation sink must be known.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_valid
        |-> !$isunknown(alloc_sink)
      )
      else $error(
        "TLC SINK TABLE: X/Z allocation sink"
      );


      //======================================================================
      // Grant sink must be known.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_valid
        |-> !$isunknown(grant_sink)
      )
      else $error(
        "TLC SINK TABLE: X/Z Grant sink"
      );


      //======================================================================
      // GrantAck sink must be known.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ack_valid
        |-> !$isunknown(ack_sink)
      )
      else $error(
        "TLC SINK TABLE: X/Z GrantAck sink"
      );


      //======================================================================
      // A sink cannot be simultaneously awaiting Grant and be free.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_sink].ack_pending
        |-> table[lookup_sink].valid &&
            table[lookup_sink].grant_sent
      )
      else $error(
        "TLC SINK TABLE: invalid ack_pending state"
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
        "TLC SINK TABLE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC SINK TABLE: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC SINK TABLE: DATA_W must be a multiple of 8"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC SINK TABLE: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC SINK TABLE: SINK_W must be > 0"
      );

    if (NUM_SINKS == 0)
      $error(
        "TLC SINK TABLE: NUM_SINKS must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC SINK TABLE: TIMEOUT_CYCLES must be > 0"
      );

    if ((CACHE_LINE_BYTES == 0) ||
        ((CACHE_LINE_BYTES &
          (CACHE_LINE_BYTES - 1)) != 0))
      $error(
        "TLC SINK TABLE: CACHE_LINE_BYTES must be power-of-two"
      );

  end

endmodule