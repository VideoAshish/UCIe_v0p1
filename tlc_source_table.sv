//==============================================================================
// tlc_source_table.sv
//
// Production-oriented TileLink source-ID transaction table.
//
// Purpose:
//
//   Tracks outstanding A-channel transactions by source ID and provides
//   transaction context for validating D-channel responses.
//
// TileLink ownership model:
//
//   A request:
//       source[N] becomes allocated.
//
//   While allocated:
//       source[N] must not be reused.
//
//   D response:
//       D.source == N
//
//   D handshake:
//       source[N] is released.
//
//==============================================================================

module tlc_source_table #(
  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 :
      $clog2((DATA_W / 8) + 1),

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned TIMEOUT_CYCLES = 100000,

  parameter bit ENABLE_TIMEOUT     = 1'b1,
  parameter bit ENABLE_ASSERTIONS  = 1'b1,
  parameter bit ENABLE_CHECKS      = 1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Allocation interface
  //
  // Connected to A-channel acceptance.
  //==========================================================================

  input  logic                   alloc_valid,
  output logic                   alloc_ready,

  input logic [SOURCE_W-1:0]     alloc_source,

  input logic [2:0]              alloc_opcode,
  input logic [2:0]              alloc_param,

  input logic [SIZE_W-1:0]       alloc_size,

  input logic [ADDR_W-1:0]       alloc_address,

  // Optional byte mask for PutFull / PutPartial tracking.
  input logic [(DATA_W/8)-1:0]   alloc_mask,

  // Transaction classification supplied by A-channel engine.
  input logic                    alloc_is_get,
  input logic                    alloc_is_put,
  input logic                    alloc_is_acquire,

  //==========================================================================
  // Completion interface
  //
  // Connected to D-channel acceptance.
  //==========================================================================

  input logic                   complete_valid,

  input logic [SOURCE_W-1:0]    complete_source,

  input logic [2:0]             complete_opcode,

  input logic                   complete_size,

  input logic                   complete_corrupt,


  //==========================================================================
  // Lookup interface
  //
  // Combinational lookup of the transaction associated with source ID.
  //==========================================================================

  input logic [SOURCE_W-1:0]     lookup_source,

  output logic                   lookup_valid,

  output logic [2:0]             lookup_opcode,
  output logic [2:0]             lookup_param,

  output logic [SIZE_W-1:0]      lookup_size,

  output logic [ADDR_W-1:0]     lookup_address,

  output logic [(DATA_W/8)-1:0] lookup_mask,

  output logic                   lookup_is_get,
  output logic                   lookup_is_put,
  output logic                   lookup_is_acquire,

  output logic                   lookup_d_expected,


  //==========================================================================
  // D-channel response validation
  //==========================================================================

  input logic [SOURCE_W-1:0]     response_source,
  input logic [2:0]              response_opcode,

  output logic                   response_source_valid,
  output logic                   response_opcode_valid,
  output logic                   response_matches,

  output logic                   response_is_data,


  //==========================================================================
  // Status
  //==========================================================================

  output logic                   source_available,

  output logic [$clog2(NUM_SOURCES+1)-1:0]
                                outstanding_count,

  output logic                   full,

  output logic                   empty,

  //==========================================================================
  // Timeout
  //==========================================================================

  output logic                   timeout_valid,
  output logic [SOURCE_W-1:0]    timeout_source,

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                   duplicate_source,
  output logic                   free_without_alloc,
  output logic                   response_mismatch,
  output logic                   protocol_error,

  //==========================================================================
  // Handshakes
  //==========================================================================

  output logic                   alloc_fire,
  output logic                   complete_fire
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned COUNT_W =
      $clog2(NUM_SOURCES + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ? 1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // TileLink opcodes
  //
  // A channel
  //==========================================================================

  localparam logic [2:0] A_GET =
      3'd4;

  localparam logic [2:0] A_PUTFULL =
      3'd0;

  localparam logic [2:0] A_PUTPARTIAL =
      3'd1;

  localparam logic [2:0] A_ARITHMETIC =
      3'd2;

  localparam logic [2:0] A_LOGICAL =
      3'd3;

  localparam logic [2:0] A_ACQUIREBLOCK =
      3'd6;

  localparam logic [2:0] A_ACQUIREPERM =
      3'd7;


  //==========================================================================
  // D channel
  //==========================================================================

  localparam logic [2:0] D_ACCESSACK =
      3'd0;

  localparam logic [2:0] D_ACCESSACKDATA =
      3'd1;

  localparam logic [2:0] D_HINTACK =
      3'd2;

  localparam logic [2:0] D_GRANT =
      3'd4;

  localparam logic [2:0] D_GRANTDATA =
      3'd5;

  localparam logic [2:0] D_RELEASEACK =
      3'd6;


  //==========================================================================
  // Entry
  //==========================================================================

  typedef struct packed {

    logic                   valid;

    logic [2:0]             opcode;
    logic [2:0]             param;

    logic [SIZE_W-1:0]      size;

    logic [ADDR_W-1:0]      address;

    logic [BYTE_W-1:0]     mask;

    logic                   is_get;
    logic                   is_put;
    logic                   is_acquire;

    logic                   d_expected;

    logic                   d_data_expected;

    logic [TIMEOUT_W-1:0]   age;

  } source_entry_t;


  //==========================================================================
  // Source table
  //==========================================================================

  source_entry_t table [0:NUM_SOURCES-1];


  //==========================================================================
  // Allocation / completion
  //==========================================================================

  assign alloc_fire =
      alloc_valid &&
      alloc_ready;


  assign complete_fire =
      complete_valid;


  //==========================================================================
  // Source availability
  //==========================================================================

  always_comb begin

    source_available =
        !table[alloc_source].valid;

    alloc_ready =
        source_available;

  end


  //==========================================================================
  // Duplicate detection
  //==========================================================================

  assign duplicate_source =
      alloc_valid &&
      table[alloc_source].valid;


  //==========================================================================
  // Lookup
  //==========================================================================

  always_comb begin

    lookup_valid =
        table[lookup_source].valid;

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

    lookup_d_expected =
        table[lookup_source].d_expected;

  end


  //==========================================================================
  // Response source validation
  //==========================================================================

  assign response_source_valid =
      table[response_source].valid;


  //==========================================================================
  // Expected D opcode
  //
  // Determine the legal D response based on the original A request.
  //
  // This is intentionally structural. Semantic permission checking for
  // Acquire/Grant is handled by the coherence engine.
  //==========================================================================

  logic [2:0] expected_d_opcode;

  always_comb begin

    expected_d_opcode = D_ACCESSACK;

    case (table[response_source].opcode)

      A_GET:
        expected_d_opcode = D_ACCESSACKDATA;

      A_PUTFULL,
      A_PUTPARTIAL,
      A_ARITHMETIC,
      A_LOGICAL:
        expected_d_opcode = D_ACCESSACK;

      A_ACQUIREBLOCK,
      A_ACQUIREPERM:

        if (table[response_source].d_data_expected)
          expected_d_opcode = D_GRANTDATA;
        else
          expected_d_opcode = D_GRANT;

      default:
        expected_d_opcode = D_ACCESSACK;

    endcase

  end


  //==========================================================================
  // Response opcode validation
  //==========================================================================

  always_comb begin

    response_opcode_valid = 1'b0;

    if (response_source_valid) begin

      case (response_opcode)

        D_ACCESSACK,
        D_ACCESSACKDATA,
        D_HINTACK,
        D_GRANT,
        D_GRANTDATA,
        D_RELEASEACK:

          response_opcode_valid = 1'b1;

        default:

          response_opcode_valid = 1'b0;

      endcase

    end

  end


  //==========================================================================
  // Data response classification
  //==========================================================================

  assign response_is_data =
      (response_opcode == D_ACCESSACKDATA) ||
      (response_opcode == D_GRANTDATA);


  //==========================================================================
  // Response relationship checking
  //
  // We allow the complete set of legal D responses structurally. The exact
  // semantic response relationship can be tightened according to the
  // TileLink client capabilities used by the surrounding implementation.
  //==========================================================================

  always_comb begin

    response_matches = 1'b0;

    if (response_source_valid &&
        response_opcode_valid) begin

      case (table[response_source].opcode)

        A_GET: begin

          response_matches =
              (response_opcode == D_ACCESSACKDATA);

        end

        A_PUTFULL,
        A_PUTPARTIAL: begin

          response_matches =
              (response_opcode == D_ACCESSACK);

        end

        A_ARITHMETIC,
        A_LOGICAL: begin

          response_matches =
              (response_opcode == D_ACCESSACKDATA) ||
              (response_opcode == D_ACCESSACK);

        end

        A_ACQUIREBLOCK,
        A_ACQUIREPERM: begin

          response_matches =
              (response_opcode == D_GRANT) ||
              (response_opcode == D_GRANTDATA);

        end

        default: begin

          response_matches = 1'b0;

        end

      endcase

    end

  end


  //==========================================================================
  // Response mismatch
  //==========================================================================

  assign response_mismatch =
      complete_valid &&
      (
        !response_source_valid ||
        !response_opcode_valid ||
        !response_matches
      );


  //==========================================================================
  // Free without allocation
  //==========================================================================

  assign free_without_alloc =
      complete_valid &&
      !table[complete_source].valid;


  //==========================================================================
  // Outstanding count
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
      (outstanding_count == NUM_SOURCES);

  assign empty =
      (outstanding_count == 0);


  //==========================================================================
  // Protocol error
  //==========================================================================

  assign protocol_error =
      duplicate_source ||
      free_without_alloc ||
      response_mismatch;


  //==========================================================================
  // Timeout logic
  //
  // One age counter exists per source entry.
  //
  // Once an entry reaches TIMEOUT_CYCLES it generates timeout_valid.
  //
  // The entry is NOT automatically freed.
  //
  // This is intentional: freeing a timed-out source automatically can cause
  // source-ID aliasing with a still-live transaction.
  //==========================================================================

  always_comb begin

    timeout_valid  = 1'b0;
    timeout_source = '0;

    if (ENABLE_TIMEOUT) begin

      for (int unsigned i = 0;
           i < NUM_SOURCES;
           i++) begin

        if (table[i].valid) begin

          if (table[i].age >= TIMEOUT_CYCLES[TIMEOUT_W-1:0]) begin

            timeout_valid  = 1'b1;
            timeout_source = SOURCE_W'(i);

          end

        end

      end

    end

  end


  //==========================================================================
  // Sequential table management
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

      //----------------------------------------------------------------------
      // Age outstanding transactions.
      //
      // Saturating counter prevents wraparound.
      //----------------------------------------------------------------------

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


      //----------------------------------------------------------------------
      // Completion.
      //
      // Completion is processed before allocation for the same source so
      // that a source can be released and immediately reused in a controlled
      // single-cycle pipeline.
      //----------------------------------------------------------------------

      if (complete_fire) begin

        if (table[complete_source].valid) begin

          table[complete_source].valid <= 1'b0;
          table[complete_source].age   <= '0;

        end

      end


      //----------------------------------------------------------------------
      // Allocation.
      //
      // A source cannot normally be allocated while occupied.
      //
      // The explicit same-cycle completion case is allowed.
      //----------------------------------------------------------------------

      if (alloc_fire) begin

        table[alloc_source].valid <= 1'b1;

        table[alloc_source].opcode <=
            alloc_opcode;

        table[alloc_source].param <=
            alloc_param;

        table[alloc_source].size <=
            alloc_size;

        table[alloc_source].address <=
            alloc_address;

        table[alloc_source].mask <=
            alloc_mask;

        table[alloc_source].is_get <=
            alloc_is_get;

        table[alloc_source].is_put <=
            alloc_is_put;

        table[alloc_source].is_acquire <=
            alloc_is_acquire;

        table[alloc_source].d_expected <=
            1'b1;

        table[alloc_source].d_data_expected <=
            (
              alloc_opcode == A_GET
            ) ||
            (
              alloc_opcode == A_ACQUIREBLOCK
            );

        table[alloc_source].age <=
            '0;

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_SOURCE_ASSERTIONS

      //======================================================================
      // No duplicate allocation
      //======================================================================

      property p_no_duplicate_source;

        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |-> !table[alloc_source].valid ||
            complete_fire &&
            (complete_source == alloc_source);

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_no_duplicate_source)
          else $error(
            "TLC SOURCE TABLE: duplicate source allocation"
          );

      end


      //======================================================================
      // Every accepted allocation creates a valid entry.
      //======================================================================

      property p_alloc_creates_entry;

        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |=> table[$past(alloc_source)].valid;

      endproperty

      assert property (p_alloc_creates_entry)
        else $error(
          "TLC SOURCE TABLE: allocation did not create entry"
        );


      //======================================================================
      // Completion must reference an allocated source.
      //======================================================================

      property p_completion_allocated;

        @(posedge clk)
        disable iff (!rst_n)

        complete_fire
        |-> table[complete_source].valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_completion_allocated)
          else $error(
            "TLC SOURCE TABLE: completion for unallocated source"
          );

      end


      //======================================================================
      // Response source must be allocated.
      //======================================================================

      property p_response_source_valid;

        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> table[complete_source].valid;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_response_source_valid)
          else $error(
            "TLC SOURCE TABLE: D response references inactive source"
          );

      end


      //======================================================================
      // GET must receive AccessAckData.
      //======================================================================

      property p_get_response;

        @(posedge clk)
        disable iff (!rst_n)

        complete_fire &&
        (table[complete_source].opcode == A_GET)
        |-> complete_opcode == D_ACCESSACKDATA;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_get_response)
          else $error(
            "TLC SOURCE TABLE: GET received illegal D response"
          );

      end


      //======================================================================
      // PUT must receive AccessAck.
      //======================================================================

      property p_put_response;

        @(posedge clk)
        disable iff (!rst_n)

        complete_fire &&
        (
          (table[complete_source].opcode == A_PUTFULL) ||
          (table[complete_source].opcode == A_PUTPARTIAL)
        )
        |-> complete_opcode == D_ACCESSACK;

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_put_response)
          else $error(
            "TLC SOURCE TABLE: PUT received illegal D response"
          );

      end


      //======================================================================
      // Acquire must receive Grant/GrantData.
      //======================================================================

      property p_acquire_response;

        @(posedge clk)
        disable iff (!rst_n)

        complete_fire &&
        (
          (table[complete_source].opcode == A_ACQUIREBLOCK) ||
          (table[complete_source].opcode == A_ACQUIREPERM)
        )
        |-> (
          (complete_opcode == D_GRANT) ||
          (complete_opcode == D_GRANTDATA)
        );

      endproperty

      if (ENABLE_CHECKS) begin

        assert property (p_acquire_response)
          else $error(
            "TLC SOURCE TABLE: Acquire received illegal D response"
          );

      end


      //======================================================================
      // Source entry remains valid until completion.
      //======================================================================

      property p_source_not_spontaneously_freed;

        @(posedge clk)
        disable iff (!rst_n)

        table[lookup_source].valid &&
        !complete_fire &&
        !(alloc_fire &&
          (alloc_source == lookup_source))
        |=> table[lookup_source].valid;

      endproperty

      assert property (p_source_not_spontaneously_freed)
        else $error(
          "TLC SOURCE TABLE: source entry unexpectedly freed"
        );


      //======================================================================
      // Outstanding count bounds.
      //======================================================================

      assert property (
        @(posedge clk)
        outstanding_count <= NUM_SOURCES
      )
      else $error(
        "TLC SOURCE TABLE: outstanding count overflow"
      );


      //======================================================================
      // Reset must clear all entries.
      //======================================================================

      property p_reset_clears_table;

        @(posedge clk)
        !rst_n
        |-> (outstanding_count == 0);

      endproperty

      assert property (p_reset_clears_table)
        else $error(
          "TLC SOURCE TABLE: entries remain allocated during reset"
        );


      //======================================================================
      // Valid source IDs contain known values.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> !$isunknown(complete_source)
      )
      else $error(
        "TLC SOURCE TABLE: X/Z completion source"
      );


      //======================================================================
      // Allocation source must be known.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_valid
        |-> !$isunknown(alloc_source)
      )
      else $error(
        "TLC SOURCE TABLE: X/Z allocation source"
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
        "TLC SOURCE TABLE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC SOURCE TABLE: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC SOURCE TABLE: DATA_W must be a multiple of 8"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC SOURCE TABLE: SOURCE_W must be > 0"
      );

    if (NUM_SOURCES == 0)
      $error(
        "TLC SOURCE TABLE: NUM_SOURCES must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC SOURCE TABLE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule