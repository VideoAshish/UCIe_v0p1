rtl/
├── ucie_pkg.sv
│
├── adapter/
│   ├── ucie_d2d_adapter.sv
│   │
│   ├── mpg/
│   │   ├── ucie_mpg_mux.sv
│   │   ├── ucie_mpg_arbiter.sv
│   │   ├── ucie_mpg_scheduler.sv
│   │   ├── ucie_mpg_nop_gen.sv
│   │   ├── ucie_mpg_stack_ctrl.sv
│   │   ├── ucie_mpg_credit_mgr.sv
│   │   └── ucie_mpg_sva.sv
│   │
│   ├── flit/
│   │   ├── ucie_flit_formatter.sv
│   │   ├── ucie_flit_parser.sv
│   │   ├── ucie_flit_demux.sv
│   │   └── ucie_flit_nop_filter.sv
│   │
│   ├── retry/
│   │   ├── ucie_crc.sv
│   │   ├── ucie_retry_buffer.sv
│   │   ├── ucie_replay_engine.sv
│   │   └── ucie_seq_manager.sv
│   │
│   ├── link/
│   │   ├── ucie_link_state_machine.sv
│   │   ├── ucie_parameter_negotiation.sv
│   │   └── ucie_link_health.sv
│   │
│   └── sideband/
│       ├── ucie_sideband_tx.sv
│       ├── ucie_sideband_rx.sv
│       └── ucie_priority_sideband.sv
│
└── phy/
    └── ucie_rdi_wrapper.sv