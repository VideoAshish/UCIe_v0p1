```systemverilog
//==============================================================================
// File        : ucie_mpg_scheduler.sv
// Project     : UCIe D2D Adapter
// Description : Advanced parameterized ASIC-oriented MPG scheduler
//
//------------------------------------------------------------------------------
// FEATURES
//------------------------------------------------------------------------------
//  * Parameterized number of protocol stacks
//  * Round-robin arbitration
//  * Strict priority arbitration
//  * Priority + aging
//  * Weighted round-robin
//  * Deficit/quantum based fairness
//  * Credit-aware arbitration
//  * Packet ownership locking
//  * No packet interleaving
//  * Optional no-consecutive-stack policy
//  * Maximum consecutive service
//  * Starvation detection
//  * Starvation override
//  * Stack enable / block
//  * Configurable quantum
//  * Saturating counters
//  * ASIC-friendly arbitration
//  * One-hot grant
//  * No inferred latches
//  * SystemVerilog assertions
//
//------------------------------------------------------------------------------
// IMPORTANT ARCHITECTURE
//------------------------------------------------------------------------------
//
//   Protocol 0 ─ FIFO ─┐
//   Protocol 1 ─ FIFO ─┤
//   Protocol 2 ─ FIFO ─┤
//   Protocol N ─ FIFO ─┘
//                     |
//                     v
//             +-------------------+
//             | MPG SCHEDULER      |
//             |                   |
//             | Eligibility       |
//             | QoS / Priority    |
//             | Aging             |
//             | RR / WRR          |
//             | Packet Lock       |
//             | Credit Check      |
//             +---------+---------+
//                       |
//                       | grant
//                       v
//                  MPG MUX
//
//------------------------------------------------------------------------------
// NOTES
//------------------------------------------------------------------------------
// This module selects a protocol stack only. It does not modify flit contents.
// CRC, replay, link state and PHY functions remain outside this block.
//
//==============================================================================

module ucie_mpg_scheduler #(

  //----------------------------------------------------------------------------
  // Basic configuration
  //----------------------------------------------------------------------------

  parameter int unsigned NUM_STACKS = 2,

  parameter int unsigned STACK_ID_WIDTH =
      (NUM_STACKS <= 1) ? 1 : $clog2(NUM_STACKS),

  parameter int unsigned PRIORITY_WIDTH = 4,

  parameter int unsigned CREDIT_WIDTH = 12,

  parameter int unsigned WEIGHT_WIDTH = 8,

  parameter int unsigned AGE_WIDTH = 16,

  parameter int unsigned QUANTUM_WIDTH = 12,

  parameter int unsigned CONSEC_WIDTH = 12,

  //----------------------------------------------------------------------------
  // Arbitration mode
  //
  // 0 = strict priority
  // 1 = round robin
  // 2 = priority + round robin among equal priority
  // 3 = weighted round robin
  // 4 = weighted + priority + aging
  //----------------------------------------------------------------------------

  parameter int unsigned ARB_MODE = 1,

  //----------------------------------------------------------------------------
  // UCIe multiplexing policy
  //----------------------------------------------------------------------------

  parameter bit ENFORCE_NO_CONSECUTIVE = 1'b1,

  //----------------------------------------------------------------------------
  // Maximum consecutive flits from a stack.
  //
  // 0 = disabled
  //----------------------------------------------------------------------------

  parameter int unsigned MAX_CONSECUTIVE = 0,

  //----------------------------------------------------------------------------
  // Credit-aware scheduling
  //----------------------------------------------------------------------------

  parameter bit ENABLE_CREDITS = 1'b0,

  //----------------------------------------------------------------------------
  // Aging
  //----------------------------------------------------------------------------

  parameter bit ENABLE_AGING = 1'b1,

  parameter bit ENABLE_STARVATION_OVERRIDE = 1'b1,

  parameter int unsigned STARVATION_THRESHOLD = 1024,

  //----------------------------------------------------------------------------
  // Weighted arbitration
  //----------------------------------------------------------------------------

  parameter bit ENABLE_WEIGHTED = 1'b0,

  parameter int unsigned DEFAULT_QUANTUM = 1,

  //----------------------------------------------------------------------------
  // Assertions
  //----------------------------------------------------------------------------

  parameter bit ENABLE_ASSERTIONS = 1'b1

) (

  input  logic clk_i,

  input  logic rst_ni,

  //===========================================================================
  // STACK INPUT STATE
  //===========================================================================

  input  logic [NUM_STACKS-1:0]
      stack_valid_i,

  input  logic [NUM_STACKS-1:0]
      stack_enable_i,

  input  logic [NUM_STACKS-1:0]
      stack_blocked_i,

  input  logic [NUM_STACKS-1:0]
      stack_sop_i,

  input  logic [NUM_STACKS-1:0]
      stack_eop_i,

  //===========================================================================
  // QoS
  //===========================================================================

  input logic [NUM_STACKS-1:0][PRIORITY_WIDTH-1:0]
      stack_priority_i,

  input logic [NUM_STACKS-1:0][WEIGHT_WIDTH-1:0]
      stack_weight_i,

  //===========================================================================
  // CREDIT STATE
  //===========================================================================

  input logic [NUM_STACKS-1:0][CREDIT_WIDTH-1:0]
      stack_credit_i,

  //===========================================================================
  // MUX HANDSHAKE
  //===========================================================================

  input logic
      mux_ready_i,

  //===========================================================================
  // SCHEDULER OUTPUT
  //===========================================================================

  output logic
      sched_valid_o,

  output logic [STACK_ID_WIDTH-1:0]
      sched_stack_id_o,

  output logic [NUM_STACKS-1:0]
      sched_grant_oh_o,

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
  // STARVATION / AGING STATUS
  //===========================================================================

  output logic [NUM_STACKS-1:0]
      starvation_o,

  output logic [NUM_STACKS-1:0][AGE_WIDTH-1:0]
      age_count_o,

  //===========================================================================
  // DEBUG
  //===========================================================================

  output logic [NUM_STACKS-1:0]
      eligible_o,

  output logic [NUM_STACKS-1:0]
      policy_blocked_o,

  output logic [NUM_STACKS-1:0]
      starvation_override_o,

  output logic [NUM_STACKS-1:0]
      selected_o

);

  //============================================================================
  // LOCAL PARAMETERS
  //============================================================================

  localparam int unsigned MAX_CONSEC_LIMIT =
      (MAX_CONSECUTIVE == 0) ? 1 : MAX_CONSECUTIVE;

  localparam int unsigned QUANTUM_LIMIT =
      (DEFAULT_QUANTUM == 0) ? 1 : DEFAULT_QUANTUM;

  //============================================================================
  // PARAMETER CHECKS
  //============================================================================

`ifndef SYNTHESIS

  initial begin

    if (NUM_STACKS < 1)
      $error("UCIe MPG Scheduler: NUM_STACKS must be >= 1");

    if (PRIORITY_WIDTH < 1)
      $error("UCIe MPG Scheduler: PRIORITY_WIDTH must be >= 1");

    if (CREDIT_WIDTH < 1)
      $error("UCIe MPG Scheduler: CREDIT_WIDTH must be >= 1");

    if (AGE_WIDTH < 1)
      $error("UCIe MPG Scheduler: AGE_WIDTH must be >= 1");

    if (ARB_MODE > 4)
      $error("UCIe MPG Scheduler: illegal ARB_MODE");

    if (ENABLE_WEIGHTED && !ENABLE_CREDITS &&
        (WEIGHT_WIDTH == 0))
      $error("UCIe MPG Scheduler: invalid WEIGHT_WIDTH");

  end

`endif

  //============================================================================
  // INTERNAL STATE
  //============================================================================

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

  //----------------------------------------------------------------------------
  // Aging
  //----------------------------------------------------------------------------

  logic [NUM_STACKS-1:0][AGE_WIDTH-1:0]
      age_q,
      age_d;

  logic [NUM_STACKS-1:0]
      starvation_q,
      starvation_d;

  //----------------------------------------------------------------------------
  // Weighted scheduling
  //----------------------------------------------------------------------------

  logic [NUM_STACKS-1:0][QUANTUM_WIDTH-1:0]
      deficit_q,
      deficit_d;

  //============================================================================
  // ELIGIBILITY
  //============================================================================

  logic [NUM_STACKS-1:0]
      basic_eligible;

  logic [NUM_STACKS-1:0]
      policy_eligible;

  logic [NUM_STACKS-1:0]
      final_eligible;

  logic [NUM_STACKS-1:0]
      policy_blocked;

  logic [NUM_STACKS-1:0]
      starvation_override;

  logic
      alternate_available;

  //============================================================================
  // ARBITRATION RESULT
  //============================================================================

  logic
      grant_valid;

  logic [STACK_ID_WIDTH-1:0]
      grant_idx;

  logic [NUM_STACKS-1:0]
      grant_oh;

  //============================================================================
  // HELPER FUNCTION
  //============================================================================
  //
  // Return the next stack index without using modulo.
  //
  // This is preferable to a "% NUM_STACKS" expression in an ASIC scheduler.
  //
  //============================================================================

  function automatic logic [STACK_ID_WIDTH-1:0]
  next_stack (
      input logic [STACK_ID_WIDTH-1:0] current
  );

    if (current == STACK_ID_WIDTH'(NUM_STACKS-1))
      next_stack = '0;
    else
      next_stack = current + 1'b1;

  endfunction

  //============================================================================
  // BASIC ELIGIBILITY
  //============================================================================

  always_comb begin

    basic_eligible = '0;

    for (int unsigned i = 0;
         i < NUM_STACKS;
         i++) begin

      basic_eligible[i] =
          stack_valid_i[i] &&
          stack_enable_i[i] &&
          !stack_blocked_i[i];

      //-----------------------------------------------------------------------
      // Credit check
      //-----------------------------------------------------------------------

      if (ENABLE_CREDITS) begin

        if (stack_credit_i[i] == '0)
          basic_eligible[i] = 1'b0;

      end

    end

  end

  //============================================================================
  // STARVATION OVERRIDE
  //============================================================================

  always_comb begin

    starvation_override = '0;

    if (ENABLE_STARVATION_OVERRIDE &&
        ENABLE_AGING) begin

      for (int unsigned i = 0;
           i < NUM_STACKS;
           i++) begin

        if (basic_eligible[i] &&
            starvation_q[i])

          starvation_override[i] = 1'b1;

      end

    end

  end

  //============================================================================
  // DETERMINE WHETHER AN ALTERNATE STACK EXISTS
  //============================================================================

  always_comb begin

    alternate_available = 1'b0;

    if (last_valid_q) begin

      for (int unsigned i = 0;
           i < NUM_STACKS;
           i++) begin

        if (basic_eligible[i] &&
            (i != last_stack_q))

          alternate_available = 1'b1;

      end

    end

  end

  //============================================================================
  // POLICY FILTER
  //============================================================================

  always_comb begin

    policy_blocked = '0;

    //---------------------------------------------------------------------------
    // UCIe multiplexed-stack policy
    //---------------------------------------------------------------------------

    if (!lock_q &&
        ENFORCE_NO_CONSECUTIVE &&
        last_valid_q &&
        alternate_available) begin

      policy_blocked[last_stack_q] = 1'b1;

    end

    //---------------------------------------------------------------------------
    // Maximum consecutive service
    //---------------------------------------------------------------------------

    if (!lock_q &&
        (MAX_CONSECUTIVE != 0) &&
        last_valid_q &&
        (consecutive_q >= MAX_CONSECUTIVE) &&
        alternate_available) begin

      policy_blocked[last_stack_q] = 1'b1;

    end

    //---------------------------------------------------------------------------
    // Starvation override has precedence over normal no-consecutive filtering.
    //---------------------------------------------------------------------------

    for (int unsigned j = 0;
         j < NUM_STACKS;
         j++) begin

      if (starvation_override[j])
        policy_blocked[j] = 1'b0;

    end

  end

  //============================================================================
  // FINAL ELIGIBILITY
  //============================================================================

  always_comb begin

    final_eligible = basic_eligible &
                     ~policy_blocked;

    //---------------------------------------------------------------------------
    // Packet ownership has highest arbitration priority.
    //---------------------------------------------------------------------------

    if (lock_q) begin

      final_eligible = '0;

      if (basic_eligible[lock_stack_q])
        final_eligible[lock_stack_q] = 1'b1;

    end

  end

  assign eligible_o =
      basic_eligible;

  assign policy_blocked_o =
      policy_blocked;

  assign starvation_override_o =
      starvation_override;

  //============================================================================
  // ARBITRATION
  //============================================================================

  always_comb begin

    grant_valid = 1'b0;

    grant_idx = '0;

    grant_oh = '0;

    //==========================================================================
    // PACKET LOCK
    //==========================================================================

    if (lock_q) begin

      if (final_eligible[lock_stack_q]) begin

        grant_valid = 1'b1;

        grant_idx = lock_stack_q;

        grant_oh[lock_stack_q] = 1'b1;

      end

    end

    //==========================================================================
    // NORMAL ARBITRATION
    //==========================================================================

    else begin

      //========================================================================
      // MODE 0 : STRICT PRIORITY
      //========================================================================

      if (ARB_MODE == 0) begin

        logic found;

        found = 1'b0;

        //----------------------------------------------------------------------
        // Highest priority = numerically smallest priority value.
        //----------------------------------------------------------------------

        for (int unsigned p = 0;
             p < (1 << PRIORITY_WIDTH);
             p++) begin

          for (int unsigned i = 0;
               i < NUM_STACKS;
               i++) begin

            if (!found &&
                final_eligible[i] &&
                (stack_priority_i[i] ==
                 PRIORITY_WIDTH'(p))) begin

              found = 1'b1;

              grant_valid = 1'b1;

              grant_idx =
                  STACK_ID_WIDTH'(i);

              grant_oh[i] =
                  1'b1;

            end

          end

        end

      end

      //========================================================================
      // MODE 1 : ROUND ROBIN
      //========================================================================

      else if (ARB_MODE == 1) begin

        logic [STACK_ID_WIDTH-1:0]
            candidate;

        candidate = rr_ptr_q;

        for (int unsigned k = 0;
             k < NUM_STACKS;
             k++) begin

          if (!grant_valid &&
              final_eligible[candidate]) begin

            grant_valid = 1'b1;

            grant_idx = candidate;

            grant_oh[candidate] = 1'b1;

          end

          candidate =
              next_stack(candidate);

        end

      end

      //========================================================================
      // MODE 2 : PRIORITY + ROUND ROBIN
      //========================================================================

      else if (ARB_MODE == 2) begin

        logic found;

        logic [PRIORITY_WIDTH-1:0]
            best_priority;

        found = 1'b0;

        best_priority = '1;

        //----------------------------------------------------------------------
        // Find best priority.
        //----------------------------------------------------------------------

        for (int unsigned i = 0;
             i < NUM_STACKS;
             i++) begin

          if (final_eligible[i] &&
              (!found ||
               (stack_priority_i[i] < best_priority))) begin

            found = 1'b1;

            best_priority =
                stack_priority_i[i];

          end

        end

        //----------------------------------------------------------------------
        // Round-robin among equal-priority stacks.
        //----------------------------------------------------------------------

        if (found) begin

          logic [STACK_ID_WIDTH-1:0]
              candidate;

          candidate = rr_ptr_q;

          for (int unsigned k = 0;
               k < NUM_STACKS;
               k++) begin

            if (!grant_valid &&
                final_eligible[candidate] &&
                (stack_priority_i[candidate] ==
                 best_priority)) begin

              grant_valid = 1'b1;

              grant_idx = candidate;

              grant_oh[candidate] = 1'b1;

            end

            candidate =
                next_stack(candidate);

          end

        end

      end

      //========================================================================
      // MODE 3 / 4 : WEIGHTED
      //========================================================================

      else begin

        logic found;

        found = 1'b0;

        //----------------------------------------------------------------------
        // Starvation override first.
        //----------------------------------------------------------------------

        if (|starvation_override) begin

          logic [AGE_WIDTH-1:0]
              oldest_age;

          oldest_age = '0;

          for (int unsigned i = 0;
               i < NUM_STACKS;
               i++) begin

            if (starvation_override[i] &&
                (!found ||
                 (age_q[i] > oldest_age))) begin

              found = 1'b1;

              oldest_age =
                  age_q[i];

              grant_valid = 1'b1;

              grant_idx =
                  STACK_ID_WIDTH'(i);

              grant_oh[i] =
                  1'b1;

            end

          end

        end

        //----------------------------------------------------------------------
        // Priority filtering for MODE 4.
        //----------------------------------------------------------------------

        if (!found) begin

          logic priority_found;

          logic [PRIORITY_WIDTH-1:0]
              best_priority;

          priority_found = 1'b0;

          best_priority = '1;

          if (ARB_MODE == 4) begin

            for (int unsigned i = 0;
                 i < NUM_STACKS;
                 i++) begin

              if (final_eligible[i] &&
                  (!priority_found ||
                   (stack_priority_i[i] < best_priority))) begin

                priority_found = 1'b1;

                best_priority =
                    stack_priority_i[i];

              end

            end

          end

          //--------------------------------------------------------------------
          // Weighted selection.
          //
          // A stack with a non-zero deficit is eligible.
          //--------------------------------------------------------------------

          if (priority_found ||
              (ARB_MODE == 3)) begin

            logic [STACK_ID_WIDTH-1:0]
                candidate;

            candidate = rr_ptr_q;

            for (int unsigned k = 0;
                 k < NUM_STACKS;
                 k++) begin

              if (!grant_valid &&
                  final_eligible[candidate]) begin

                if ((ARB_MODE == 3) ||
                    (stack_priority_i[candidate] ==
                     best_priority)) begin

                  if (!ENABLE_WEIGHTED ||
                      (deficit_q[candidate] != '0)) begin

                    grant_valid = 1'b1;

                    grant_idx = candidate;

                    grant_oh[candidate] =
                        1'b1;

                  end

                end

              end

              candidate =
                  next_stack(candidate);

            end

          end

        end

      end

    end

  end

  //============================================================================
  // OUTPUT
  //============================================================================

  assign sched_valid_o =
      grant_valid;

  assign sched_stack_id_o =
      grant_idx;

  assign sched_grant_oh_o =
      grant_oh;

  assign sched_fire_o =
      grant_valid &&
      mux_ready_i;

  assign locked_o =
      lock_q;

  assign locked_stack_o =
      lock_stack_q;

  assign last_valid_o =
      last_valid_q;

  assign last_stack_o =
      last_stack_q;

  assign age_count_o =
      age_q;

  assign starvation_o =
      starvation_q;

  assign selected_o =
      grant_oh;

  //============================================================================
  // NEXT STATE
  //============================================================================

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

    age_d =
        age_q;

    starvation_d =
        starvation_q;

    deficit_d =
        deficit_q;

    //==========================================================================
    // SERVICE EVENT
    //==========================================================================

    if (sched_fire_o) begin

      //------------------------------------------------------------------------
      // Record last served stack
      //------------------------------------------------------------------------

      last_valid_d =
          1'b1;

      last_stack_d =
          grant_idx;

      //------------------------------------------------------------------------
      // Packet ownership
      //
      // Ownership persists until EOP.
      //------------------------------------------------------------------------

      if (!stack_eop_i[grant_idx]) begin

        lock_d =
            1'b1;

        lock_stack_d =
            grant_idx;

      end

      else begin

        lock_d =
            1'b0;

        lock_stack_d =
            '0;

      end

      //------------------------------------------------------------------------
      // Consecutive service counter
      //------------------------------------------------------------------------

      if (last_valid_q &&
          (last_stack_q == grant_idx)) begin

        if (consecutive_q != {CONSEC_WIDTH{1'b1}})

          consecutive_d =
              consecutive_q + 1'b1;

      end

      else begin

        consecutive_d =
            CONSEC_WIDTH'(1);

      end

      //------------------------------------------------------------------------
      // Round-robin pointer
      //
      // Pointer advances after EOP. This prevents a packet from changing
      // ownership simply because an individual flit was transmitted.
      //------------------------------------------------------------------------

      if (stack_eop_i[grant_idx])

        rr_ptr_d =
            next_stack(grant_idx);

      //------------------------------------------------------------------------
      // Weighted deficit
      //------------------------------------------------------------------------

      if (ENABLE_WEIGHTED) begin

        //----------------------------------------------------------------------
        // Consume one service credit.
        //----------------------------------------------------------------------

        if (deficit_q[grant_idx] != '0)

          deficit_d[grant_idx] =
              deficit_q[grant_idx] - 1'b1;

        //----------------------------------------------------------------------
        // When deficit reaches zero, replenish all active stacks.
        //----------------------------------------------------------------------
        //
        // This is a simple deficit-round-robin implementation. It avoids
        // multiplication/division in the critical arbitration path.
        //----------------------------------------------------------------------

        if ((deficit_q[grant_idx] <= 1) &&
            stack_eop_i[grant_idx]) begin

          for (int unsigned q = 0;
               q < NUM_STACKS;
               q++) begin

            if (stack_enable_i[q]) begin

              if (stack_weight_i[q] != '0)

                deficit_d[q] =
                    {{(QUANTUM_WIDTH-WEIGHT_WIDTH){1'b0}},
                     stack_weight_i[q]};

              else

                deficit_d[q] =
                    QUANTUM_WIDTH'(DEFAULT_QUANTUM);

            end

          end

        end

      end

    end

    //==========================================================================
    // AGING
    //==========================================================================

    if (ENABLE_AGING) begin

      for (int unsigned i = 0;
           i < NUM_STACKS;
           i++) begin

        //------------------------------------------------------------------------
        // Stack not requesting service does not age.
        //------------------------------------------------------------------------

        if (!stack_valid_i[i] ||
            !stack_enable_i[i] ||
            stack_blocked_i[i]) begin

          age_d[i] =
              '0;

          starvation_d[i] =
              1'b0;

        end

        //------------------------------------------------------------------------
        // Selected stack resets age.
        //------------------------------------------------------------------------

        else if (sched_fire_o &&
                 (grant_idx == i)) begin

          age_d[i] =
              '0;

          starvation_d[i] =
              1'b0;

        end

        //------------------------------------------------------------------------
        // Waiting stack ages.
        //------------------------------------------------------------------------

        else begin

          if (age_q[i] != {AGE_WIDTH{1'b1}})

            age_d[i] =
                age_q[i] + 1'b1;

          if ((STARVATION_THRESHOLD != 0) &&
              (age_q[i] >= STARVATION_THRESHOLD))

            starvation_d[i] =
                1'b1;

        end

      end

    end

  end

  //============================================================================
  // STATE REGISTERS
  //============================================================================

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

      age_q <=
          '0;

      starvation_q <=
          '0;

      deficit_q <=
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

      age_q <=
          age_d;

      starvation_q <=
          starvation_d;

      deficit_q <=
          deficit_d;

    end

  end

  //============================================================================
  // ASSERTIONS
  //============================================================================

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_SVA

      //========================================================================
      // Grant is one-hot or zero.
      //========================================================================

      property p_grant_onehot;

        @(posedge clk_i)
        disable iff (!rst_ni)

        $onehot0(sched_grant_oh_o);

      endproperty

      assert property (p_grant_onehot)
        else
          $error(
            "UCIe MPG scheduler: grant is not one-hot"
          );

      //========================================================================
      // VALID agrees with grant vector.
      //========================================================================

      property p_valid_grant_consistent;

        @(posedge clk_i)
        disable iff (!rst_ni)

        sched_valid_o ==
        (|sched_grant_oh_o);

      endproperty

      assert property (p_valid_grant_consistent)
        else
          $error(
            "UCIe MPG scheduler: VALID/grant mismatch"
          );

      //========================================================================
      // FIRE requires VALID.
      //========================================================================

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

      //========================================================================
      // Disabled stack cannot be selected.
      //========================================================================

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

      //========================================================================
      // Blocked stack cannot be selected.
      //========================================================================

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

      //========================================================================
      // Credit protection.
      //========================================================================

      if (ENABLE_CREDITS) begin : GEN_CREDIT_SVA

        property p_credit_available;

          @(posedge clk_i)
          disable iff (!rst_ni)

          sched_fire_o

          |->
          (stack_credit_i[sched_stack_id_o] != '0);

        endproperty

        assert property (p_credit_available)
          else
            $error(
              "UCIe MPG scheduler: transmission without credit"
            );

      end

      //========================================================================
      // Packet lock ownership.
      //========================================================================

      property p_locked_stack_only;

        @(posedge clk_i)
        disable iff (!rst_ni)

        locked_o &&
        sched_valid_o

        |->
        (sched_stack_id_o == locked_stack_o);

      endproperty

      assert property (p_locked_stack_only)
        else
          $error(
            "UCIe MPG scheduler: packet ownership violation"
          );

      //========================================================================
      // Lock cannot disappear in middle of packet.
      //========================================================================

      property p_lock_until_eop;

        @(posedge clk_i)
        disable iff (!rst_ni)

        locked_o &&
        !stack_eop_i[locked_stack_o]

        |->

        (!sched_valid_o ||
         (sched_stack_id_o == locked_stack_o));

      endproperty

      assert property (p_lock_until_eop)
        else
          $error(
            "UCIe MPG scheduler: packet interleaving detected"
          );

      //========================================================================
      // No illegal grant.
      //========================================================================

      property p_grant_requires_eligible;

        @(posedge clk_i)
        disable iff (!rst_ni)

        sched_fire_o

        |->
        final_eligible[sched_stack_id_o];

      endproperty

      assert property (p_grant_requires_eligible)
        else
          $error(
            "UCIe MPG scheduler: grant was not eligible"
          );

      //========================================================================
      // Reset clears lock.
      //========================================================================

      property p_reset_clears_lock;

        @(posedge clk_i)

        !rst_ni
        |=> !locked_o;

      endproperty

      assert property (p_reset_clears_lock)
        else
          $error(
            "UCIe MPG scheduler: lock not cleared by reset"
          );

      //========================================================================
      // Output arbitration is stable while mux is stalled.
      //
      // This property applies to scheduler selection. The actual data
      // stability requirement belongs to the downstream skid buffer/MUX.
      //========================================================================

      property p_selection_stable_when_stalled;

        @(posedge clk_i)
        disable iff (!rst_ni)

        sched_valid_o &&
        !mux_ready_i

        |=> sched_valid_o &&
            $stable(sched_stack_id_o) &&
            $stable(sched_grant_oh_o);

      endproperty

      // NOTE:
      // This assertion is only appropriate when the scheduler is connected
      // directly to a holding interface. If the MUX can independently
      // consume/re-request arbitration, this property should be disabled.

    end

  endgenerate

endmodule
```
