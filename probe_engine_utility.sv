                         ┌──────────────────┐
                         │ tlc_directory    │
                         │                  │
                         │ target_clients   │
                         │ owner            │
                         │ dirty            │
                         └────────┬─────────┘
                                  │
                                  │ req_targets
                                  ▼
                       ┌────────────────────┐
                       │ tlc_permission_mgr│
                       │                    │
                       │ need_probe         │
                       │ dirty_required     │
                       └─────────┬──────────┘
                                 │
                                 ▼
                       ┌────────────────────┐
                       │ tlc_probe_engine   │
                       │                    │
                       │ target bitmap      │
                       │ sent bitmap        │
                       │ ack bitmap         │
                       │ dirty collection   │
                       └───────┬───────┬────┘
                               │       │
                          B    │       │ C
                               ▼       ▲
                         ┌────────┐ ┌────────┐
                         │ B Chan │ │ C Chan │
                         └────────┘ └────────┘
						 
//=============================================================//

targets = 1011

Client 0 ── Probe ──► ProbeAck
Client 1 ── Probe ──► ProbeAckData
Client 2             no probe
Client 3 ── Probe ──► ProbeAck

sent = 1011
ack  = 1011
             │
             ▼
      probe_complete = 1
      dirty_received = 1
	  
//==============================================================//

B Probe:
    source_id
    client_id
    address
    param

              ↓

C ProbeAck:
    source_id
    client_id
    opcode
    param
    data
	
//================================================================//

source_id ───────► probe transaction
                         │
                         ├── address
                         ├── requester
                         ├── target bitmap
                         ├── sent bitmap
                         ├── ack bitmap
                         ├── dirty owner
                         └── dirty data
						 
//=================================================================//

