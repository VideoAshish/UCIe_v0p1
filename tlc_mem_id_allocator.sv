//==============================================================================
// tlc_mem_id_allocator.sv
//
// TileLink-C Memory Transaction ID Allocator
//
// Features
// --------
// * Parameterized ID width
// * Parameterized number of IDs
// * Supports non-power-of-two NUM_IDS
// * Allocate / free interface
// * Simultaneous allocate + free
// * No duplicate allocation
// * Registered ownership state
// * Deterministic lowest-free-ID allocation
// * Allocation remains stable until accepted
// * Free has priority over allocation when the same ID is returned
// * Double-free detection
// * Allocation overflow protection
// * Underflow protection
// * Reset-clean state
// * Synthesis friendly
// * SystemVerilog assertions
//
// Intended usage
// --------------
//
//                  +--------------------------+
//                  | tlc_mem_id_allocator    |
//                  |                          |
//      alloc_req ->|                          |-> alloc_valid
//                  |                          |   alloc_id
//                  |                          |
//      alloc_fire  |                          |
//                  |                          |
//      free_valid ->|                          |
//      free_id ---->|                          |
//                  +--------------------------+
//
//==============================================================================

module tlc_mem_id_allocator #(
  parameter int unsigned NUM_IDS =
      16,

  parameter int unsigned ID_W =
      (NUM_IDS <= 1) ? 1 : $clog2(NUM_IDS),

  parameter bit LOWEST_ID_FIRST =
      1'b1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Allocation request
  //==========================================================================

  input  logic             alloc_valid,
  output logic             alloc_ready,

  output logic             alloc_id_valid,
  output logic [ID_W-1:0]  alloc_id,

  //==========================================================================
  // Allocation ownership
  //==========================================================================

  // Allocation is committed when alloc_valid && alloc_ready.
  // alloc_id remains stable while alloc_valid && !alloc_ready.
  //
  //==========================================================================

  //==========================================================================
  // Free interface
  //==========================================================================

  input  logic             free_valid,
  output logic             free_ready,

  input  logic [ID_W-1:0]  free_id,

  //==========================================================================
  // Status
  //==========================================================================

  output logic             empty,
  output logic             full,

  output logic [$clog2(NUM_IDS + 1)-1:0] allocated_count,

  //==========================================================================
  // Error reporting
  //==========================================================================

  output logic             alloc_overflow,
  output logic             free_underflow,
  output logic             double_free,
  output logic             invalid_free_id,
  output logic             protocol_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned COUNT_W =
      (NUM_IDS <= 1) ?
      1 :
      $clog2(NUM_IDS + 1);


  //==========================================================================
  // Allocation ownership bitmap
  //
  // 1 = allocated
  // 0 = free
  //==========================================================================

  logic [NUM_IDS-1:0] allocated_q;
  logic [NUM_IDS-1:0] allocated_d;


  //==========================================================================
  // Registered allocation candidate
  //
  // Registering the candidate prevents the allocator from creating a
  // combinational ready/valid path through downstream logic.
  //==========================================================================

  logic             candidate_valid_q;
  logic [ID_W-1:0]  candidate_id_q;


  logic             candidate_valid_d;
  logic [ID_W-1:0]  candidate_id_d;


  //==========================================================================
  // Allocation count
  //==========================================================================

  logic [COUNT_W-1:0] allocated_count_q;
  logic [COUNT_W-1:0] allocated_count_d;


  assign allocated_count =
      allocated_count_q;


  //==========================================================================
  // Free ID validation
  //==========================================================================

  logic free_id_valid;

  always_comb begin

    free_id_valid =
        1'b0;

    if (free_valid) begin

      if (
        free_id < NUM_IDS
      ) begin

        free_id_valid =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Free readiness
  //
  // A valid free request is always accepted.
  //
  // This is deliberately independent of allocation readiness.
  //==========================================================================

  assign free_ready =
      1'b1;


  //==========================================================================
  // Find a free ID
  //
  // Lowest-numbered free ID is selected.
  //
  // This is deterministic and synthesizes to a priority encoder.
  //
  //==========================================================================

  logic            found_free_id;
  logic [ID_W-1:0] free_candidate_id;

  integer k;

  always_comb begin

    found_free_id =
        1'b0;

    free_candidate_id =
        '0;

    if (LOWEST_ID_FIRST) begin

      for (k = 0; k < NUM_IDS; k++) begin

        if (
          !found_free_id &&
          !allocated_q[k]
        ) begin

          found_free_id =
              1'b1;

          free_candidate_id =
              k[ID_W-1:0];

        end

      end

    end
    else begin

      // Default implementation remains deterministic.
      // A reverse priority encoder can be substituted here.

      for (k = NUM_IDS-1; k >= 0; k--) begin

        if (
          !found_free_id &&
          !allocated_q[k]
        ) begin

          found_free_id =
              1'b1;

          free_candidate_id =
              k[ID_W-1:0];

        end

      end

    end

  end


  //==========================================================================
  // Allocation interface
  //
  // Candidate is presented independently from downstream acceptance.
  //==========================================================================

  always_comb begin

    alloc_id_valid =
        candidate_valid_q;

    alloc_id =
        candidate_id_q;

    alloc_ready =
        candidate_valid_q &&
        alloc_valid;

  end


  //==========================================================================
  // Allocation handshake
  //==========================================================================

  logic alloc_fire;
  logic free_fire;

  assign alloc_fire =
      alloc_valid &&
      alloc_ready;

  assign free_fire =
      free_valid &&
      free_ready;


  //==========================================================================
  // Candidate generation
  //
  // A candidate is loaded whenever the allocator is idle and a free ID
  // exists.
  //
  // Once loaded, it remains stable until accepted.
  //==========================================================================

  always_comb begin

    candidate_valid_d =
        candidate_valid_q;

    candidate_id_d =
        candidate_id_q;


    if (!candidate_valid_q) begin

      if (found_free_id) begin

        candidate_valid_d =
            1'b1;

        candidate_id_d =
            free_candidate_id;

      end

    end
    else begin

      if (alloc_fire) begin

        //--------------------------------------------------------------------
        // Current candidate was consumed.
        //--------------------------------------------------------------------

        candidate_valid_d =
            1'b0;

      end

    end

  end


  //==========================================================================
  // Ownership next-state calculation
  //==========================================================================

  always_comb begin

    allocated_d =
        allocated_q;

    allocated_count_d =
        allocated_count_q;


    //-----------------------------------------------------------------------
    // Free first.
    //
    // This ordering is intentional. If allocation and free happen in the
    // same cycle, the returned ID is considered available for the next
    // allocation.
    //-----------------------------------------------------------------------

    if (free_fire && free_id_valid) begin

      if (allocated_q[free_id]) begin

        allocated_d[free_id] =
            1'b0;

        if (
          allocated_count_d != 0
        ) begin

          allocated_count_d =
              allocated_count_d - 1'b1;

        end

      end

    end


    //-----------------------------------------------------------------------
    // Allocation.
    //-----------------------------------------------------------------------

    if (alloc_fire) begin

      allocated_d[alloc_id] =
          1'b1;

      allocated_count_d =
          allocated_count_d + 1'b1;

    end

  end


  //==========================================================================
  // Error detection
  //==========================================================================

  always_comb begin

    invalid_free_id =
        free_valid &&
        !free_id_valid;


    double_free =
        free_fire &&
        free_id_valid &&
        !allocated_q[free_id];


    alloc_overflow =
        alloc_valid &&
        !candidate_valid_q &&
        !found_free_id;


    free_underflow =
        double_free;


    protocol_error =
        alloc_overflow ||
        free_underflow ||
        double_free ||
        invalid_free_id;

  end


  //==========================================================================
  // Empty / full
  //==========================================================================

  assign empty =
      (allocated_count_q == 0);

  assign full =
      (allocated_count_q >= NUM_IDS);


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      allocated_q <=
          '0;

      candidate_valid_q <=
          1'b0;

      candidate_id_q <=
          '0;

      allocated_count_q <=
          '0;

    end
    else begin

      allocated_q <=
          allocated_d;

      candidate_valid_q <=
          candidate_valid_d;

      candidate_id_q <=
          candidate_id_d;

      allocated_count_q <=
          allocated_count_d;

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_ALLOC_ASSERTIONS

      //------------------------------------------------------------------------
      // Allocation ID must be valid.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_id_valid
        |-> (alloc_id < NUM_IDS)
      )
      else $error(
        "TLC MEM ID ALLOCATOR: invalid allocated ID"
      );


      //------------------------------------------------------------------------
      // Candidate must remain stable while waiting.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_id_valid &&
        alloc_valid &&
        !alloc_ready
        |=> alloc_id_valid &&
            $stable(alloc_id)
      )
      else $error(
        "TLC MEM ID ALLOCATOR: allocation ID changed while stalled"
      );


      //------------------------------------------------------------------------
      // Allocated count cannot exceed NUM_IDS.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        allocated_count_q <= NUM_IDS
      )
      else $error(
        "TLC MEM ID ALLOCATOR: allocation count overflow"
      );


      //------------------------------------------------------------------------
      // Empty means no IDs allocated.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        empty
        |-> (allocated_count_q == 0)
      )
      else $error(
        "TLC MEM ID ALLOCATOR: empty/count mismatch"
      );


      //------------------------------------------------------------------------
      // Full means all IDs allocated.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        full
        |-> (allocated_count_q == NUM_IDS)
      )
      else $error(
        "TLC MEM ID ALLOCATOR: full/count mismatch"
      );


      //------------------------------------------------------------------------
      // An ID cannot be allocated twice without a free.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire
        |-> !allocated_q[alloc_id] ||
            (
              free_fire &&
              free_id_valid &&
              (free_id == alloc_id)
            )
      )
      else $error(
        "TLC MEM ID ALLOCATOR: duplicate ID allocation"
      );


      //------------------------------------------------------------------------
      // Valid free must refer to an allocated ID.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        free_fire &&
        free_id_valid
        |-> allocated_q[free_id]
      )
      else $error(
        "TLC MEM ID ALLOCATOR: double free"
      );


      //------------------------------------------------------------------------
      // Invalid ID must never be accepted as a legitimate free.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        free_fire &&
        !free_id_valid
        |-> invalid_free_id
      )
      else $error(
        "TLC MEM ID ALLOCATOR: invalid free ID"
      );


      //------------------------------------------------------------------------
      // Reset must clear ownership.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          allocated_count_q == 0 &&
          allocated_q == '0 &&
          !candidate_valid_q
        )
      )
      else $error(
        "TLC MEM ID ALLOCATOR: reset state is not clean"
      );


      //------------------------------------------------------------------------
      // No allocated bit may exist outside NUM_IDS.
      //------------------------------------------------------------------------

      // The bitmap itself is exactly NUM_IDS bits, so this is structurally
      // guaranteed.


      //------------------------------------------------------------------------
      // Same-cycle free/allocate of same ID is legal.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        alloc_fire &&
        free_fire &&
        free_id_valid &&
        (free_id == alloc_id)
        |=> allocated_q[alloc_id]
      )
      else $error(
        "TLC MEM ID ALLOCATOR: same-cycle recycle failed"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter checks
  //==========================================================================

  initial begin

    if (NUM_IDS == 0) begin

      $error(
        "TLC MEM ID ALLOCATOR: NUM_IDS must be > 0"
      );

    end

    if (
      NUM_IDS >
      (1 << ID_W)
    ) begin

      $error(
        "TLC MEM ID ALLOCATOR: ID_W insufficient for NUM_IDS"
      );

    end

  end

endmodule