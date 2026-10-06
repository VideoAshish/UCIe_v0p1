//==============================================================================
// tlc_crossbar.sv
//
// TileLink-C Multi-Client Crossbar
//
//                         +----------------------+
// Client 0 -------------->|                      |
// Client 1 -------------->|                      |
// Client 2 -------------->|     TL-C XBAR        |----> Manager
//    ...                   |                      |<---- Manager
// Client N -------------->|                      |
//                         +----------------------+
//
// Client -> Manager
// -----------------
// A : arbitration
// C : arbitration
// E : arbitration
//
// Manager -> Client
// -----------------
// B : source-ID based routing
// D : source-ID based routing
//
// E routing
// ---------
// E uses sink-ID based client routing.
//
// ID encoding
// -----------
// SOURCE_W = CLIENT_ID_W + LOCAL_SOURCE_W
// SINK_W   = CLIENT_ID_W + LOCAL_SINK_W
//
// source[ SOURCE_W-1 : LOCAL_SOURCE_W ]
//       = client ID
//
// sink[ SINK_W-1 : LOCAL_SINK_W ]
//       = client ID
//
//==============================================================================

module tlc_crossbar #(

  parameter int unsigned NUM_CLIENTS =
      4,

  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned SINK_W =
      6,

  parameter int unsigned CLIENT_ID_W =
      (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS),

  parameter int unsigned LOCAL_SOURCE_W =
      (SOURCE_W > CLIENT_ID_W) ?
      SOURCE_W - CLIENT_ID_W :
      1,

  parameter int unsigned LOCAL_SINK_W =
      (SINK_W > CLIENT_ID_W) ?
      SINK_W - CLIENT_ID_W :
      1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1

) (

  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Client-side TL-C interfaces
  //==========================================================================

  //-------------------------------------------------------------------------
  // A channel : Client -> Manager
  //-------------------------------------------------------------------------

  input  logic [NUM_CLIENTS-1:0]
      c_a_valid,

  output logic [NUM_CLIENTS-1:0]
      c_a_ready,

  input  logic [2:0]
      c_a_opcode [NUM_CLIENTS],

  input  logic [2:0]
      c_a_param [NUM_CLIENTS],

  input  logic [2:0]
      c_a_size [NUM_CLIENTS],

  input  logic [SOURCE_W-1:0]
      c_a_source [NUM_CLIENTS],

  input  logic [ADDR_W-1:0]
      c_a_address [NUM_CLIENTS],

  input  logic [DATA_W-1:0]
      c_a_data [NUM_CLIENTS],

  input  logic [DATA_W/8-1:0]
      c_a_mask [NUM_CLIENTS],

  //-------------------------------------------------------------------------
  // B channel : Manager -> Client
  //-------------------------------------------------------------------------

  output logic [NUM_CLIENTS-1:0]
      c_b_valid,

  input logic [NUM_CLIENTS-1:0]
      c_b_ready,

  output logic [2:0]
      c_b_opcode [NUM_CLIENTS],

  output logic [2:0]
      c_b_param [NUM_CLIENTS],

  output logic [2:0]
      c_b_size [NUM_CLIENTS],

  output logic [SOURCE_W-1:0]
      c_b_source [NUM_CLIENTS],

  output logic [ADDR_W-1:0]
      c_b_address [NUM_CLIENTS],

  output logic [DATA_W-1:0]
      c_b_data [NUM_CLIENTS],

  output logic [DATA_W/8-1:0]
      c_b_mask [NUM_CLIENTS],

  output logic [SINK_W-1:0]
      c_b_sink [NUM_CLIENTS],

  //-------------------------------------------------------------------------
  // C channel : Client -> Manager
  //-------------------------------------------------------------------------

  input logic [NUM_CLIENTS-1:0]
      c_c_valid,

  output logic [NUM_CLIENTS-1:0]
      c_c_ready,

  input logic [2:0]
      c_c_opcode [NUM_CLIENTS],

  input logic [2:0]
      c_c_param [NUM_CLIENTS],

  input logic [2:0]
      c_c_size [NUM_CLIENTS],

  input logic [SOURCE_W-1:0]
      c_c_source [NUM_CLIENTS],

  input logic [SINK_W-1:0]
      c_c_sink [NUM_CLIENTS],

  input logic [ADDR_W-1:0]
      c_c_address [NUM_CLIENTS],

  input logic [DATA_W-1:0]
      c_c_data [NUM_CLIENTS],

  input logic [DATA_W/8-1:0]
      c_c_mask [NUM_CLIENTS],

  //-------------------------------------------------------------------------
  // D channel : Manager -> Client
  //-------------------------------------------------------------------------

  output logic [NUM_CLIENTS-1:0]
      c_d_valid,

  input logic [NUM_CLIENTS-1:0]
      c_d_ready,

  output logic [2:0]
      c_d_opcode [NUM_CLIENTS],

  output logic [2:0]
      c_d_param [NUM_CLIENTS],

  output logic [2:0]
      c_d_size [NUM_CLIENTS],

  output logic [SOURCE_W-1:0]
      c_d_source [NUM_CLIENTS],

  output logic [SINK_W-1:0]
      c_d_sink [NUM_CLIENTS],

  output logic [DATA_W-1:0]
      c_d_data [NUM_CLIENTS],

  output logic
      c_d_denied [NUM_CLIENTS],

  output logic
      c_d_corrupt [NUM_CLIENTS],

  //-------------------------------------------------------------------------
  // E channel : Client -> Manager
  //-------------------------------------------------------------------------

  input logic [NUM_CLIENTS-1:0]
      c_e_valid,

  output logic [NUM_CLIENTS-1:0]
      c_e_ready,

  input logic [SINK_W-1:0]
      c_e_sink [NUM_CLIENTS],


  //==========================================================================
  // Manager-side TL-C interface
  //==========================================================================

  //-------------------------------------------------------------------------
  // A
  //-------------------------------------------------------------------------

  output logic
      m_a_valid,

  input logic
      m_a_ready,

  output logic [2:0]
      m_a_opcode,

  output logic [2:0]
      m_a_param,

  output logic [2:0]
      m_a_size,

  output logic [SOURCE_W-1:0]
      m_a_source,

  output logic [ADDR_W-1:0]
      m_a_address,

  output logic [DATA_W-1:0]
      m_a_data,

  output logic [DATA_W/8-1:0]
      m_a_mask,

  //-------------------------------------------------------------------------
  // B
  //-------------------------------------------------------------------------

  input logic
      m_b_valid,

  output logic
      m_b_ready,

  input logic [2:0]
      m_b_opcode,

  input logic [2:0]
      m_b_param,

  input logic [2:0]
      m_b_size,

  input logic [SOURCE_W-1:0]
      m_b_source,

  input logic [ADDR_W-1:0]
      m_b_address,

  input logic [DATA_W-1:0]
      m_b_data,

  input logic [DATA_W/8-1:0]
      m_b_mask,

  input logic [SINK_W-1:0]
      m_b_sink,

  //-------------------------------------------------------------------------
  // C
  //-------------------------------------------------------------------------

  output logic
      m_c_valid,

  input logic
      m_c_ready,

  output logic [2:0]
      m_c_opcode,

  output logic [2:0]
      m_c_param,

  output logic [2:0]
      m_c_size,

  output logic [SOURCE_W-1:0]
      m_c_source,

  output logic [SINK_W-1:0]
      m_c_sink,

  output logic [ADDR_W-1:0]
      m_c_address,

  output logic [DATA_W-1:0]
      m_c_data,

  output logic [DATA_W/8-1:0]
      m_c_mask,

  //-------------------------------------------------------------------------
  // D
  //-------------------------------------------------------------------------

  input logic
      m_d_valid,

  output logic
      m_d_ready,

  input logic [2:0]
      m_d_opcode,

  input logic [2:0]
      m_d_param,

  input logic [2:0]
      m_d_size,

  input logic [SOURCE_W-1:0]
      m_d_source,

  input logic [SINK_W-1:0]
      m_d_sink,

  input logic [DATA_W-1:0]
      m_d_data,

  input logic
      m_d_denied,

  input logic
      m_d_corrupt,

  //-------------------------------------------------------------------------
  // E
  //-------------------------------------------------------------------------

  output logic
      m_e_valid,

  input logic
      m_e_ready,

  output logic [SINK_W-1:0]
      m_e_sink

);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned RR_W =
      (NUM_CLIENTS <= 1) ?
      1 :
      $clog2(NUM_CLIENTS);


  //==========================================================================
  // Arbitration pointers
  //==========================================================================

  logic [RR_W-1:0]
      a_rr_q;

  logic [RR_W-1:0]
      c_rr_q;

  logic [RR_W-1:0]
      e_rr_q;


  //==========================================================================
  // Arbitration grants
  //==========================================================================

  logic [NUM_CLIENTS-1:0]
      a_grant;

  logic [NUM_CLIENTS-1:0]
      c_grant;

  logic [NUM_CLIENTS-1:0]
      e_grant;

  logic
      a_grant_valid;

  logic
      c_grant_valid;

  logic
      e_grant_valid;

  logic [RR_W-1:0]
      a_sel;

  logic [RR_W-1:0]
      c_sel;

  logic [RR_W-1:0]
      e_sel;


  //==========================================================================
  // Generic round-robin arbitration
  //
  // Combinational selection only.
  // Output ready is generated from registered arbitration state and the
  // selected request. No downstream ready is fed back into request selection.
  //==========================================================================

  integer i;
  integer idx;

  always_comb begin

    a_grant =
        '0;

    a_grant_valid =
        1'b0;

    a_sel =
        '0;

    for (int offset = 0;
         offset < NUM_CLIENTS;
         offset++) begin

      idx =
          (a_rr_q + offset) % NUM_CLIENTS;

      if (
        !a_grant_valid &&
        c_a_valid[idx]
      ) begin

        a_grant[idx] =
            1'b1;

        a_grant_valid =
            1'b1;

        a_sel =
            idx[RR_W-1:0];

      end

    end

  end


  always_comb begin

    c_grant =
        '0;

    c_grant_valid =
        1'b0;

    c_sel =
        '0;

    for (int offset = 0;
         offset < NUM_CLIENTS;
         offset++) begin

      idx =
          (c_rr_q + offset) % NUM_CLIENTS;

      if (
        !c_grant_valid &&
        c_c_valid[idx]
      ) begin

        c_grant[idx] =
            1'b1;

        c_grant_valid =
            1'b1;

        c_sel =
            idx[RR_W-1:0];

      end

    end

  end


  always_comb begin

    e_grant =
        '0;

    e_grant_valid =
        1'b0;

    e_sel =
        '0;

    for (int offset = 0;
         offset < NUM_CLIENTS;
         offset++) begin

      idx =
          (e_rr_q + offset) % NUM_CLIENTS;

      if (
        !e_grant_valid &&
        c_e_valid[idx]
      ) begin

        e_grant[idx] =
            1'b1;

        e_grant_valid =
            1'b1;

        e_sel =
            idx[RR_W-1:0];

      end

    end

  end


  //==========================================================================
  // A channel
  //==========================================================================

  always_comb begin

    m_a_valid =
        a_grant_valid;

    m_a_opcode =
        '0;

    m_a_param =
        '0;

    m_a_size =
        '0;

    m_a_source =
        '0;

    m_a_address =
        '0;

    m_a_data =
        '0;

    m_a_mask =
        '0;

    for (int n = 0;
         n < NUM_CLIENTS;
         n++) begin

      c_a_ready[n] =
          a_grant[n] &&
          m_a_ready;

    end

    if (a_grant_valid) begin

      m_a_opcode =
          c_a_opcode[a_sel];

      m_a_param =
          c_a_param[a_sel];

      m_a_size =
          c_a_size[a_sel];

      m_a_source =
          c_a_source[a_sel];

      m_a_address =
          c_a_address[a_sel];

      m_a_data =
          c_a_data[a_sel];

      m_a_mask =
          c_a_mask[a_sel];

    end

  end


  //==========================================================================
  // C channel
  //==========================================================================

  always_comb begin

    m_c_valid =
        c_grant_valid;

    m_c_opcode =
        '0;

    m_c_param =
        '0;

    m_c_size =
        '0;

    m_c_source =
        '0;

    m_c_sink =
        '0;

    m_c_address =
        '0;

    m_c_data =
        '0;

    m_c_mask =
        '0;

    for (int n = 0;
         n < NUM_CLIENTS;
         n++) begin

      c_c_ready[n] =
          c_grant[n] &&
          m_c_ready;

    end

    if (c_grant_valid) begin

      m_c_opcode =
          c_c_opcode[c_sel];

      m_c_param =
          c_c_param[c_sel];

      m_c_size =
          c_c_size[c_sel];

      m_c_source =
          c_c_source[c_sel];

      m_c_sink =
          c_c_sink[c_sel];

      m_c_address =
          c_c_address[c_sel];

      m_c_data =
          c_c_data[c_sel];

      m_c_mask =
          c_c_mask[c_sel];

    end

  end


  //==========================================================================
  // E channel
  //==========================================================================

  always_comb begin

    m_e_valid =
        e_grant_valid;

    m_e_sink =
        '0;

    for (int n = 0;
         n < NUM_CLIENTS;
         n++) begin

      c_e_ready[n] =
          e_grant[n] &&
          m_e_ready;

    end

    if (e_grant_valid) begin

      m_e_sink =
          c_e_sink[e_sel];

    end

  end


  //==========================================================================
  // Extract destination client from SOURCE ID
  //==========================================================================

  logic [CLIENT_ID_W-1:0]
      d_client_id;

  logic [CLIENT_ID_W-1:0]
      b_client_id;

  logic [CLIENT_ID_W-1:0]
      e_client_id;

  assign d_client_id =
      m_d_source[SOURCE_W-1 -: CLIENT_ID_W];

  assign b_client_id =
      m_b_source[SOURCE_W-1 -: CLIENT_ID_W];

  assign e_client_id =
      m_e_sink[SINK_W-1 -: CLIENT_ID_W];


  //==========================================================================
  // Validate client ID
  //==========================================================================

  logic d_client_valid;
  logic b_client_valid;
  logic e_client_valid;

  always_comb begin

    d_client_valid =
        (d_client_id < NUM_CLIENTS);

    b_client_valid =
        (b_client_id < NUM_CLIENTS);

    e_client_valid =
        (e_client_id < NUM_CLIENTS);

  end


  //==========================================================================
  // B channel
  //
  // Manager -> client.
  //
  // Routing is based on the client ID encoded in source.
  //==========================================================================

  always_comb begin

    c_b_valid =
        '0;

    c_b_opcode =
        '{default:'0};

    c_b_param =
        '{default:'0};

    c_b_size =
        '{default:'0};

    c_b_source =
        '{default:'0};

    c_b_address =
        '{default:'0};

    c_b_data =
        '{default:'0};

    c_b_mask =
        '{default:'0};

    c_b_sink =
        '{default:'0};

    m_b_ready =
        1'b0;

    if (
      m_b_valid &&
      b_client_valid
    ) begin

      c_b_valid[b_client_id] =
          1'b1;

      c_b_opcode[b_client_id] =
          m_b_opcode;

      c_b_param[b_client_id] =
          m_b_param;

      c_b_size[b_client_id] =
          m_b_size;

      c_b_source[b_client_id] =
          m_b_source;

      c_b_address[b_client_id] =
          m_b_address;

      c_b_data[b_client_id] =
          m_b_data;

      c_b_mask[b_client_id] =
          m_b_mask;

      c_b_sink[b_client_id] =
          m_b_sink;

      m_b_ready =
          c_b_ready[b_client_id];

    end

  end


  //==========================================================================
  // D channel
  //
  // Manager -> client.
  //
  // Routing based on source ID.
  //==========================================================================

  always_comb begin

    c_d_valid =
        '0;

    c_d_opcode =
        '{default:'0};

    c_d_param =
        '{default:'0};

    c_d_size =
        '{default:'0};

    c_d_source =
        '{default:'0};

    c_d_sink =
        '{default:'0};

    c_d_data =
        '{default:'0};

    c_d_denied =
        '0;

    c_d_corrupt =
        '0;

    m_d_ready =
        1'b0;

    if (
      m_d_valid &&
      d_client_valid
    ) begin

      c_d_valid[d_client_id] =
          1'b1;

      c_d_opcode[d_client_id] =
          m_d_opcode;

      c_d_param[d_client_id] =
          m_d_param;

      c_d_size[d_client_id] =
          m_d_size;

      c_d_source[d_client_id] =
          m_d_source;

      c_d_sink[d_client_id] =
          m_d_sink;

      c_d_data[d_client_id] =
          m_d_data;

      c_d_denied[d_client_id] =
          m_d_denied;

      c_d_corrupt[d_client_id] =
          m_d_corrupt;

      m_d_ready =
          c_d_ready[d_client_id];

    end

  end


  //==========================================================================
  // Round-robin pointer update
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

      //----------------------------------------------------------------------
      // A arbitration
      //----------------------------------------------------------------------

      if (
        m_a_valid &&
        m_a_ready
      ) begin

        if (
          a_sel ==
          NUM_CLIENTS-1
        ) begin

          a_rr_q <=
              '0;

        end
        else begin

          a_rr_q <=
              a_sel + 1'b1;

        end

      end


      //----------------------------------------------------------------------
      // C arbitration
      //----------------------------------------------------------------------

      if (
        m_c_valid &&
        m_c_ready
      ) begin

        if (
          c_sel ==
          NUM_CLIENTS-1
        ) begin

          c_rr_q <=
              '0;

        end
        else begin

          c_rr_q <=
              c_sel + 1'b1;

        end

      end


      //----------------------------------------------------------------------
      // E arbitration
      //----------------------------------------------------------------------

      if (
        m_e_valid &&
        m_e_ready
      ) begin

        if (
          e_sel ==
          NUM_CLIENTS-1
        ) begin

          e_rr_q <=
              '0;

        end
        else begin

          e_rr_q <=
              e_sel + 1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Protocol assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_XBAR_ASSERTIONS

      //======================================================================
      // A channel: only one client may be selected.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(a_grant)
      )
      else $error(
        "TLC XBAR: multiple A-channel grants"
      );


      //======================================================================
      // C channel: only one client may be selected.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(c_grant)
      )
      else $error(
        "TLC XBAR: multiple C-channel grants"
      );


      //======================================================================
      // E channel: only one client may be selected.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(e_grant)
      )
      else $error(
        "TLC XBAR: multiple E-channel grants"
      );


      //======================================================================
      // B output cannot be sent to multiple clients.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(c_b_valid)
      )
      else $error(
        "TLC XBAR: B-channel multicast"
      );


      //======================================================================
      // D output cannot be sent to multiple clients.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        $onehot0(c_d_valid)
      )
      else $error(
        "TLC XBAR: D-channel multiple routing"
      );


      //======================================================================
      // Valid must remain asserted while stalled.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_a_valid &&
        !m_a_ready
        |=> m_a_valid
      )
      else $error(
        "TLC XBAR: A valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_c_valid &&
        !m_c_ready
        |=> m_c_valid
      )
      else $error(
        "TLC XBAR: C valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_e_valid &&
        !m_e_ready
        |=> m_e_valid
      )
      else $error(
        "TLC XBAR: E valid changed while stalled"
      );


      //======================================================================
      // B destination must be valid.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_b_valid
        |-> b_client_valid
      )
      else $error(
        "TLC XBAR: invalid B destination"
      );


      //======================================================================
      // D destination must be valid.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_d_valid
        |-> d_client_valid
      )
      else $error(
        "TLC XBAR: invalid D destination"
      );


      //======================================================================
      // E destination must be valid.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_e_valid
        |-> e_client_valid
      )
      else $error(
        "TLC XBAR: invalid E destination"
      );


      //======================================================================
      // No A starvation due to multiple grant.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_a_valid
        |-> $onehot(a_grant)
      )
      else $error(
        "TLC XBAR: A valid without exactly one grant"
      );


      //======================================================================
      // No C starvation due to multiple grant.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        m_c_valid
        |-> $onehot(c_grant)
      )
      else $error(
        "TLC XBAR: C valid without exactly one grant"
      );


      //======================================================================
      // Reset pointers known.
      //======================================================================

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
        "TLC XBAR: arbitration pointer not reset"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Parameter checks
  //==========================================================================

  initial begin

    if (NUM_CLIENTS == 0) begin

      $error(
        "TLC XBAR: NUM_CLIENTS must be > 0"
      );

    end


    if (DATA_W == 0) begin

      $error(
        "TLC XBAR: DATA_W must be > 0"
      );

    end


    if ((DATA_W % 8) != 0) begin

      $error(
        "TLC XBAR: DATA_W must be byte aligned"
      );

    end


    if (SOURCE_W <= CLIENT_ID_W) begin

      $error(
        "TLC XBAR: SOURCE_W must be greater than CLIENT_ID_W"
      );

    end


    if (SINK_W <= CLIENT_ID_W) begin

      $error(
        "TLC XBAR: SINK_W must be greater than CLIENT_ID_W"
      );

    end

  end

endmodule