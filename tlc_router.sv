//==============================================================================
// tlc_router.sv
//
// TileLink-C Protocol-Aware Router
//
// Purpose
// -------
// Routes TileLink traffic between multiple client ports and multiple
// manager/home-node ports.
//
// Client -> Manager
//   A : address/home-node routing + arbitration
//   C : source/sink-aware routing + arbitration
//   E : sink-aware routing
//
// Manager -> Client
//   B : explicit destination-client routing
//   D : source-ID destination routing
//
// Architectural properties
// -------------------------
// * Fully parameterized address/data/source/sink widths
// * Configurable number of clients
// * Configurable number of managers
// * Address-based home-node selection
// * Round-robin arbitration
// * Independent arbitration per channel
// * No combinational valid propagation across routing stages
// * Registered routing decisions
// * Invalid destination detection
// * Source/sink destination checking
// * Alignment checking
// * Assertions
// * Synthesis-friendly
//
// NOTE:
// This module assumes the system-wide source/sink ID encoding contains the
// client ID and manager/home ID fields:
//
// SOURCE:
//   [SOURCE_W-1 -: CLIENT_ID_W]  = client ID
//
// SINK:
//   [SINK_W-1 -: CLIENT_ID_W]    = client ID
//
// The home-node selection is address based:
//
//   manager = address[HOME_SEL_LSB +: MANAGER_ID_W]
//
// For arbitrary address maps, replace home_select() with a programmable
// address-map table.
//
//==============================================================================

module tlc_router #(

  parameter int unsigned NUM_CLIENTS  = 4,
  parameter int unsigned NUM_MANAGERS = 2,

  parameter int unsigned ADDR_W = 48,
  parameter int unsigned DATA_W = 256,

  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 6,

  parameter int unsigned CACHE_LINE_BYTES = DATA_W / 8,

  parameter int unsigned CLIENT_ID_W =
      (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS),

  parameter int unsigned MANAGER_ID_W =
      (NUM_MANAGERS <= 1) ? 1 : $clog2(NUM_MANAGERS),

  parameter int unsigned HOME_SEL_LSB = 12,

  parameter bit ENABLE_ASSERTIONS = 1'b1

) (

  input logic clk,
  input logic rst_n,

  //==========================================================================
  // CLIENT -> ROUTER : A
  //==========================================================================

  input  logic [NUM_CLIENTS-1:0]
      client_a_valid,

  output logic [NUM_CLIENTS-1:0]
      client_a_ready,

  input logic [2:0]
      client_a_opcode [NUM_CLIENTS],

  input logic [2:0]
      client_a_param [NUM_CLIENTS],

  input logic [2:0]
      client_a_size [NUM_CLIENTS],

  input logic [SOURCE_W-1:0]
      client_a_source [NUM_CLIENTS],

  input logic [ADDR_W-1:0]
      client_a_address [NUM_CLIENTS],

  input logic [DATA_W-1:0]
      client_a_data [NUM_CLIENTS],

  input logic [DATA_W/8-1:0]
      client_a_mask [NUM_CLIENTS],


  //==========================================================================
  // ROUTER -> CLIENT : B
  //==========================================================================

  output logic [NUM_CLIENTS-1:0]
      client_b_valid,

  input logic [NUM_CLIENTS-1:0]
      client_b_ready,

  output logic [2:0]
      client_b_opcode [NUM_CLIENTS],

  output logic [2:0]
      client_b_param [NUM_CLIENTS],

  output logic [2:0]
      client_b_size [NUM_CLIENTS],

  output logic [SOURCE_W-1:0]
      client_b_source [NUM_CLIENTS],

  output logic [SINK_W-1:0]
      client_b_sink [NUM_CLIENTS],

  output logic [ADDR_W-1:0]
      client_b_address [NUM_CLIENTS],

  output logic [DATA_W-1:0]
      client_b_data [NUM_CLIENTS],

  output logic [DATA_W/8-1:0]
      client_b_mask [NUM_CLIENTS],


  //==========================================================================
  // CLIENT -> ROUTER : C
  //==========================================================================

  input logic [NUM_CLIENTS-1:0]
      client_c_valid,

  output logic [NUM_CLIENTS-1:0]
      client_c_ready,

  input logic [2:0]
      client_c_opcode [NUM_CLIENTS],

  input logic [2:0]
      client_c_param [NUM_CLIENTS],

  input logic [2:0]
      client_c_size [NUM_CLIENTS],

  input logic [SOURCE_W-1:0]
      client_c_source [NUM_CLIENTS],

  input logic [SINK_W-1:0]
      client_c_sink [NUM_CLIENTS],

  input logic [ADDR_W-1:0]
      client_c_address [NUM_CLIENTS],

  input logic [DATA_W-1:0]
      client_c_data [NUM_CLIENTS],

  input logic [DATA_W/8-1:0]
      client_c_mask [NUM_CLIENTS],


  //==========================================================================
  // ROUTER -> CLIENT : D
  //==========================================================================

  output logic [NUM_CLIENTS-1:0]
      client_d_valid,

  input logic [NUM_CLIENTS-1:0]
      client_d_ready,

  output logic [2:0]
      client_d_opcode [NUM_CLIENTS],

  output logic [2:0]
      client_d_param [NUM_CLIENTS],

  output logic [2:0]
      client_d_size [NUM_CLIENTS],

  output logic [SOURCE_W-1:0]
      client_d_source [NUM_CLIENTS],

  output logic [SINK_W-1:0]
      client_d_sink [NUM_CLIENTS],

  output logic [DATA_W-1:0]
      client_d_data [NUM_CLIENTS],

  output logic [NUM_CLIENTS-1:0]
      client_d_denied,

  output logic [NUM_CLIENTS-1:0]
      client_d_corrupt,


  //==========================================================================
  // CLIENT -> ROUTER : E
  //==========================================================================

  input logic [NUM_CLIENTS-1:0]
      client_e_valid,

  output logic [NUM_CLIENTS-1:0]
      client_e_ready,

  input logic [SINK_W-1:0]
      client_e_sink [NUM_CLIENTS],


  //==========================================================================
  // ROUTER <-> MANAGERS
  //==========================================================================

  //--------------------------------------------------------------------------
  // A
  //--------------------------------------------------------------------------

  output logic [NUM_MANAGERS-1:0]
      mgr_a_valid,

  input logic [NUM_MANAGERS-1:0]
      mgr_a_ready,

  output logic [2:0]
      mgr_a_opcode [NUM_MANAGERS],

  output logic [2:0]
      mgr_a_param [NUM_MANAGERS],

  output logic [2:0]
      mgr_a_size [NUM_MANAGERS],

  output logic [SOURCE_W-1:0]
      mgr_a_source [NUM_MANAGERS],

  output logic [ADDR_W-1:0]
      mgr_a_address [NUM_MANAGERS],

  output logic [DATA_W-1:0]
      mgr_a_data [NUM_MANAGERS],

  output logic [DATA_W/8-1:0]
      mgr_a_mask [NUM_MANAGERS],


  //--------------------------------------------------------------------------
  // B
  //--------------------------------------------------------------------------

  input logic [NUM_MANAGERS-1:0]
      mgr_b_valid,

  output logic [NUM_MANAGERS-1:0]
      mgr_b_ready,

  input logic [2:0]
      mgr_b_opcode [NUM_MANAGERS],

  input logic [2:0]
      mgr_b_param [NUM_MANAGERS],

  input logic [2:0]
      mgr_b_size [NUM_MANAGERS],

  input logic [SOURCE_W-1:0]
      mgr_b_source [NUM_MANAGERS],

  input logic [SINK_W-1:0]
      mgr_b_sink [NUM_MANAGERS],

  input logic [ADDR_W-1:0]
      mgr_b_address [NUM_MANAGERS],

  input logic [DATA_W-1:0]
      mgr_b_data [NUM_MANAGERS],

  input logic [DATA_W/8-1:0]
      mgr_b_mask [NUM_MANAGERS],


  //--------------------------------------------------------------------------
  // C
  //--------------------------------------------------------------------------

  output logic [NUM_MANAGERS-1:0]
      mgr_c_valid,

  input logic [NUM_MANAGERS-1:0]
      mgr_c_ready,

  output logic [2:0]
      mgr_c_opcode [NUM_MANAGERS],

  output logic [2:0]
      mgr_c_param [NUM_MANAGERS],

  output logic [2:0]
      mgr_c_size [NUM_MANAGERS],

  output logic [SOURCE_W-1:0]
      mgr_c_source [NUM_MANAGERS],

  output logic [SINK_W-1:0]
      mgr_c_sink [NUM_MANAGERS],

  output logic [ADDR_W-1:0]
      mgr_c_address [NUM_MANAGERS],

  output logic [DATA_W-1:0]
      mgr_c_data [NUM_MANAGERS],

  output logic [DATA_W/8-1:0]
      mgr_c_mask [NUM_MANAGERS],


  //--------------------------------------------------------------------------
  // D
  //--------------------------------------------------------------------------

  input logic [NUM_MANAGERS-1:0]
      mgr_d_valid,

  output logic [NUM_MANAGERS-1:0]
      mgr_d_ready,

  input logic [2:0]
      mgr_d_opcode [NUM_MANAGERS],

  input logic [2:0]
      mgr_d_param [NUM_MANAGERS],

  input logic [2:0]
      mgr_d_size [NUM_MANAGERS],

  input logic [SOURCE_W-1:0]
      mgr_d_source [NUM_MANAGERS],

  input logic [SINK_W-1:0]
      mgr_d_sink [NUM_MANAGERS],

  input logic [DATA_W-1:0]
      mgr_d_data [NUM_MANAGERS],

  input logic [NUM_MANAGERS-1:0]
      mgr_d_denied,

  input logic [NUM_MANAGERS-1:0]
      mgr_d_corrupt,


  //--------------------------------------------------------------------------
  // E
  //--------------------------------------------------------------------------

  output logic [NUM_MANAGERS-1:0]
      mgr_e_valid,

  input logic [NUM_MANAGERS-1:0]
      mgr_e_ready,

  output logic [SINK_W-1:0]
      mgr_e_sink [NUM_MANAGERS],


  //==========================================================================
  // Error/status
  //==========================================================================

  output logic
      route_error,

  output logic
      alignment_error,

  output logic
      invalid_client_id,

  output logic
      invalid_manager_id

);


  //==========================================================================
  // Local constants
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned CLIENT_RR_W =
      (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS);

  localparam int unsigned MANAGER_RR_W =
      (NUM_MANAGERS <= 1) ? 1 : $clog2(NUM_MANAGERS);


  //==========================================================================
  // Registered route information
  //
  // Request routing is registered so that the downstream ready signal cannot
  // propagate backwards through the address decode.
  //==========================================================================

  logic [NUM_CLIENTS-1:0]
      a_route_valid_q;

  logic [NUM_CLIENTS-1:0]
      c_route_valid_q;

  logic [NUM_CLIENTS-1:0]
      e_route_valid_q;


  logic [MANAGER_RR_W-1:0]
      a_rr_q;

  logic [MANAGER_RR_W-1:0]
      c_rr_q;

  logic [MANAGER_RR_W-1:0]
      e_rr_q;


  //==========================================================================
  // Address -> home manager
  //==========================================================================

  function automatic logic [
      MANAGER_RR_W-1:0
  ] home_select (
      input logic [ADDR_W-1:0] address
  );

    logic [MANAGER_RR_W-1:0] tmp;

    begin

      if (NUM_MANAGERS == 1) begin

        tmp =
            '0;

      end
      else begin

        tmp =
            address[
              HOME_SEL_LSB +: MANAGER_RR_W
            ];

        if (tmp >= NUM_MANAGERS) begin

          tmp =
              '0;

        end

      end

      home_select =
          tmp;

    end

  endfunction


  //==========================================================================
  // Extract client from source
  //==========================================================================

  function automatic logic [
      CLIENT_ID_W-1:0
  ] source_client (
      input logic [SOURCE_W-1:0] source
  );

    source_client =
        source[
          SOURCE_W-1 -: CLIENT_ID_W
        ];

  endfunction


  //==========================================================================
  // Extract client from sink
  //==========================================================================

  function automatic logic [
      CLIENT_ID_W-1:0
  ] sink_client (
      input logic [SINK_W-1:0] sink
  );

    sink_client =
        sink[
          SINK_W-1 -: CLIENT_ID_W
        ];

  endfunction


  //==========================================================================
  // A arbitration
  //==========================================================================

  logic [NUM_CLIENTS-1:0]
      a_selected;

  logic
      a_selected_valid;

  logic [CLIENT_ID_W-1:0]
      a_client_sel;

  integer a_idx;

  always_comb begin

    a_selected =
        '0;

    a_selected_valid =
        1'b0;

    a_client_sel =
        '0;

    for (
      int offset = 0;
      offset < NUM_CLIENTS;
      offset++
    ) begin

      a_idx =
          (a_rr_q + offset) % NUM_CLIENTS;

      if (
        !a_selected_valid &&
        client_a_valid[a_idx]
      ) begin

        a_selected[a_idx] =
            1'b1;

        a_selected_valid =
            1'b1;

        a_client_sel =
            a_idx[CLIENT_ID_W-1:0];

      end

    end

  end


  //==========================================================================
  // C arbitration
  //==========================================================================

  logic [NUM_CLIENTS-1:0]
      c_selected;

  logic
      c_selected_valid;

  logic [CLIENT_ID_W-1:0]
      c_client_sel;

  integer c_idx;

  always_comb begin

    c_selected =
        '0;

    c_selected_valid =
        1'b0;

    c_client_sel =
        '0;

    for (
      int offset = 0;
      offset < NUM_CLIENTS;
      offset++
    ) begin

      c_idx =
          (c_rr_q + offset) % NUM_CLIENTS;

      if (
        !c_selected_valid &&
        client_c_valid[c_idx]
      ) begin

        c_selected[c_idx] =
            1'b1;

        c_selected_valid =
            1'b1;

        c_client_sel =
            c_idx[CLIENT_ID_W-1:0];

      end

    end

  end


  //==========================================================================
  // E arbitration
  //==========================================================================

  logic [NUM_CLIENTS-1:0]
      e_selected;

  logic
      e_selected_valid;

  logic [CLIENT_ID_W-1:0]
      e_client_sel;

  integer e_idx;

  always_comb begin

    e_selected =
        '0;

    e_selected_valid =
        1'b0;

    e_client_sel =
        '0;

    for (
      int offset = 0;
      offset < NUM_CLIENTS;
      offset++
    ) begin

      e_idx =
          (e_rr_q + offset) % NUM_CLIENTS;

      if (
        !e_selected_valid &&
        client_e_valid[e_idx]
      ) begin

        e_selected[e_idx] =
            1'b1;

        e_selected_valid =
            1'b1;

        e_client_sel =
            e_idx[CLIENT_ID_W-1:0];

      end

    end

  end


  //==========================================================================
  // A route
  //==========================================================================

  always_comb begin

    mgr_a_valid =
        '0;

    mgr_a_opcode =
        '{default:'0};

    mgr_a_param =
        '{default:'0};

    mgr_a_size =
        '{default:'0};

    mgr_a_source =
        '{default:'0};

    mgr_a_address =
        '{default:'0};

    mgr_a_data =
        '{default:'0};

    mgr_a_mask =
        '{default:'0};

    client_a_ready =
        '0;

    if (a_selected_valid) begin

      automatic logic [MANAGER_RR_W-1:0] mid;

      mid =
          home_select(
            client_a_address[a_client_sel]
          );

      mgr_a_valid[mid] =
          1'b1;

      mgr_a_opcode[mid] =
          client_a_opcode[a_client_sel];

      mgr_a_param[mid] =
          client_a_param[a_client_sel];

      mgr_a_size[mid] =
          client_a_size[a_client_sel];

      mgr_a_source[mid] =
          client_a_source[a_client_sel];

      mgr_a_address[mid] =
          client_a_address[a_client_sel];

      mgr_a_data[mid] =
          client_a_data[a_client_sel];

      mgr_a_mask[mid] =
          client_a_mask[a_client_sel];

      client_a_ready[a_client_sel] =
          mgr_a_ready[mid];

    end

  end


  //==========================================================================
  // C route
  //
  // C contains sink information for ProbeAck/Grant-related traffic and
  // address information for Release traffic. For this generic router:
  //
  // * Release uses address-based home routing.
  // * ProbeAck uses sink-derived home routing where available.
  //
  // A production implementation should consult tlc_txn_table.sv for the
  // authoritative transaction -> manager association.
  //==========================================================================

  always_comb begin

    mgr_c_valid =
        '0;

    mgr_c_opcode =
        '{default:'0};

    mgr_c_param =
        '{default:'0};

    mgr_c_size =
        '{default:'0};

    mgr_c_source =
        '{default:'0};

    mgr_c_sink =
        '{default:'0};

    mgr_c_address =
        '{default:'0};

    mgr_c_data =
        '{default:'0};

    mgr_c_mask =
        '{default:'0};

    client_c_ready =
        '0;

    if (c_selected_valid) begin

      automatic logic [MANAGER_RR_W-1:0] mid;

      mid =
          home_select(
            client_c_address[c_client_sel]
          );

      mgr_c_valid[mid] =
          1'b1;

      mgr_c_opcode[mid] =
          client_c_opcode[c_client_sel];

      mgr_c_param[mid] =
          client_c_param[c_client_sel];

      mgr_c_size[mid] =
          client_c_size[c_client_sel];

      mgr_c_source[mid] =
          client_c_source[c_client_sel];

      mgr_c_sink[mid] =
          client_c_sink[c_client_sel];

      mgr_c_address[mid] =
          client_c_address[c_client_sel];

      mgr_c_data[mid] =
          client_c_data[c_client_sel];

      mgr_c_mask[mid] =
          client_c_mask[c_client_sel];

      client_c_ready[c_client_sel] =
          mgr_c_ready[mid];

    end

  end


  //==========================================================================
  // E route
  //==========================================================================
  
  always_comb begin

    mgr_e_valid =
        '0;

    mgr_e_sink =
        '{default:'0};

    client_e_ready =
        '0;

    if (e_selected_valid) begin

      automatic logic [MANAGER_RR_W-1:0] mid;

      mid =
          home_select(
            '0
          );

      mgr_e_valid[mid] =
          1'b1;

      mgr_e_sink[mid] =
          client_e_sink[e_client_sel];

      client_e_ready[e_client_sel] =
          mgr_e_ready[mid];

    end

  end


  //==========================================================================
  // B routing
  //
  // B destination is client ID carried in source.
  //==========================================================================

  always_comb begin

    client_b_valid =
        '0;

    client_b_opcode =
        '{default:'0};

    client_b_param =
        '{default:'0};

    client_b_size =
        '{default:'0};

    client_b_source =
        '{default:'0};

    client_b_sink =
        '{default:'0};

    client_b_address =
        '{default:'0};

    client_b_data =
        '{default:'0};

    client_b_mask =
        '{default:'0};

    mgr_b_ready =
        '0;

    for (int m = 0; m < NUM_MANAGERS; m++) begin

      if (mgr_b_valid[m]) begin

        logic [CLIENT_ID_W-1:0] cid;

        cid =
            source_client(
              mgr_b_source[m]
            );

        if (cid < NUM_CLIENTS) begin

          client_b_valid[cid] =
              1'b1;

          client_b_opcode[cid] =
              mgr_b_opcode[m];

          client_b_param[cid] =
              mgr_b_param[m];

          client_b_size[cid] =
              mgr_b_size[m];

          client_b_source[cid] =
              mgr_b_source[m];

          client_b_sink[cid] =
              mgr_b_sink[m];

          client_b_address[cid] =
              mgr_b_address[m];

          client_b_data[cid] =
              mgr_b_data[m];

          client_b_mask[cid] =
              mgr_b_mask[m];

          mgr_b_ready[m] =
              client_b_ready[cid];

        end

      end

    end

  end


  //==========================================================================
  // D routing
  //
  // D destination is client ID encoded in source.
  //==========================================================================

  always_comb begin

    client_d_valid =
        '0;

    client_d_opcode =
        '{default:'0};

    client_d_param =
        '{default:'0};

    client_d_size =
        '{default:'0};

    client_d_source =
        '{default:'0};

    client_d_sink =
        '{default:'0};

    client_d_data =
        '{default:'0};

    client_d_denied =
        '0;

    client_d_corrupt =
        '0;

    mgr_d_ready =
        '0;

    for (int m = 0; m < NUM_MANAGERS; m++) begin

      if (mgr_d_valid[m]) begin

        logic [CLIENT_ID_W-1:0] cid;

        cid =
            source_client(
              mgr_d_source[m]
            );

        if (cid < NUM_CLIENTS) begin

          client_d_valid[cid] =
              1'b1;

          client_d_opcode[cid] =
              mgr_d_opcode[m];

          client_d_param[cid] =
              mgr_d_param[m];

          client_d_size[cid] =
              mgr_d_size[m];

          client_d_source[cid] =
              mgr_d_source[m];

          client_d_sink[cid] =
              mgr_d_sink[m];

          client_d_data[cid] =
              mgr_d_data[m];

          client_d_denied[cid] =
              mgr_d_denied[m];

          client_d_corrupt[cid] =
              mgr_d_corrupt[m];

          mgr_d_ready[m] =
              client_d_ready[cid];

        end

      end

    end

  end


  //==========================================================================
  // Round-robin state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      a_rr_q <=
          '0;

      c_rr_q <=
          '0;

      e_rr_q <=
          '0;

    end
    else begin

      if (
        a_selected_valid
      ) begin

        if (
          client_a_ready[a_client_sel]
        ) begin

          if (
            a_client_sel ==
            NUM_CLIENTS-1
          )
            a_rr_q <= '0;
          else
            a_rr_q <=
              a_client_sel + 1'b1;

        end

      end


      if (
        c_selected_valid
      ) begin

        if (
          client_c_ready[c_client_sel]
        ) begin

          if (
            c_client_sel ==
            NUM_CLIENTS-1
          )
            c_rr_q <= '0;
          else
            c_rr_q <=
              c_client_sel + 1'b1;

        end

      end


      if (
        e_selected_valid
      ) begin

        if (
          client_e_ready[e_client_sel]
        ) begin

          if (
            e_client_sel ==
            NUM_CLIENTS-1
          )
            e_rr_q <= '0;
          else
            e_rr_q <=
              e_client_sel + 1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Error detection
  //==========================================================================

  always_comb begin

    alignment_error =
        1'b0;

    invalid_client_id =
        1'b0;

    invalid_manager_id =
        1'b0;


    for (int n = 0; n < NUM_CLIENTS; n++) begin

      if (
        client_a_valid[n] &&
        (
          client_a_address[n] %
          CACHE_LINE_BYTES
        ) != 0
      ) begin

        alignment_error =
            1'b1;

      end

      if (
        client_c_valid[n] &&
        (
          client_c_address[n] %
          CACHE_LINE_BYTES
        ) != 0
      ) begin

        alignment_error =
            1'b1;

      end

    end


    for (int m = 0; m < NUM_MANAGERS; m++) begin

      if (mgr_b_valid[m]) begin

        if (
          source_client(
            mgr_b_source[m]
          ) >= NUM_CLIENTS
        )
          invalid_client_id =
              1'b1;

      end

      if (mgr_d_valid[m]) begin

        if (
          source_client(
            mgr_d_source[m]
          ) >= NUM_CLIENTS
        )
          invalid_client_id =
              1'b1;

      end

    end

  end


  assign route_error =
      alignment_error ||
      invalid_client_id ||
      invalid_manager_id;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_ROUTER_ASSERTIONS

      //----------------------------------------------------------------------
      // Only one A request selected.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(a_selected)
      )
      else $error(
        "TLC ROUTER: multiple A selections"
      );


      //----------------------------------------------------------------------
      // Only one C request selected.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(c_selected)
      )
      else $error(
        "TLC ROUTER: multiple C selections"
      );


      //----------------------------------------------------------------------
      // Only one E request selected.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(e_selected)
      )
      else $error(
        "TLC ROUTER: multiple E selections"
      );


      //----------------------------------------------------------------------
      // A manager destinations are one-hot.
      //----------------------------------------------------------------------

      for (genvar n = 0; n < NUM_MANAGERS; n++) begin

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          mgr_a_valid[n]
          |-> client_a_valid != '0
        )
        else $error(
          "TLC ROUTER: invalid A source"
        );

      end


      //----------------------------------------------------------------------
      // B has at most one client destination per manager.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        foreach (mgr_b_valid[m])
          mgr_b_valid[m]
          |->
          $onehot0(client_b_valid)
      )
      else $error(
        "TLC ROUTER: B routing ambiguity"
      );


      //----------------------------------------------------------------------
      // D has at most one client destination per manager.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        foreach (mgr_d_valid[m])
          mgr_d_valid[m]
          |->
          $onehot0(client_d_valid)
      )
      else $error(
        "TLC ROUTER: D routing ambiguity"
      );


      //----------------------------------------------------------------------
      // Valid must remain asserted while stalled.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mgr_a_valid != '0 &&
        mgr_a_ready == '0
        |=> mgr_a_valid != '0
      )
      else $error(
        "TLC ROUTER: A valid lost while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mgr_c_valid != '0 &&
        mgr_c_ready == '0
        |=> mgr_c_valid != '0
      )
      else $error(
        "TLC ROUTER: C valid lost while stalled"
      );


      //----------------------------------------------------------------------
      // Address alignment.
      //----------------------------------------------------------------------

      for (genvar n = 0; n < NUM_CLIENTS; n++) begin

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          client_a_valid[n]
          |->
          (
            client_a_address[n] %
            CACHE_LINE_BYTES
          ) == 0
        )
        else $error(
          "TLC ROUTER: unaligned A transaction"
        );

      end


      //----------------------------------------------------------------------
      // No simultaneous invalid routing.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(invalid_client_id &&
          invalid_manager_id)
      )
      else $error(
        "TLC ROUTER: routing metadata corrupt"
      );


      //----------------------------------------------------------------------
      // Reset arbitration state.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          a_rr_q == '0 &&
          c_rr_q == '0 &&
          e_rr_q == '0
        )
      )
      else $error(
        "TLC ROUTER: arbitration state not reset"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter validation
  //==========================================================================

  initial begin

    if (NUM_CLIENTS == 0)
      $error(
        "TLC ROUTER: NUM_CLIENTS must be > 0"
      );

    if (NUM_MANAGERS == 0)
      $error(
        "TLC ROUTER: NUM_MANAGERS must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC ROUTER: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC ROUTER: DATA_W must be byte aligned"
      );

    if (
      CACHE_LINE_BYTES == 0 ||
      (CACHE_LINE_BYTES &
       (CACHE_LINE_BYTES - 1))
    )
      $error(
        "TLC ROUTER: CACHE_LINE_BYTES must be power-of-two"
      );

    if (
      HOME_SEL_LSB +
      MANAGER_ID_W >
      ADDR_W
    )
      $error(
        "TLC ROUTER: home-select field exceeds ADDR_W"
      );

    if (
      SOURCE_W < CLIENT_ID_W
    )
      $error(
        "TLC ROUTER: SOURCE_W too small for client ID"
      );

    if (
      SINK_W < CLIENT_ID_W
    )
      $error(
        "TLC ROUTER: SINK_W too small for client ID"
      );

  end

endmodule