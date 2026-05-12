// RTE - Real-Time Engine
// Loads 'enrichment' file which defines subscriptions to TP tables & enrichment functions to apply to them.
// Subscribes to TP tables in .rte.subscriptions dictionary
// Runs enrichment functions in .rte.enrichmentDict against incoming data for the table
// Single instance, lives in the realtime module alongside RDB.
// Flow: FH -> TP (.rte.subscriptions) -> RTE (.rte.enrichmentDict) -> TP (.rte.pub) -> RDB

system"l utils/main.q";

.log.info["Initialising RTE"];

// TP handle - tracked for reconnection
TP_H:0N;

// Mapping dictionaries
.rte.enrichmentDict: ()!(); /enrichment function -> table name
.rte.subscriptions: ()!(); /table -> syms to subscribe to from TP

// Mapping helpers
// Add a subscription for table/syms 
.rte.addSubscription: {[tab;syms]
    .log.trace[(".rte.addSubscription: table [%s] and syms [%s]"; string[tab]; string[syms])];
    if[not 11h = abs type syms;
        .log.error[("Subscription rejected for table [%s]: syms type does not match, expected symbol but got type [%s]"; string[tab]; string type syms)];
        :()
        ];
    $[tab in key[.rte.subscriptions];
        [
            .rte.subscriptions[tab]: distinct .rte.subscriptions[tab],syms;
            .log.info[("Subscription for table [%s] already present, updated target syms to [%s]"; string[tab]; string[.rte.subscriptions[tab]])]
            ];
        [
            .rte.subscriptions[tab]: syms;
            .log.info[("Added subscription for table [%s] and syms [%s]"; string[tab]; string[syms])]
            ]
        ]
    };
// Add an enrichment function
.rte.addEnrichment: {[func;tab]
    .log.trace[(".rte.addEnrichment: function [%s] and table [%s]"; string[func]; string[tab])];
    if[func in key[.rte.enrichmentDict];
        .log.warn[("Enrichment function [%s] already exists (target table [%s]), overwriting"; string[func]; string[.rte.enrichmentDict[func]])];
        ];
    .rte.enrichmentDict[func]: tab;
    .log.info[("Added enrichment function [%s] for table [%s]"; string[func]; string[tab])];
    };

// Connect to TP and subscribe to tables registered in .rte.subscriptions
// Returns 1b on success, 0b on failure
.rte.connectTP:{[]
    h:@[hopen; `$"::",first CLI_ARGS[`tpPort]; {.log.warn["Failed to connect to TP: ",x]; 0N}];
    if[null h; :0b];
    TP_H::h;
    // Subscribe to each registered table - no .u.rep wrapper since enrichment is stateless
    // Discard the initial schema/data tuple - we only want live updates
    {[t;s] TP_H (`.u.sub; t; s)} ' [key[.rte.subscriptions];value[.rte.subscriptions]];
    .log.info[("Connected to TP at port [%s] and subscribed to [%s]";
        first CLI_ARGS[`tpPort]; ", " sv string key .rte.subscriptions)];
    1b
    };

// Retry TP connection with exponential backoff + jitter
// Mirrors .rdb.connectTPWithRetry (r.q) / .fh.connectTPWithRetry (fh.q)
.rte.connectTPWithRetry:{[maxRetries]
    i:0;
    connected:0b;
    while[(i < maxRetries) and not connected;
        connected:.rte.connectTP[];
        if[not connected;
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("TP connect attempt %d/%d failed, retrying in %s ms";i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
        ];
        i+:1;
    ];
    connected
    };

// Publish to TP helper - to be used in enrichment functions to publish results
.rte.pub: {[t;x]
    if[null TP_H; .log.warn["Cannot publish enriched rows - TP_H is null"]];
    nrows:$[98h=type x; count x; count first x];
    .[{[t;x;nrows]
        neg[TP_H] (`.u.upd; t; value flip x); neg[TP_H][];
        .log.debug[("[FLOW RTE] pub -> TP | table=%s rows=%d"; string t; nrows)];
      }; (t;x;nrows); {.log.error["Publish to TP failed: ",x]}];
    };

// Always load schemas locally - gives us `cols <table>` for column reordering in
// enrichment functions.
{system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x}[getenv[`SCHEMA_DIR]];

// Load enrichment file
// Enrichment file will define enrichment functions:
// sampleEnrich: {[x] //do some enrichment to x; .rte.publish[enrichedTableName;enrichedData]};
// Register the enrichment function and subscriptions for target table:
// .rte.addEnrichment[`sampleEnrich;`targetTable];
// .rte.addSubscription[`targetTable;`];
.log.info[("Loading enrichment file [%s]"; first CLI_ARGS[`enrichFile])];
if[any first[CLI_ARGS[`enrichFile]]~/:(();"");
    .log.fatal["No enrichment file provided, exiting"];
    exit 1;
    ];
system "l ",first CLI_ARGS[`enrichFile];

if[0=count .rte.subscriptions;
    .log.warn["No subscriptions registered - RTE will idle"];
    ];

if[0=count .rte.enrichmentDict;
    .log.warn["No enrichment functions registered - RTE will idle"];
    ];

// Initial connect. If TP not yet available, timer will reconnect when it comes up.
if[not .rte.connectTPWithRetry[10];
    .log.warn["TP not available on startup - timer will retry"];
    ];

// ── upd handler: called by TP on publish ────────────────────────────────
// Runs enrichment functions registered for table against incoming data for that table
// Enrichment function handles publishing results (using .rte.pub function)
// Target table of publish must exist in schema
upd:{[t;x]
    .log.debug[("[FLOW RTE] upd received | table=%s rows=%d"; string t; $[98h=type x; count x; count first x])];
    if[not t in value[.rte.enrichmentDict];
        .log.warn[("No enrichment function registered for table [%s]"; string t)];
        :()
        ];
    enrichmentFuncs: where .rte.enrichmentDict = t; /lookup enrichment functions for table
    .log.debug[("Enrichment functions for table [%s]: [%s]"; string[t]; ", " sv string enrichmentFuncs)];
    {[f;t;x]
        .log.debug[("Running enrichment function [%s] for table [%s]"; string f; string t)];
        @[value[f];  x; {[f;t;e] .log.error[("Enrichment function [%s] failed for table [%s]: %s"; string f; string t; e)]}[f;t;]]
        }[;t;x] each enrichmentFuncs;
    };

// ── EOD handler ─────────────────────────────────────────────────────────
// RTE has no persistence, so .u.end is a no-op beyond logging
.u.end:{[d] .log.info[("RTE received .u.end for date %s"; string d)]};

// ── Reconnection ────────────────────────────────────────────────────────
.timer.funcs[`rteReconnectTP]:{[]
    if[null TP_H;
        .log.info["Attempting TP reconnect"];
        .rte.connectTP[];
    ];
    };

// GC timer - keep memory returned to heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// ── Disconnect hook ─────────────────────────────────────────────────────
/ToDo: why not attempt reconnect here?
.z.pc:{[h]
    if[h~TP_H;
        .log.warn["Lost connection to TP"];
        TP_H::0N;
    ];
    };

// Set timer for reconnection and logging checks (60s)
system"t 60000";

.log.info[("RTE successfully initialised on port [%s]"; `long$first system"p")];
