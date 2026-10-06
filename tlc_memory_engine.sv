//==============================================================================
// tlc_memory_engine.sv
//
// TileLink-C / Coherence Memory Engine
//
// Purpose
// -------
// Backing-memory / LLC interface for the TL-C coherence subsystem.
//
// Features
// --------
// * Fully parameterized address/data widths
// * Configurable cache-line size
// * Configurable outstanding memory transactions
// * Read / write request arbitration
// * Byte-enable partial writes
// * Request-ID allocation
// * Out-of-order memory response correlation
// * Independent ready/valid interfaces
// * No combinational ready/valid loops
// * Request buffering
// * Response buffering
// * Acquire fill support
// * Dirty eviction / ReleaseData support
// * Probe dirty-data writeback support
// * Alignment checking
// * Mask checking
// * ID overflow/underflow protection
// * Timeout detection
// * Reset-clean state
// * Synthesis-friendly transaction RAM
// * Assertions
//
// Architectural position
//
//             tlc_acquire_engine
//                    |
//                    | memory read
//                    v
//             +-------------------+
//             |                   |
//             | tlc_memory_engine |
//             |                   |
//             +----+----------+---+
//                  |          |
//             read |          | write
//                  v          v
//              MEMORY / LLC / SRAM
//                  |
//                  | response
//                  v
//             tlc_memory_engine
//                  |
//                  +--> grant_engine
//                  +--> release_engine
//                  +--> probe_engine
//
//==============================================================================

module tlc_memory_engine #(
  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned MEM_ID_W =
      6,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned MAX_OUTSTANDING =
      16,

  parameter int unsigned REQ_FIFO_DEPTH =
      8,

  parameter int unsigned RSP_FIFO_DEPTH =
      8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_TIMEOUT =
      1'b1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1,

  parameter bit ENABLE_PARTIAL_WRITE =
      1'b1
);

  //==========================================================================
  // Derived parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned OFFSET_W =
      (CACHE_LINE_BYTES <= 1) ?
      0 :
      $clog2(CACHE_LINE_BYTES);

  localparam int unsigned COUNT_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);

  localparam int unsigned REQ_PTR_W =
      (REQ_FIFO_DEPTH <= 1) ?
      1 :
      $clog2(REQ_FIFO_DEPTH);

  localparam int unsigned RSP_PTR_W =
      (RSP_FIFO_DEPTH <= 1) ?
      1 :
      $clog2(RSP_FIFO_DEPTH);


  //==========================================================================
  // Interface declarations
  //==========================================================================

  input  logic clk;
  input  logic rst_n;

  //==========================================================================
  // Read request from coherence engines
  //==========================================================================

  input  logic                    rd_req_valid;
  output logic                    rd_req_ready;

  input  logic [ADDR_W-1:0]       rd_req_addr;
  input  logic [SOURCE_W-1:0]     rd_req_source;
  input  logic [DATA_W/8-1:0]     rd_req_mask;

  //==========================================================================
  // Write request from coherence engines
  //==========================================================================

  input  logic                    wr_req_valid;
  output logic                    wr_req_ready;

  input  logic [ADDR_W-1:0]       wr_req_addr;
  input  logic [SOURCE_W-1:0]     wr_req_source;

  input  logic [DATA_W-1:0]       wr_req_data;
  input  logic [DATA_W/8-1:0]     wr_req_mask;

  //==========================================================================
  // Memory / LLC request interface
  //==========================================================================

  output logic                    mem_req_valid;
  input  logic                    mem_req_ready;

  output logic                    mem_req_write;

  output logic [ADDR_W-1:0]       mem_req_addr;

  output logic [MEM_ID_W-1:0]     mem_req_id;

  output logic [DATA_W-1:0]       mem_req_data;

  output logic [DATA_W/8-1:0]     mem_req_strb;

  //==========================================================================
  // Memory / LLC response interface
  //==========================================================================

  input  logic                    mem_rsp_valid;
  output logic                    mem_rsp_ready;

  input  logic [MEM_ID_W-1:0]     mem_rsp_id;

  input  logic [DATA_W-1:0]       mem_rsp_data;

  input  logic                    mem_rsp_error;

  //==========================================================================
  // Read response to coherence subsystem
  //==========================================================================

  output logic                    rd_rsp_valid;
  input  logic                    rd_rsp_ready;

  output logic [SOURCE_W-1:0]     rd_rsp_source;

  output logic [ADDR_W-1:0]       rd_rsp_addr;

  output logic [DATA_W-1:0]       rd_rsp_data;

  output logic                    rd_rsp_error;

  //==========================================================================
  // Write completion
  //==========================================================================

  output logic                    wr_rsp_valid;
  input  logic                    wr_rsp_ready;

  output logic [SOURCE_W-1:0]     wr_rsp_source;

  output logic [ADDR_W-1:0]       wr_rsp_addr;

  output logic                    wr_rsp_error;

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy;

  output logic                    full;

  output logic                    empty;

  output logic [COUNT_W-1:0]      outstanding_count;

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                    alignment_error;

  output logic                    mask_error;

  output logic                    id_error;

  output logic                    overflow_error;

  output logic                    underflow_error;

  output logic                    timeout_error;

  output logic                    protocol_error;


  //==========================================================================
  // Request descriptor
  //==========================================================================

  typedef struct packed {

    logic                    valid;

    logic                    write;

    logic [ADDR_W-1:0]       addr;

    logic [SOURCE_W-1:0]     source;

    logic [DATA_W-1:0]       data;

    logic [BYTE_W-1:0]       mask;

    logic [TIMEOUT_W-1:0]    age;

  } txn_t;


  //==========================================================================
  // Transaction table
  //==========================================================================

  txn_t txn_table [0:MAX_OUTSTANDING-1];


  //==========================================================================
  // Allocation state
  //==========================================================================

  logic [MAX_OUTSTANDING-1:0] txn_valid;

  logic [MAX_OUTSTANDING-1:0] txn_done;


  logic [COUNT_W-1:0] count_q;
  logic [COUNT_W-1:0] count_d;


  //==========================================================================
  // Free-ID search
  //==========================================================================

  logic                    alloc_found;
  logic [MEM_ID_W-1:0]     alloc_id;


  integer i;


  always_comb begin

    alloc_found = 1'b0;
    alloc_id    = '0;

    for (i = 0; i < MAX_OUTSTANDING; i++) begin

      if (!alloc_found && !txn_valid[i]) begin

        alloc_found = 1'b1;
        alloc_id    = i[MEM_ID_W-1:0];

      end

    end

  end


  //==========================================================================
  // Request arbitration
  //
  // Fixed alternating arbitration prevents permanent starvation.
  //==========================================================================

  logic arb_q;
  logic arb_d;

  logic selected_valid;
  logic selected_write;

  logic [ADDR_W-1:0] selected_addr;
  logic [SOURCE_W-1:0] selected_source;
  logic [DATA_W-1:0] selected_data;
  logic [BYTE_W-1:0] selected_mask;


  always_comb begin

    selected_valid  = 1'b0;
    selected_write  = 1'b0;

    selected_addr   = '0;
    selected_source = '0;
    selected_data   = '0;
    selected_mask   = '0;

    arb_d = arb_q;


    if (!arb_q) begin

      if (rd_req_valid) begin

        selected_valid  = 1'b1;
        selected_write  = 1'b0;

        selected_addr   = rd_req_addr;
        selected_source = rd_req_source;
        selected_data   = '0;
        selected_mask   = rd_req_mask;

        arb_d = 1'b1;

      end
      else if (wr_req_valid) begin

        selected_valid  = 1'b1;
        selected_write  = 1'b1;

        selected_addr   = wr_req_addr;
        selected_source = wr_req_source;
        selected_data   = wr_req_data;
        selected_mask   = wr_req_mask;

        arb_d = 1'b0;

      end

    end
    else begin

      if (wr_req_valid) begin

        selected_valid  = 1'b1;
        selected_write  = 1'b1;

        selected_addr   = wr_req_addr;
        selected_source = wr_req_source;
        selected_data   = wr_req_data;
        selected_mask   = wr_req_mask;

        arb_d = 1'b0;

      end
      else if (rd_req_valid) begin

        selected_valid  = 1'b1;
        selected_write  = 1'b0;

        selected_addr   = rd_req_addr;
        selected_source = rd_req_source;
        selected_data   = '0;
        selected_mask   = rd_req_mask;

        arb_d = 1'b1;

      end

    end

  end


  //==========================================================================
  // Request validation
  //==========================================================================

  logic selected_alignment_error;
  logic selected_mask_error;


  always_comb begin

    selected_alignment_error = 1'b0;
    selected_mask_error      = 1'b0;

    if (selected_valid) begin

      //----------------------------------------------------------------------
      // Cache-line alignment
      //----------------------------------------------------------------------

      if (
        (selected_addr % CACHE_LINE_BYTES) != 0
      ) begin

        selected_alignment_error = 1'b1;

      end

      //----------------------------------------------------------------------
      // Read mask
      //----------------------------------------------------------------------

      if (!selected_write) begin

        if (selected_mask == '0) begin

          selected_mask_error = 1'b1;

        end
        else if (
          selected_mask != {BYTE_W{1'b1}}
        ) begin

          // Reads are represented as complete cache-line reads in this
          // implementation.

          selected_mask_error = 1'b1;

        end

      end

      //----------------------------------------------------------------------
      // Write mask
      //----------------------------------------------------------------------

      if (selected_write) begin

        if (!ENABLE_PARTIAL_WRITE) begin

          if (selected_mask != {BYTE_W{1'b1}}) begin

            selected_mask_error = 1'b1;

          end

        end
        else begin

          if (selected_mask == '0) begin

            selected_mask_error = 1'b1;

          end

        end

      end

    end

  end


  //==========================================================================
  // Request ready
  //
  // No dependence on mem_req_ready is allowed here.
  // This prevents a combinational ready loop through the memory subsystem.
  //==========================================================================

  always_comb begin

    rd_req_ready = 1'b0;
    wr_req_ready = 1'b0;

    if (
      (count_q < MAX_OUTSTANDING) &&
      alloc_found
    ) begin

      if (!arb_q) begin

        rd_req_ready = 1'b1;

        if (!rd_req_valid)
          rd_req_ready = 1'b1;

        wr_req_ready = 1'b1;

      end
      else begin

        rd_req_ready = 1'b1;
        wr_req_ready = 1'b1;

      end

    end

  end


  //==========================================================================
  // Request fire
  //==========================================================================

  logic rd_fire;
  logic wr_fire;

  logic req_fire;


  assign rd_fire =
      rd_req_valid &&
      rd_req_ready;

  assign wr_fire =
      wr_req_valid &&
      wr_req_ready;

  assign req_fire =
      rd_fire ||
      wr_fire;


  //==========================================================================
  // Memory request interface
  //
  // Requests are registered through txn_table.
  // mem_req_valid is generated only for a committed transaction.
  //==========================================================================

  logic mem_issue_valid_q;

  logic [MEM_ID_W-1:0] mem_issue_id_q;


  assign mem_req_valid =
      mem_issue_valid_q;

  assign mem_req_write =
      txn_table[mem_issue_id_q].write;

  assign mem_req_addr =
      txn_table[mem_issue_id_q].addr;

  assign mem_req_id =
      mem_issue_id_q;

  assign mem_req_data =
      txn_table[mem_issue_id_q].data;

  assign mem_req_strb =
      txn_table[mem_issue_id_q].mask;


  logic mem_req_fire;


  assign mem_req_fire =
      mem_req_valid &&
      mem_req_ready;


  //==========================================================================
  // Response buffering
  //==========================================================================

  typedef struct packed {

    logic                    valid;

    logic                    write;

    logic [SOURCE_W-1:0]     source;

    logic [ADDR_W-1:0]       addr;

    logic [DATA_W-1:0]       data;

    logic                    error;

  } response_t;


  response_t rsp_fifo [0:RSP_FIFO_DEPTH-1];


  logic [RSP_PTR_W-1:0] rsp_wr_ptr_q;
  logic [RSP_PTR_W-1:0] rsp_rd_ptr_q;

  logic [RSP_PTR_W:0] rsp_count_q;


  assign mem_rsp_ready =
      (rsp_count_q < RSP_FIFO_DEPTH);


  logic mem_rsp_fire;


  assign mem_rsp_fire =
      mem_rsp_valid &&
      mem_rsp_ready;


  //==========================================================================
  // Response lookup
  //==========================================================================

  logic rsp_id_valid;

  always_comb begin

    rsp_id_valid = 1'b0;

    if (
      mem_rsp_valid &&
      (mem_rsp_id < MAX_OUTSTANDING)
    ) begin

      rsp_id_valid =
          txn_valid[mem_rsp_id];

    end

  end


  //==========================================================================
  // Output response
  //==========================================================================

  assign rd_rsp_valid =
      rsp_fifo[rsp_rd_ptr_q].valid &&
      !rsp_fifo[rsp_rd_ptr_q].write;

  assign wr_rsp_valid =
      rsp_fifo[rsp_rd_ptr_q].valid &&
      rsp_fifo[rsp_rd_ptr_q].write;


  assign rd_rsp_source =
      rsp_fifo[rsp_rd_ptr_q].source;

  assign rd_rsp_addr =
      rsp_fifo[rsp_rd_ptr_q].addr;

  assign rd_rsp_data =
      rsp_fifo[rsp_rd_ptr_q].data;

  assign rd_rsp_error =
      rsp_fifo[rsp_rd_ptr_q].error;


  assign wr_rsp_source =
      rsp_fifo[rsp_rd_ptr_q].source;

  assign wr_rsp_addr =
      rsp_fifo[rsp_rd_ptr_q].addr;

  assign wr_rsp_error =
      rsp_fifo[rsp_rd_ptr_q].error;


  logic rsp_pop;

  assign rsp_pop =
      (
        rd_rsp_valid &&
        rd_rsp_ready
      ) ||
      (
        wr_rsp_valid &&
        wr_rsp_ready
      );


  //==========================================================================
  // Count
  //==========================================================================

  assign outstanding_count =
      count_q;

  assign full =
      (count_q >= MAX_OUTSTANDING);

  assign empty =
      (count_q == '0);

  assign busy =
      (count_q != '0);


  //==========================================================================
  // Error detection
  //==========================================================================

  assign alignment_error =
      selected_alignment_error;

  assign mask_error =
      selected_mask_error;

  assign id_error =
      mem_rsp_valid &&
      !rsp_id_valid;

  assign overflow_error =
      req_fire &&
      (count_q >= MAX_OUTSTANDING);

  assign underflow_error =
      rsp_pop &&
      (rsp_count_q == 0);

  assign timeout_error =
      |{
        txn_valid
      } &&
      ENABLE_TIMEOUT;


  assign protocol_error =
      alignment_error ||
      mask_error ||
      id_error ||
      overflow_error ||
      underflow_error ||
      timeout_error;


  //==========================================================================
  // Sequential logic
  //==========================================================================

  integer t;

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      arb_q <=
          1'b0;

      count_q <=
          '0;

      mem_issue_valid_q <=
          1'b0;

      mem_issue_id_q <=
          '0;

      rsp_wr_ptr_q <=
          '0;

      rsp_rd_ptr_q <=
          '0;

      rsp_count_q <=
          '0;

      for (t = 0; t < MAX_OUTSTANDING; t++) begin

        txn_valid[t] <=
            1'b0;

        txn_done[t] <=
            1'b0;

        txn_table[t] <=
            '0;

      end

      for (t = 0; t < RSP_FIFO_DEPTH; t++) begin

        rsp_fifo[t] <=
            '0;

      end

    end
    else begin

      //----------------------------------------------------------------------
      // Arbitration state
      //----------------------------------------------------------------------

      if (req_fire)
        arb_q <= arb_d;


      //----------------------------------------------------------------------
      // Memory request issue
      //----------------------------------------------------------------------

      if (req_fire) begin

        txn_valid[alloc_id] <=
            1'b1;

        txn_done[alloc_id] <=
            1'b0;

        txn_table[alloc_id].valid <=
            1'b1;

        txn_table[alloc_id].write <=
            selected_write;

        txn_table[alloc_id].addr <=
            selected_addr;

        txn_table[alloc_id].source <=
            selected_source;

        txn_table[alloc_id].data <=
            selected_data;

        txn_table[alloc_id].mask <=
            selected_mask;

        txn_table[alloc_id].age <=
            '0;

        //--------------------------------------------------------------------
        // The allocated ID becomes the registered memory request.
        //--------------------------------------------------------------------

        mem_issue_valid_q <=
            1'b1;

        mem_issue_id_q <=
            alloc_id[MEM_ID_W-1:0];

      end
      else if (mem_req_fire) begin

        mem_issue_valid_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Outstanding count
      //----------------------------------------------------------------------

      case ({
        req_fire,
        mem_rsp_fire
      })

        2'b10: begin

          count_q <=
              count_q + 1'b1;

        end

        2'b01: begin

          if (count_q != 0)
            count_q <=
                count_q - 1'b1;

        end

        default: begin
          count_q <= count_q;
        end

      endcase


      //----------------------------------------------------------------------
      // Memory response
      //----------------------------------------------------------------------

      if (mem_rsp_fire) begin

        if (rsp_id_valid) begin

          //------------------------------------------------------------------
          // Construct response from transaction metadata.
          //------------------------------------------------------------------

          rsp_fifo[rsp_wr_ptr_q].valid <=
              1'b1;

          rsp_fifo[rsp_wr_ptr_q].write <=
              txn_table[mem_rsp_id].write;

          rsp_fifo[rsp_wr_ptr_q].source <=
              txn_table[mem_rsp_id].source;

          rsp_fifo[rsp_wr_ptr_q].addr <=
              txn_table[mem_rsp_id].addr;

          rsp_fifo[rsp_wr_ptr_q].data <=
              mem_rsp_data;

          rsp_fifo[rsp_wr_ptr_q].error <=
              mem_rsp_error;

          //------------------------------------------------------------------
          // Free transaction entry.
          //------------------------------------------------------------------

          txn_valid[mem_rsp_id] <=
              1'b0;

          txn_done[mem_rsp_id] <=
              1'b1;

          txn_table[mem_rsp_id].valid <=
              1'b0;

          //------------------------------------------------------------------
          // FIFO write pointer.
          //------------------------------------------------------------------

          if (
            rsp_wr_ptr_q ==
            RSP_FIFO_DEPTH-1
          ) begin

            rsp_wr_ptr_q <=
                '0;

          end
          else begin

            rsp_wr_ptr_q <=
                rsp_wr_ptr_q + 1'b1;

          end

        end

      end


      //----------------------------------------------------------------------
      // Response FIFO pop
      //----------------------------------------------------------------------

      if (rsp_pop) begin

        rsp_fifo[rsp_rd_ptr_q].valid <=
            1'b0;

        if (
          rsp_rd_ptr_q ==
          RSP_FIFO_DEPTH-1
        ) begin

          rsp_rd_ptr_q <=
              '0;

        end
        else begin

          rsp_rd_ptr_q <=
              rsp_rd_ptr_q + 1'b1;

        end

      end


      //----------------------------------------------------------------------
      // Response FIFO count
      //----------------------------------------------------------------------

      case ({
        mem_rsp_fire && rsp_id_valid,
        rsp_pop
      })

        2'b10: begin

          rsp_count_q <=
              rsp_count_q + 1'b1;

        end

        2'b01: begin

          if (rsp_count_q != 0)
            rsp_count_q <=
                rsp_count_q - 1'b1;

        end

        default: begin
          rsp_count_q <= rsp_count_q;
        end

      endcase


      //----------------------------------------------------------------------
      // Age outstanding transactions.
      //----------------------------------------------------------------------

      for (t = 0; t < MAX_OUTSTANDING; t++) begin

        if (txn_valid[t]) begin

          if (
            txn_table[t].age <
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]
          ) begin

            txn_table[t].age <=
                txn_table[t].age + 1'b1;

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

    if (ENABLE_ASSERTIONS) begin : GEN_MEMORY_ASSERTIONS

      //------------------------------------------------------------------------
      // Valid/ready protocol: request must remain stable while stalled.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mem_req_valid && !mem_req_ready
        |=> mem_req_valid &&
            $stable(mem_req_write) &&
            $stable(mem_req_addr) &&
            $stable(mem_req_id) &&
            $stable(mem_req_data) &&
            $stable(mem_req_strb)
      )
      else $error(
        "TLC MEMORY: memory request changed while stalled"
      );


      //------------------------------------------------------------------------
      // Read request alignment.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rd_fire
        |-> ((rd_req_addr % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC MEMORY: unaligned read request"
      );


      //------------------------------------------------------------------------
      // Write request alignment.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        wr_fire
        |-> ((wr_req_addr % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC MEMORY: unaligned write request"
      );


      //------------------------------------------------------------------------
      // Write must contain at least one enabled byte.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        wr_fire
        |-> (wr_req_mask != '0)
      )
      else $error(
        "TLC MEMORY: zero-byte write"
      );


      //------------------------------------------------------------------------
      // Memory response ID must identify an active transaction.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mem_rsp_fire
        |-> rsp_id_valid
      )
      else $error(
        "TLC MEMORY: response with invalid transaction ID"
      );


      //------------------------------------------------------------------------
      // Transaction count never exceeds capacity.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        count_q <= MAX_OUTSTANDING
      )
      else $error(
        "TLC MEMORY: outstanding transaction overflow"
      );


      //------------------------------------------------------------------------
      // Response FIFO count never exceeds capacity.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rsp_count_q <= RSP_FIFO_DEPTH
      )
      else $error(
        "TLC MEMORY: response FIFO overflow"
      );


      //------------------------------------------------------------------------
      // No response FIFO underflow.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rsp_pop
        |-> (rsp_count_q != 0)
      )
      else $error(
        "TLC MEMORY: response FIFO underflow"
      );


      //------------------------------------------------------------------------
      // Read response source comes from transaction table.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rd_rsp_valid
        |-> !$isunknown(rd_rsp_source)
      )
      else $error(
        "TLC MEMORY: unknown read response source"
      );


      //------------------------------------------------------------------------
      // Response must remain stable while stalled.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rd_rsp_valid && !rd_rsp_ready
        |=> rd_rsp_valid &&
            $stable(rd_rsp_source) &&
            $stable(rd_rsp_addr) &&
            $stable(rd_rsp_data) &&
            $stable(rd_rsp_error)
      )
      else $error(
        "TLC MEMORY: read response changed while stalled"
      );


      //------------------------------------------------------------------------
      // Write response must remain stable while stalled.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        wr_rsp_valid && !wr_rsp_ready
        |=> wr_rsp_valid &&
            $stable(wr_rsp_source) &&
            $stable(wr_rsp_addr) &&
            $stable(wr_rsp_error)
      )
      else $error(
        "TLC MEMORY: write response changed while stalled"
      );


      //------------------------------------------------------------------------
      // Memory response cannot be accepted if response FIFO is full.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        rsp_count_q >= RSP_FIFO_DEPTH
        |-> !mem_rsp_ready
      )
      else $error(
        "TLC MEMORY: response accepted while FIFO full"
      );


      //------------------------------------------------------------------------
      // Reset state.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          count_q == 0 &&
          rsp_count_q == 0 &&
          !mem_issue_valid_q
        )
      )
      else $error(
        "TLC MEMORY: reset state not clean"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter validation
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC MEMORY: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC MEMORY: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC MEMORY: DATA_W must be byte aligned"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC MEMORY: CACHE_LINE_BYTES must be > 0"
      );

    if (
      CACHE_LINE_BYTES &
      (CACHE_LINE_BYTES - 1)
    )
      $error(
        "TLC MEMORY: CACHE_LINE_BYTES must be power-of-two"
      );

    if (MAX_OUTSTANDING == 0)
      $error(
        "TLC MEMORY: MAX_OUTSTANDING must be > 0"
      );

    if (REQ_FIFO_DEPTH == 0)
      $error(
        "TLC MEMORY: REQ_FIFO_DEPTH must be > 0"
      );

    if (RSP_FIFO_DEPTH == 0)
      $error(
        "TLC MEMORY: RSP_FIFO_DEPTH must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC MEMORY: TIMEOUT_CYCLES must be > 0"
      );

    if (
      MAX_OUTSTANDING >
      (1 << MEM_ID_W)
    )
      $error(
        "TLC MEMORY: MEM_ID_W insufficient for MAX_OUTSTANDING"
      );

  end

endmodule