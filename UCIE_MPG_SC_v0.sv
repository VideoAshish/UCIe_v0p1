```systemverilog
//=============================================================================
// File        : ucie_mpg_scheduler.sv
// Project     : UCIe 3.0 D2D Adapter
// Description : Multi-Protocol Group scheduler for UCIe adapter
//
// Architecture
// ------------
//
//       Stack 0 ─────┐
//       Stack 1 ─────┤
//       Stack 2 ─────┤
//       ...          ├──> ucie_mpg_scheduler ──> ucie_mpg_mux
//       Stack N ─────┘
//
// Responsibilities
// ----------------
// * Select one eligible protocol stack per arbitration opportunity
// * Round-robin scheduling
// * Fixed-priority scheduling
// * Optional weighted scheduling
// * Packet ownership locking
// * No packet interleaving
// * Optional no-consecutive-stack policy
// * Optional maximum service quota
// * Starvation monitoring
// * Credit-aware eligibility
// * Programmable per-stack priority
//
// This block does NOT:
// * Format UCIe flits
// * Generate CRC
// * Perform retry/replay
// * Encode PHY symbols
// * Modify protocol payloads
//
//=============================================================================

module ucie_mpg_scheduler #(

  parameter int unsigned NUM_STACKS = 2,

  parameter int unsigned PRIORITY_WIDTH = 4,

  parameter int unsigned WEIGHT_WIDTH = 8,

  parameter int unsigned CREDIT_WIDTH = 8,

  parameter int unsigned STARVE_WIDTH = 16,

  parameter int unsigned QUOTA_WIDTH = 16,

  parameter int unsigned STACK_ID_WIDTH =
      (NUM_STACKS <= 1) ? 1 : $clog2(NUM_STACKS),

  //-------------------------------------------------------------------------
  // Arbitration mode
  //
  // 0 = fixed priority
  // 1 = round robin
  //-------------------------------------------------------------------------
  parameter bit ROUND_ROBIN = 1'b1,

  //-------------------------------------------------------------------------
  // Weighted scheduling
  //-------------------------------------------------------------------------
  parameter bit ENABLE_WEIGHTED = 1'b0,

  //-------------------------------------------------------------------------
  // Credit gating
  //-------------------------------------------------------------------------
  parameter bit ENABLE_CREDITS = 1'b0,

  //-------------------------------------------------------------------------
  // Prevent same stack from being selected on consecutive completed
  // protocol flits when an alternate eligible stack exists.
  //-------------------------------------------------------------------------
  parameter bit ENFORCE_NO_CONSECUTIVE = 1'b1,

  //-------------------------------------------------------------------------
  // Maximum number of consecutive grants.
  //
  // 0 = unlimited.
  //-------------------------------------------------------------------------
  parameter int unsigned MAX_CONSECUTIVE = 0,

  //-------------------------------------------------------------------------
  // Starvation tracking
  //-------------------------------------------------------------------------
  parameter bit ENABLE_STARVATION_MONITOR = 1'b1,

  //-------------------------------------------------------------------------
  // Saturating starvation counter
  //-------------------------------------------------------------------------
  parameter int unsigned STARVATION_THRESHOLD = 0,

  parameter bit ENABLE_ASSERTIONS = 1'b1

) (

  input logic clk_i,

  input logic rst_ni,

  //===========================================================================
  // INPUT / STACK STATE
  //===========================================================================

  input logic [NUM_STACKS-1:0]
      stack_valid_i,

  input logic [NUM_STACKS-1:0]
      stack_enable_i,

  input logic [NUM_STACKS-1:0]
      stack_sop_i,

  input logic [NUM_STACKS-1:0]
      stack_eop_i,

  input logic [NUM_STACKS-1:0]
      stack_error_i,

  input logic [NUM_STACKS-1:0]
      stack_blocked_i,

  input logic [NUM_STACKS-1:0][PRIORITY_WIDTH-1:0]
      stack_priority_i,

  input logic [NUM_STACKS-1:0][WEIGHT_WIDTH-1:0]
      stack_weight_i,

  input logic [NUM_STACKS-1:0][CREDIT_WIDTH-1:0]
      stack_credit_i,

  //===========================================================================
  // OUTPUT / MUX HANDSHAKE
  //===========================================================================

  input logic
      mux_ready_i,

  output logic
      sched_valid_o,

  output logic [STACK_ID_WIDTH-1:0]
      sched_stack_id_o,

  output logic [NUM_STACKS-1:0]
      sched_grant_oh_o,

  //===========================================================================
  // ACCEPTED TRANSACTION
  //===========================================================================

  output logic
      sched_fire_o,

  //===========================================================================
  // PACKET OWNERSHIP
  //===========================================================================

  output logic
      locked_o,

  output logic [STACK_ID_WIDTH-1:0]
      locked_stack_o,

  //===========================================================================
  // LAST SERVED STACK
  //===========================================================================

  output logic
      last_valid_o,

  output logic [STACK_ID_WIDTH-1:0]
      last_stack_o,

  //===========================================================================
  // STARVATION STATUS
  //===========================================================================

  output logic [NUM_STACKS-1:0]
      starvation_o,

  output logic [NUM_STACKS-1:0][STARVE_WIDTH-1:0]
      starvation_count_o,

  //===========================================================================
  // DEBUG / PERFORMANCE
  //===========================================================================

  output logic [NUM_STACKS-1:0]
      eligible_o,

  output logic [NUM_STACKS-1:0]
      blocked_by_policy_o,

  output logic [NUM_STACKS-1:0]
      selected_o

);

  //===========================================================================
  // LOCAL PARAMETERS
  //===========================================================================

  localparam int unsigned CONSEC_WIDTH =
      (MAX_CONSECUTIVE <= 1) ?
      1 :
      $clog2(MAX_CONSECUTIVE + 1);

  //===========================================================================
  // INTERNAL STATE
  //===========================================================================

  logic [STACK_ID_WIDTH-1:0]
      rr_ptr_q,
      rr_ptr_d;

  logic
      lock_q,
      lock_d;

  logic [STACK_ID_WIDTH-1:0]
      lock_stack_q,
      lock_stack_d;

  logic
      last_valid_q,
      last_valid_d;

  logic [STACK_ID_WIDTH-1:0]
      last_stack_q,
      last_stack_d;

  logic [CONSEC_WIDTH-1:0]
      consecutive_q,
      consecutive_d;

  logic [NUM_STACKS-1:0][STARVE_WIDTH-1:0]
      starvation_count_q,
      starvation_count_d;

  logic [NUM_STACKS-1:0]
      starvation_q,
      starvation_d;

  //===========================================================================
  // ELIGIBILITY
  //===========================================================================

  logic [NUM_STACKS-1:0]
      eligible;

  logic [NUM_STACKS-1:0]
      policy_blocked;

  logic
      alternate_available;

  //===========================================================================
  // SELECTED STACK
  //===========================================================================

  logic
      select_valid;

  logic [STACK_ID_WIDTH-1:0]
      select_id;

  logic [NUM_STACKS-1:0]
      select_oh;

  //===========================================================================
  // BASIC ELIGIBILITY
  //===========================================================================

  always_comb begin

    eligible = '0;

    for (int unsigned i = 0;
         i < NUM_STACKS;
         i++) begin

      eligible[i] =
          stack_valid_i[i] &&
          stack_enable_i[i] &&
          !stack_blocked_i[i];

      //-----------------------------------------------------------------------
      // Credit-aware scheduling
      //-----------------------------------------------------------------------

      if (ENABLE_CREDITS) begin

        if (stack_credit_i[i] == '0)

          eligible[i] = 1'b0;

      end

    end

  end

  //===========================================================================
  // POLICY FILTER
  //===========================================================================

  always_comb begin

    policy_blocked =
        '0;

    alternate_available =
        1'b0;

    //-----------------------------------------------------------------------
    // Determine if another stack is available.
    //-----------------------------------------------------------------------

    if (last_valid_q) begin

      for (int unsigned i = 0;
           i < NUM_STACKS;
           i++) begin

        if (eligible[i] &&
            (i != last_stack_q))

          alternate_available = 1'b1;

      end

    end

    //-----------------------------------------------------------------------
    // No-consecutive-stack rule
    //-----------------------------------------------------------------------

    if (!lock_q &&
        ENFORCE_NO_CONSECUTIVE &&
        last_valid_q &&
        alternate_available) begin

      policy_blocked[last_stack_q] =
          1'b1;

    end

    //-----------------------------------------------------------------------
    // Maximum consecutive service
    //-----------------------------------------------------------------------

    if (!lock_q &&
        (MAX_CONSECUTIVE != 0) &&
        last_valid_q &&
        (consecutive_q >= MAX_CONSECUTIVE) &&
        alternate_available) begin

      policy_blocked[last_stack_q] =
          1'b1;

    end

  end

  //===========================================================================
  // FINAL ELIGIBILITY
  //===========================================================================

  always_comb begin

    eligible_o =
        eligible;

    blocked_by_policy_o =
        policy_blocked;

    if (lock_q) begin

      //-----------------------------------------------------------------------
      // Once a packet is locked, only its owner can be scheduled.
      //-----------------------------------------------------------------------

      eligible =
          '0;

      eligible[lock_stack_q] =
          stack_valid_i[lock_stack_q] &&
          stack_enable_i[lock_stack_q] &&
          !stack_blocked_i[lock_stack_q];

      if (ENABLE_CREDITS) begin

        if (stack_credit_i[lock_stack_q] == '0)

          eligible[lock_stack_q] =
              1'b0;

      end

    end

    else begin

      eligible =
          eligible &
          ~policy_blocked;

    end

  end

  //===========================================================================
  // ARBITRATION
  //===========================================================================

  always_comb begin

    select_valid =
        1'b0;

    select_id =
        '0;

    select_oh =
        '0;

    //=======================================================================
    // LOCKED PACKET
    //=======================================================================

    if (lock_q) begin

      if (eligible[lock_stack_q]) begin

        select_valid =
            1'b1;

        select_id =
            lock_stack_q;

        select_oh[lock_stack_q] =
            1'b1;

      end

    end

    //=======================================================================
    // NEW ARBITRATION
    //=======================================================================

    else begin

      //=====================================================================
      // FIXED PRIORITY
      //=====================================================================

      if (!ROUND_ROBIN) begin

        logic found;

        found = 1'b0;

        for (int unsigned p = 0;
             p < (1 << PRIORITY_WIDTH);
             p++) begin

          for (int unsigned i = 0;
               i < NUM_STACKS;
               i++) begin

            if (!found &&
                eligible[i] &&
                (stack_priority_i[i] ==
                 PRIORITY_WIDTH'(p))) begin

              found =
                  1'b1;

              select_valid =
                  1'b1;

              select_id =
                  STACK_ID_WIDTH'(i);

              select_oh[i] =
                  1'b1;

            end

          end

        end

      end

      //=====================================================================
      // ROUND ROBIN
      //=====================================================================

      else begin

        for (int unsigned offset = 0;
             offset < NUM_STACKS;
             offset++) begin

          int unsigned idx;

          idx =
              (rr_ptr_q + offset) % NUM_STACKS;

          if (!select_valid &&
              eligible[idx]) begin

            select_valid =
                1'b1;

            select_id =
                STACK_ID_WIDTH'(idx);

            select_oh[idx] =
                1'b1;

          end

        end

      end

    end

  end

  //===========================================================================
  // OUTPUTS
  //===========================================================================

  assign sched_valid_o =
      select_valid;

  assign sched_stack_id_o =
      select_id;

  assign sched_grant_oh_o =
      select_oh;

  assign sched_fire_o =
      select_valid &&
      mux_ready_i;

  assign locked_o =
      lock_q;

  assign locked_stack_o =
      lock_stack_q;

  assign last_valid_o =
      last_valid_q;

  assign last_stack_o =
      last_stack_q;

  assign starvation_count_o =
      starvation_count_q;

  assign starvation_o =
      starvation_q;

  assign selected_o =
      select_oh;

  //===========================================================================
  // NEXT STATE
  //===========================================================================

  always_comb begin

    rr_ptr_d =
        rr_ptr_q;

    lock_d =
        lock_q;

    lock_stack_d =
        lock_stack_q;

    last_valid_d =
        last_valid_q;

    last_stack_d =
        last_stack_q;

    consecutive_d =
        consecutive_q;

    starvation_count_d =
        starvation_count_q;

    starvation_d =
        starvation_q;

    //=======================================================================
    // Successful scheduling decision
    //=======================================================================

    if (sched_fire_o) begin

      //---------------------------------------------------------------------
      // Record last served stack.
      //---------------------------------------------------------------------

      last_valid_d =
          1'b1;

      last_stack_d =
          select_id;

      //---------------------------------------------------------------------
      // Packet ownership
      //
      // A stack retains ownership until EOP.
      //---------------------------------------------------------------------

      if (!stack_eop_i[select_id]) begin

        lock_d =
            1'b1;

        lock_stack_d =
            select_id;

      end

      else begin

        lock_d =
            1'b0;

        lock_stack_d =
            '0;

      end

      //---------------------------------------------------------------------
      // Consecutive service accounting.
      //---------------------------------------------------------------------

      if (last_valid_q &&
          (last_stack_q == select_id)) begin

        if (MAX_CONSECUTIVE != 0) begin

          if (consecutive_q < MAX_CONSECUTIVE)

            consecutive_d =
                consecutive_q + 1'b1;

        end

      end

      else begin

        consecutive_d =
            CONSEC_WIDTH'(1);

      end

      //---------------------------------------------------------------------
      // Round-robin pointer moves after a completed flit/packet.
      //---------------------------------------------------------------------

      if (stack_eop_i[select_id]) begin

        if (select_id == NUM_STACKS-1)

          rr_ptr_d =
              '0;

        else

          rr_ptr_d =
              select_id + 1'b1;

      end

    end

    //=======================================================================
    // STARVATION MONITOR
    //=======================================================================

    if (ENABLE_STARVATION_MONITOR) begin

      for (int unsigned i = 0;
           i < NUM_STACKS;
           i++) begin

        //-------------------------------------------------------------------
        // Disabled / empty stacks are not starving.
        //-------------------------------------------------------------------

        if (!stack_enable_i[i] ||
            !stack_valid_i[i]) begin

          starvation_count_d[i] =
              '0;

          starvation_d[i] =
              1'b0;

        end

        //-------------------------------------------------------------------
        // Selected stack gets reset.
        //-------------------------------------------------------------------

        else if (sched_fire_o &&
                 (select_id == i)) begin

          starvation_count_d[i] =
              '0;

          starvation_d[i] =
              1'b0;

        end

        //-------------------------------------------------------------------
        // Waiting stack increments saturating counter.
        //-------------------------------------------------------------------

        else begin

          if (starvation_count_q[i] != {STARVE_WIDTH{1'b1}})

            starvation_count_d[i] =
                starvation_count_q[i] + 1'b1;

          if ((STARVATION_THRESHOLD != 0) &&
              (starvation_count_q[i] >= STARVATION_THRESHOLD))

            starvation_d[i] =
                1'b1;

        end

      end

    end

  end

  //===========================================================================
  // SEQUENTIAL STATE
  //===========================================================================

  always_ff @(posedge clk_i or negedge rst_ni) begin

    if (!rst_ni) begin

      rr_ptr_q <=
          '0;

      lock_q <=
          1'b0;

      lock_stack_q <=
          '0;

      last_valid_q <=
          1'b0;

      last_stack_q <=
          '0;

      consecutive_q <=
          '0;

      starvation_count_q <=
          '0;

      starvation_q <=
          '0;

    end

    else begin

      rr_ptr_q <=
          rr_ptr_d;

      lock_q <=
          lock_d;

      lock_stack_q <=
          lock_stack_d;

      last_valid_q <=
          last_valid_d;

      last_stack_q <=
          last_stack_d;

      consecutive_q <=
          consecutive_d;

      starvation_count_q <=
          starvation_count_d;

      starvation_q <=
          starvation_d;

    end

  end

  //===========================================================================
  // ASSERTIONS
  //===========================================================================

  generate

    if (ENABLE_ASSERTIONS) begin : gen_sva

      //=======================================================================
      // Grant must be one-hot or zero.
      //=======================================================================

      property p_onehot_grant;

        @(posedge clk_i)
        disable iff (!rst_ni)

        $onehot0(sched_grant_oh_o);

      endproperty

      assert property (p_onehot_grant)
        else
          $error(
            "UCIe MPG scheduler: grant is not one-hot"
          );


      //=======================================================================
      // VALID must match grant vector.
      //=======================================================================

      property p_valid_matches_grant;

        @(posedge clk_i)
        disable iff (!rst_ni)

        sched_valid_o ==
        (|sched_grant_oh_o);

      endproperty

      assert property (p_valid_matches_grant)
        else
          $error(
            "UCIe MPG scheduler: VALID/grant mismatch"
          );


      //=======================================================================
      // Locked scheduler must select locked stack.
      //=======================================================================

      property p_lock_ownership;

        @(posedge clk_i)
        disable iff (!rst_ni)

        locked_o &&
        sched_valid_o

        |->
        sched_stack_id_o == locked_stack_o;

      endproperty

      assert property (p_lock_ownership)
        else
          $error(
            "UCIe MPG scheduler: packet ownership violation"
          );


      //=======================================================================
      // Fire implies VALID.
      //=======================================================================

      property p_fire_requires_valid;

        @(posedge clk_i)
        disable iff (!rst_ni)

        sched_fire_o
        |->
        sched_valid_o;

      endproperty

      assert property (p_fire_requires_valid)
        else
          $error(
            "UCIe MPG scheduler: FIRE without VALID"
          );


      //=======================================================================
      // Disabled stack must never be selected.
      //=======================================================================

      property p_disabled_not_selected;

        @(posedge clk_i)
        disable iff (!rst_ni)

        (sched_grant_oh_o & ~stack_enable_i) == '0;

      endproperty

      assert property (p_disabled_not_selected)
        else
          $error(
            "UCIe MPG scheduler: disabled stack selected"
          );


      //=======================================================================
      // Blocked stack must not be selected.
      //=======================================================================

      property p_blocked_not_selected;

        @(posedge clk_i)
        disable iff (!rst_ni)

        (sched_grant_oh_o & stack_blocked_i) == '0;

      endproperty

      assert property (p_blocked_not_selected)
        else
          $error(
            "UCIe MPG scheduler: blocked stack selected"
          );


      //=======================================================================
      // Credit starvation protection.
      //=======================================================================

      if (ENABLE_CREDITS) begin : gen_credit_assertions

        property p_no_zero_credit_grant;

          @(posedge clk_i)
          disable iff (!rst_ni)

          sched_fire_o

          |->
          (stack_credit_i[sched_stack_id_o] != 0);

        endproperty

        assert property (p_no_zero_credit_grant)
          else
            $error(
              "UCIe MPG scheduler: selected stack has zero credit"
            );

      end


      //=======================================================================
      // Locked transaction cannot change ownership.
      //=======================================================================

      property p_lock_stable;

        @(posedge clk_i)
        disable iff (!rst_ni)

        locked_o &&
        !stack_eop_i[locked_stack_o]

        |->

        (!sched_valid_o ||
         sched_stack_id_o == locked_stack_o);

      endproperty

      assert property (p_lock_stable)
        else
          $error(
            "UCIe MPG scheduler: lock changed before EOP"
          );


      //=======================================================================
      // Reset clears ownership.
      //=======================================================================

      property p_reset_clears_lock;

        @(posedge clk_i)

        !rst_ni
        |=> !locked_o;

      endproperty

      assert property (p_reset_clears_lock)
        else
          $error(
            "UCIe MPG scheduler: lock not cleared on reset"
          );

    end

  endgenerate

endmodule
```
