// Interactive q client with handles to core processes
// Usage: source .env && q kdb-x-platform/client.q -gwPort 5013 -qrPort 5015 -rdbPort 5011 -hdbPort 5012 -procName client1
// CLI args: -gwPort <port> -qrPort <port> -tpPort <port> -rdbPort <port> -hdbPort <port> -procName <name>

system"l utils/main.q";

.log.info["Initialising Q client"];

// Open handles to core processes
FH_H:@[hopen; `$"::",first CLI_ARGS[`fhPort]; {.log.warn["Failed to connect to FH: ",x]; 0N}];
GW_H:@[hopen; `$"::",first CLI_ARGS[`gwPort]; {.log.warn["Failed to connect to GW: ",x]; 0N}];
QR_H:@[hopen; `$"::",first CLI_ARGS[`qrPort]; {.log.warn["Failed to connect to QR: ",x]; 0N}];
TP_H:@[hopen; `$"::",first CLI_ARGS[`tpPort]; {.log.warn["Failed to connect to TP: ",x]; 0N}];
RTE_H:@[hopen; `$"::",first CLI_ARGS[`rtePort]; {.log.warn["Failed to connect to RTE: ",x]; 0N}];
RDB_H:@[hopen; `$"::",first CLI_ARGS[`rdbPort]; {.log.warn["Failed to connect to RDB: ",x]; 0N}];
HDB_H:@[hopen; `$"::",first CLI_ARGS[`hdbPort]; {.log.warn["Failed to connect to HDB: ",x]; 0N}];

.log.info["Successfully initialised Q client"];
.log.info[("  FH_H:  %s";$[null FH_H; "NOT CONNECTED";string FH_H])];
.log.info[("  GW_H:  %s";$[null GW_H; "NOT CONNECTED";string GW_H])];
.log.info[("  QR_H:  %s";$[null QR_H; "NOT CONNECTED";string QR_H])];
.log.info[("  TP_H: %s";$[null TP_H;"NOT CONNECTED";string TP_H])];
.log.info[("  RTE_H: %s";$[null RTE_H;"NOT CONNECTED";string RTE_H])];
.log.info[("  RDB_H: %s";$[null RDB_H;"NOT CONNECTED";string RDB_H])];
.log.info[("  HDB_H: %s";$[null HDB_H;"NOT CONNECTED";string HDB_H])];

// Example usage:
//   GW_H (`.kxgw.query; `rdb; "select from energy")
//   QR_H "WORKERS"
//   RDB_H "tables[]"
//   HDB_H "tables[]"
