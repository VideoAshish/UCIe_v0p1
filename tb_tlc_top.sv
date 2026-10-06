`timescale 1ns/1ps

module tb_tlc_top;

  //==========================================================================
  // Parameters
  //==========================================================================

  localparam int ADDR_W           = 48;
  localparam int DATA_W           = 256;
  localparam int SOURCE_W         = 8;
  localparam int SINK_W           = 6;

  localparam int BYTE_W           = DATA_W / 8;
  localparam int CACHE_LINE_BYTES = DATA_W / 8;

  localparam int MAX_OUTSTANDING  = 32;
  localparam int MAX_PROBES       = 32;

  localparam int TIMEOUT_CYCLES   = 1000;

  localparam time CLK_PERIOD      = 2ns;


  //==========================================================================
  // Clock / Reset
  //==========================================================================

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;

    forever #(CLK_PERIOD/2)
      clk = ~clk;
  end


  initial begin
    rst_n = 1'b0;

    repeat (10)
      @(posedge clk);

    rst_n = 1'b1;
  end


  //==========================================================================
  // A CHANNEL
  //==========================================================================

  logic                   a_valid;
  logic                   a_ready;

  logic [2:0]             a_opcode;
  logic [2:0]             a_param;
  logic [2:0]             a_size;

  logic [SOURCE_W-1:0]    a_source;

  logic [ADDR_W-1:0]      a_address;

  logic [DATA_W-1:0]      a_data;

  logic [BYTE_W-1:0]      a_mask;


  //==========================================================================
  // B CHANNEL
  //==========================================================================

  logic                   b_valid;
  logic                   b_ready;

  logic [2:0]             b_opcode;
  logic [2:0]             b_param;
  logic [2:0]             b_size;

  logic [SOURCE_W-1:0]    b_source;

  logic [SINK_W-1:0]      b_sink;

  logic [ADDR_W-1:0]      b_address;

  logic [DATA_W-1:0]      b_data;

  logic [BYTE_W-1:0]      b_mask;


  //==========================================================================
  // C CHANNEL
  //==========================================================================

  logic                   c_valid;
  logic                   c_ready;

  logic [2:0]             c_opcode;
  logic [2:0]             c_param;
  logic [2:0]             c_size;

  logic [SOURCE_W-1:0]    c_source;

  logic [SINK_W-1:0]      c_sink;

  logic [ADDR_W-1:0]      c_address;

  logic [DATA_W-1:0]      c_data;

  logic [BYTE_W-1:0]      c_mask;


  //==========================================================================
  // D CHANNEL
  //==========================================================================

  logic                   d_valid;
  logic                   d_ready;

  logic [2:0]             d_opcode;
  logic [2:0]             d_param;
  logic [2:0]             d_size;

  logic [SOURCE_W-1:0]    d_source;

  logic [SINK_W-1:0]      d_sink;

  logic [DATA_W-1:0]      d_data;

  logic                   d_denied;
  logic                   d_corrupt;


  //==========================================================================
  // E CHANNEL
  //==========================================================================

  logic                   e_valid;
  logic                   e_ready;

  logic [SINK_W-1:0]      e_sink;


  //==========================================================================
  // Memory interface
  //==========================================================================

  logic                   mem_valid;
  logic                   mem_ready;
  logic                   mem_write;

  logic [ADDR_W-1:0]      mem_address;

  logic [DATA_W-1:0]      mem_wdata;

  logic [BYTE_W-1:0]      mem_wmask;

  logic                   mem_rvalid;

  logic [DATA_W-1:0]      mem_rdata;

  logic                   mem_error;


  //==========================================================================
  // Error / Status
  //==========================================================================

  logic                   error_active;
  logic                   fatal_error;
  logic                   quarantine;

  logic [31:0]            error_status;

  logic [31:0]            first_error_code;

  logic [ADDR_W-1:0]      first_error_address;

  logic [SOURCE_W-1:0]    first_error_source;

  logic [SINK_W-1:0]      first_error_sink;

  logic                   fatal_interrupt;
  logic                   recoverable_interrupt;


  //==========================================================================
  // DUT
  //==========================================================================

  tlc_top #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),

    .CACHE_LINE_BYTES   (CACHE_LINE_BYTES),

    .NUM_SOURCES        (1 << SOURCE_W),
    .NUM_SINKS          (1 << SINK_W),

    .MAX_OUTSTANDING    (MAX_OUTSTANDING),
    .MAX_PROBES         (MAX_PROBES),

    .FIFO_DEPTH         (4),

    .TIMEOUT_CYCLES     (TIMEOUT_CYCLES),

    .ENABLE_ASSERTIONS  (1'b1),
    .ENABLE_TIMEOUT     (1'b1),
    .ENABLE_ERROR_HANDLER(1'b1)

  ) dut (

    .clk                    (clk),
    .rst_n                  (rst_n),

    // A
    .a_valid                (a_valid),
    .a_ready                (a_ready),
    .a_opcode               (a_opcode),
    .a_param                (a_param),
    .a_size                 (a_size),
    .a_source               (a_source),
    .a_address              (a_address),
    .a_data                 (a_data),
    .a_mask                 (a_mask),

    // B
    .b_valid                (b_valid),
    .b_ready                (b_ready),
    .b_opcode               (b_opcode),
    .b_param                (b_param),
    .b_size                 (b_size),
    .b_source               (b_source),
    .b_sink                  (b_sink),
    .b_address              (b_address),
    .b_data                 (b_data),
    .b_mask                 (b_mask),

    // C
    .c_valid                (c_valid),
    .c_ready                (c_ready),
    .c_opcode               (c_opcode),
    .c_param                (c_param),
    .c_size                 (c_size),
    .c_source               (c_source),
    .c_sink                 (c_sink),
    .c_address              (c_address),
    .c_data                 (c_data),
    .c_mask                 (c_mask),

    // D
    .d_valid                (d_valid),
    .d_ready                (d_ready),
    .d_opcode               (d_opcode),
    .d_param                (d_param),
    .d_size                 (d_size),
    .d_source               (d_source),
    .d_sink                 (d_sink),
    .d_data                 (d_data),
    .d_denied               (d_denied),
    .d_corrupt              (d_corrupt),

    // E
    .e_valid                (e_valid),
    .e_ready                (e_ready),
    .e_sink                 (e_sink),

    // Memory
    .mem_valid              (mem_valid),
    .mem_ready              (mem_ready),
    .mem_write              (mem_write),
    .mem_address            (mem_address),
    .mem_wdata              (mem_wdata),
    .mem_wmask              (mem_wmask),

    .mem_rvalid             (mem_rvalid),
    .mem_rdata              (mem_rdata),
    .mem_error              (mem_error),

    // Error
    .error_active           (error_active),
    .fatal_error            (fatal_error),
    .quarantine             (quarantine),

    .error_status           (error_status),

    .first_error_code       (first_error_code),
    .first_error_address    (first_error_address),
    .first_error_source     (first_error_source),
    .first_error_sink       (first_error_sink),

    .fatal_interrupt        (fatal_interrupt),
    .recoverable_interrupt  (recoverable_interrupt)

  );


  //==========================================================================
  // Test memory
  //==========================================================================

  logic [DATA_W-1:0]
      memory [0:1023];

  function automatic int mem_index(
    input logic [ADDR_W-1:0] addr
  );

    mem_index = addr[11:5];

  endfunction


  //==========================================================================
  // Memory model
  //
  // Simple synchronous model with byte enables.
  //==========================================================================

  always_ff @(posedge clk) begin

    mem_rvalid <= 1'b0;
    mem_error  <= 1'b0;

    if (!rst_n) begin

      mem_rvalid <= 1'b0;
      mem_rdata  <= '0;

    end
    else begin

      if (mem_valid && mem_ready) begin

        if (mem_write) begin

          for (int i = 0; i < BYTE_W; i++) begin

            if (mem_wmask[i])
              memory[mem_index(mem_address)][i*8 +: 8]
                <= mem_wdata[i*8 +: 8];

          end

        end
        else begin

          mem_rdata <= memory[mem_index(mem_address)];

          mem_rvalid <= 1'b1;

        end

      end

    end

  end


  assign mem_ready = 1'b1;


  //==========================================================================
  // Default channel consumers
  //==========================================================================

  //
  // D is normally consumed by the client.
  //

  initial begin

    d_ready = 1'b0;

    wait (rst_n);

    forever begin

      @(posedge clk);

      if ($urandom_range(0, 9) < 8)
        d_ready <= 1'b1;
      else
        d_ready <= 1'b0;

    end

  end


  //
  // B channel consumer.
  //

  initial begin

    b_ready = 1'b1;

    wait (rst_n);

    forever begin

      @(posedge clk);

      if ($urandom_range(0, 9) < 9)
        b_ready <= 1'b1;
      else
        b_ready <= 1'b0;

    end

  end


  //
  // E channel consumer.
  //

  initial begin

    e_ready = 1'b1;

    wait (rst_n);

    forever begin

      @(posedge clk);

      if ($urandom_range(0, 9) < 9)
        e_ready <= 1'b1;
      else
        e_ready <= 1'b0;

    end

  end


  //==========================================================================
  // C-channel defaults
  //==========================================================================

  initial begin

    c_valid   = 1'b0;
    c_opcode  = '0;
    c_param   = '0;
    c_size    = '0;
    c_source  = '0;
    c_sink    = '0;
    c_address = '0;
    c_data    = '0;
    c_mask    = '0;

  end


  //==========================================================================
  // A-channel transaction task
  //==========================================================================

  task automatic send_a(

    input logic [2:0]          opcode,
    input logic [2:0]          param,
    input logic [2:0]          size,
    input logic [SOURCE_W-1:0] source,
    input logic [ADDR_W-1:0]   address,
    input logic [DATA_W-1:0]   data,
    input logic [BYTE_W-1:0]   mask

  );

    @(posedge clk);

    a_valid   <= 1'b1;

    a_opcode  <= opcode;
    a_param   <= param;
    a_size    <= size;
    a_source  <= source;
    a_address <= address;
    a_data    <= data;
    a_mask    <= mask;

    do begin
      @(posedge clk);
    end
    while (!a_ready);

    a_valid <= 1'b0;

    a_opcode  <= '0;
    a_param   <= '0;
    a_size    <= '0;
    a_source  <= '0;
    a_address <= '0;
    a_data    <= '0;
    a_mask    <= '0;

  endtask


  //==========================================================================
  // C-channel transaction task
  //==========================================================================

  task automatic send_c(

    input logic [2:0]          opcode,
    input logic [2:0]          param,
    input logic [2:0]          size,
    input logic [SOURCE_W-1:0] source,
    input logic [SINK_W-1:0]   sink,
    input logic [ADDR_W-1:0]   address,
    input logic [DATA_W-1:0]   data,
    input logic [BYTE_W-1:0]   mask

  );

    @(posedge clk);

    c_valid   <= 1'b1;

    c_opcode  <= opcode;
    c_param   <= param;
    c_size    <= size;
    c_source  <= source;
    c_sink    <= sink;
    c_address <= address;
    c_data    <= data;
    c_mask    <= mask;

    do begin
      @(posedge clk);
    end
    while (!c_ready);

    c_valid <= 1'b0;

    c_opcode  <= '0;
    c_param   <= '0;
    c_size    <= '0;
    c_source  <= '0;
    c_sink    <= '0;
    c_address <= '0;
    c_data    <= '0;
    c_mask    <= '0;

  endtask


  //==========================================================================
  // Opcode definitions
  //
  // These should ultimately come from tlc_pkg.sv.
  //==========================================================================

  localparam logic [2:0] TL_A_PUTFULL = 3'd0;
  localparam logic [2:0] TL_A_PUTPART = 3'd1;
  localparam logic [2:0] TL_A_ARITH   = 3'd2;
  localparam logic [2:0] TL_A_LOGICAL = 3'd3;
  localparam logic [2:0] TL_A_GET     = 3'd4;
  localparam logic [2:0] TL_A_HINT    = 3'd5;

  localparam logic [2:0] TL_C_PROBEACK       = 3'd4;
  localparam logic [2:0] TL_C_PROBEACKDATA   = 3'd5;
  localparam logic [2:0] TL_C_RELEASE        = 3'd6;
  localparam logic [2:0] TL_C_RELEASEDATA    = 3'd7;


  //==========================================================================
  // Test 1
  // Basic GET
  //==========================================================================

  task automatic test_basic_get;

    $display("");
    $display("============================================================");
    $display("TEST: BASIC GET");
    $display("============================================================");

    send_a(
      TL_A_GET,
      3'd0,
      3'd5,
      8'd1,
      48'h0000_0000_0000_0100,
      '0,
      '0
    );

    repeat (20)
      @(posedge clk);

    $display("BASIC GET completed");

  endtask


  //==========================================================================
  // Test 2
  // Full cache-line write
  //==========================================================================

  task automatic test_put_full;

    logic [DATA_W-1:0] data;

    data = '0;

    for (int i = 0; i < DATA_W/8; i++)
      data[i*8 +: 8] = i;

    $display("");
    $display("============================================================");
    $display("TEST: PUT FULL");
    $display("============================================================");

    send_a(
      TL_A_PUTFULL,
      3'd0,
      3'd5,
      8'd2,
      48'h0000_0000_0000_0200,
      data,
      '1
    );

    repeat (20)
      @(posedge clk);

    $display("PUT FULL completed");

  endtask


  //==========================================================================
  // Test 3
  // Partial write
  //==========================================================================

  task automatic test_partial_write;

    logic [DATA_W-1:0] data;
    logic [BYTE_W-1:0] mask;

    data = '0;
    mask = '0;

    for (int i = 0; i < DATA_W/8; i++)
      data[i*8 +: 8] = 8'hA0 + i;

    //
    // Write only alternate bytes.
    //

    for (int i = 0; i < BYTE_W; i++)
      mask[i] = (i % 2) == 0;

    $display("");
    $display("============================================================");
    $display("TEST: PARTIAL WRITE");
    $display("============================================================");

    send_a(
      TL_A_PUTPART,
      3'd0,
      3'd5,
      8'd3,
      48'h0000_0000_0000_0300,
      data,
      mask
    );

    repeat (20)
      @(posedge clk);

    $display("PARTIAL WRITE completed");

  endtask


  //==========================================================================
  // Test 4
  // Multiple outstanding transactions
  //==========================================================================

  task automatic test_multiple_outstanding;

    $display("");
    $display("============================================================");
    $display("TEST: MULTIPLE OUTSTANDING");
    $display("============================================================");

    fork

      send_a(
        TL_A_GET,
        3'd0,
        3'd5,
        8'd10,
        48'h1000,
        '0,
        '0
      );

      send_a(
        TL_A_GET,
        3'd0,
        3'd5,
        8'd11,
        48'h1100,
        '0,
        '0
      );

      send_a(
        TL_A_GET,
        3'd0,
        3'd5,
        8'd12,
        48'h1200,
        '0,
        '0
      );

      send_a(
        TL_A_GET,
        3'd0,
        3'd5,
        8'd13,
        48'h1300,
        '0,
        '0
      );

    join

    repeat (100)
      @(posedge clk);

    $display("MULTIPLE OUTSTANDING completed");

  endtask


  //==========================================================================
  // Test 5
  // Backpressure
  //==========================================================================

  task automatic test_backpressure;

    $display("");
    $display("============================================================");
    $display("TEST: BACKPRESSURE");
    $display("============================================================");

    d_ready = 1'b0;

    fork

      begin
        send_a(
          TL_A_GET,
          3'd0,
          3'd5,
          8'd20,
          48'h2000,
          '0,
          '0
        );
      end

      begin
        repeat (30)
          @(posedge clk);

        d_ready = 1'b1;

      end

    join

    repeat (30)
      @(posedge clk);

    d_ready = 1'b1;

    $display("BACKPRESSURE completed");

  endtask


  //==========================================================================
  // Test 6
  // Random traffic
  //==========================================================================

  task automatic test_random_traffic;

    logic [SOURCE_W-1:0] source;
    logic [ADDR_W-1:0] address;
    logic [DATA_W-1:0] data;
    logic [BYTE_W-1:0] mask;

    $display("");
    $display("============================================================");
    $display("TEST: RANDOM TRAFFIC");
    $display("============================================================");

    for (int i = 0; i < 100; i++) begin

      source  = $urandom_range(0, MAX_OUTSTANDING-1);

      //
      // Keep addresses cache-line aligned.
      //

      address = {$urandom, $urandom};

      address[CACHE_LINE_BYTES > 1 ?
              $clog2(CACHE_LINE_BYTES)-1 : 0 : 0] = '0;

      data = {$urandom, $urandom,
              $urandom, $urandom};

      mask = $urandom;

      if ($urandom_range(0, 1)) begin

        send_a(
          TL_A_GET,
          3'd0,
          3'd5,
          source,
          address,
          '0,
          '0
        );

      end
      else begin

        send_a(
          TL_A_PUTFULL,
          3'd0,
          3'd5,
          source,
          address,
          data,
          mask
        );

      end

    end

    repeat (200)
      @(posedge clk);

    $display("RANDOM TRAFFIC completed");

  endtask


  //==========================================================================
  // Protocol monitor
  //==========================================================================

  always @(posedge clk) begin

    if (rst_n) begin

      //
      // A stability requirement.
      //

      if (a_valid && !a_ready) begin

        assert ($stable(a_opcode))
          else $error("A opcode changed while stalled");

        assert ($stable(a_source))
          else $error("A source changed while stalled");

        assert ($stable(a_address))
          else $error("A address changed while stalled");

        assert ($stable(a_data))
          else $error("A data changed while stalled");

        assert ($stable(a_mask))
          else $error("A mask changed while stalled");

      end


      //
      // B stability.
      //

      if (b_valid && !b_ready) begin

        assert ($stable(b_opcode))
          else $error("B opcode changed while stalled");

        assert ($stable(b_source))
          else $error("B source changed while stalled");

        assert ($stable(b_sink))
          else $error("B sink changed while stalled");

        assert ($stable(b_address))
          else $error("B address changed while stalled");

      end


      //
      // C stability.
      //

      if (c_valid && !c_ready) begin

        assert ($stable(c_opcode))
          else $error("C opcode changed while stalled");

        assert ($stable(c_source))
          else $error("C source changed while stalled");

        assert ($stable(c_sink))
          else $error("C sink changed while stalled");

        assert ($stable(c_address))
          else $error("C address changed while stalled");

      end


      //
      // D stability.
      //

      if (d_valid && !d_ready) begin

        assert ($stable(d_opcode))
          else $error("D opcode changed while stalled");

        assert ($stable(d_source))
          else $error("D source changed while stalled");

        assert ($stable(d_sink))
          else $error("D sink changed while stalled");

        assert ($stable(d_data))
          else $error("D data changed while stalled");

      end


      //
      // E stability.
      //

      if (e_valid && !e_ready) begin

        assert ($stable(e_sink))
          else $error("E sink changed while stalled");

      end

    end

  end


  //==========================================================================
  // Error monitor
  //==========================================================================

  always @(posedge clk) begin

    if (rst_n) begin

      if (fatal_error) begin

        $error(
          "[TL-C] FATAL ERROR status=%h code=%h addr=%h source=%h sink=%h",
          error_status,
          first_error_code,
          first_error_address,
          first_error_source,
          first_error_sink
        );

      end

    end

  end


  //==========================================================================
  // Timeout watchdog for testbench
  //==========================================================================

  initial begin

    wait (rst_n);

    fork

      begin

        repeat (100000)
          @(posedge clk);

        $fatal(
          1,
          "TB TIMEOUT: simulation exceeded maximum duration"
        );

      end

      begin

        wait (fatal_error);

        $display(
          "Simulation stopped because DUT entered fatal-error state"
        );

      end

    join_any

  end


  //==========================================================================
  // Waveform dump
  //==========================================================================

  initial begin

    $dumpfile("tb_tlc_top.vcd");
    $dumpvars(0, tb_tlc_top);

  end


  //==========================================================================
  // Main test sequence
  //==========================================================================

  initial begin

    //
    // Initialize A channel.
    //

    a_valid   = 1'b0;
    a_opcode  = '0;
    a_param   = '0;
    a_size    = '0;
    a_source  = '0;
    a_address = '0;
    a_data    = '0;
    a_mask    = '0;

    //
    // Initialize memory.
    //

    for (int i = 0; i < 1024; i++)
      memory[i] = '0;

    //
    // Wait for reset.
    //

    wait (rst_n);

    repeat (5)
      @(posedge clk);


    //=======================================================================
    // TEST 1
    //=======================================================================

    test_basic_get;


    //=======================================================================
    // TEST 2
    //=======================================================================

    test_put_full;


    //=======================================================================
    // TEST 3
    //=======================================================================

    test_partial_write;


    //=======================================================================
    // TEST 4
    //=======================================================================

    test_multiple_outstanding;


    //=======================================================================
    // TEST 5
    //=======================================================================

    test_backpressure;


    //=======================================================================
    // TEST 6
    //=======================================================================

    test_random_traffic;


    //=======================================================================
    // Final
    //=======================================================================

    repeat (100)
      @(posedge clk);

    if (fatal_error) begin

      $display("");
      $display("============================================================");
      $display("TL-C TEST FAILED");
      $display("============================================================");

      $fatal(1);

    end
    else begin

      $display("");
      $display("============================================================");
      $display("TL-C TEST PASSED");
      $display("============================================================");

      $finish;

    end

  end


endmodule