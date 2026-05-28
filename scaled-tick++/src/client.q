// scaled-tick++/src/client.q - Interactive Q Client
//
// Usage: source .env && q scaled-tick++/src/client.q -gwPort $GW_PORT -rtePort $RTE_PORT \
//          -rdbPort $RDB_PORT -hdbPort $HDB_PORT -tpPort $TICK_PORT -fhPort $FH_PORT \
//          -procName client1
//
// Opens IPC handles to each process in the stack so the running q session can issue
// queries directly. Failed connections log a warning and leave the handle null; the
// process continues so partial-stack scenarios are still usable.
//
// Example usage (once running):
//   GW_H (`.kxgw.query; `rdb; "select from energy")
//   GW_H (`.kxgw.query; `idb; "select from energy")
//   GW_H (`.kxgw.query; `hdb; ({[tab;d] select from tab where date=d}; `energy; 2026.04.17))
//   GW_H (`.kxgw.query; `all;  ("select from energy"; "select from energy"; "select from energy where date=2026.04.17"))
//   RDB_H "tables[]"
//   HDB_H "tables[]"

system"l scaled-tick++/utils/main.q";

.log.info["Initializing Q client"];

// @desc IPC handle to the Feedhandler — null when FH is unreachable at startup
FH_H:@[hopen; `$"::",first CLI_ARGS[`fhPort];  {.log.warn["Failed to connect to FH: ", x]; 0N}];

// @desc IPC handle to the Gateway — entry point for `.kxgw.query` calls
GW_H:@[hopen; `$"::",first CLI_ARGS[`gwPort];  {.log.warn["Failed to connect to GW: ", x]; 0N}];

// @desc IPC handle to the Tickerplant — useful for `.u.end[date]` and `.u.sub[...]`
TP_H:@[hopen; `$"::",first CLI_ARGS[`tpPort];  {.log.warn["Failed to connect to TP: ", x]; 0N}];

// @desc IPC handle to the Real-Time Engine
RTE_H:@[hopen; `$"::",first CLI_ARGS[`rtePort]; {.log.warn["Failed to connect to RTE: ",x]; 0N}];

// @desc IPC handle to the Realtime Database — direct (non-gateway) RDB queries
RDB_H:@[hopen; `$"::",first CLI_ARGS[`rdbPort]; {.log.warn["Failed to connect to RDB: ",x]; 0N}];

// @desc IPC handle to the Historical Database — direct (non-gateway) HDB queries
HDB_H:@[hopen; `$"::",first CLI_ARGS[`hdbPort]; {.log.warn["Failed to connect to HDB: ",x]; 0N}];

.log.info["Successfully initialized Q client"];
.log.info[("  FH_H:  %s"; $[null FH_H;  "NOT CONNECTED"; string FH_H])];
.log.info[("  GW_H:  %s"; $[null GW_H;  "NOT CONNECTED"; string GW_H])];
.log.info[("  TP_H:  %s"; $[null TP_H;  "NOT CONNECTED"; string TP_H])];
.log.info[("  RTE_H: %s"; $[null RTE_H; "NOT CONNECTED"; string RTE_H])];
.log.info[("  RDB_H: %s"; $[null RDB_H; "NOT CONNECTED"; string RDB_H])];
.log.info[("  HDB_H: %s"; $[null HDB_H; "NOT CONNECTED"; string HDB_H])];
