// tick++/src/rte.q - Real-Time Engine (Enrichment Process)
//
// q tick++/src/rte.q -p $RTE_PORT -tpPort $TICK_PORT [-enrichFile <path>] -procName RTE
//
// Single instance, lives in the realtime module alongside the RDB. Starts with no
// enrichments registered — the registration API below is the extension point.
//
// To add a custom enrichment:
//   1. Define a global function `myEnrich:{[data] ...; .rte.pub[`derivedTable; derived]};`
//   2. Register it:  `.rte.addEnrichment[`myEnrich; `sourceTable]`
//   3. Subscribe RTE to the source table on the TP:  `.rte.addSubscription[`sourceTable; `]`
// Bundle steps 1–3 into a `.q` file and pass it via the optional `-enrichFile` argument
// to load at startup (see the "Example Enrichment File" block in tick/README.md), or call
// the registration helpers directly over IPC.
//
//   Flow: FH → TP → (.rte.subscriptions) → RTE → (.rte.enrichmentDict) → (.rte.pub) → TP → RDB

system"l tick++/utils/main.q";

.log.info["Initialising RTE"];

// @desc Tickerplant handle — null until `.rte.connectTP[]` succeeds; cleared by `.z.pc` on disconnect
TP_H:0N;

// @desc Enrichment function -> target table registry — populated by `.rte.addEnrichment`
.rte.enrichmentDict: ()!();

// @desc Table -> sym-filter registry — populated by `.rte.addSubscription`
.rte.subscriptions: ()!();

// @desc Register / extend a TP subscription for `tab`
// Rejects non-symbol `syms`. If a subscription for `tab` already exists, merges `syms`
// into the existing filter (distinct union); otherwise creates a new entry. If the RTE
// is already connected to the TP, the new subscription is also sent immediately.
//
// @param tab     {symbol}    Table name to subscribe to
// @param syms    {symbol[]}  Sym filter (`` for all)
.rte.addSubscription:{[tab;syms]
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
        ];
    if[not null TP_H; TP_H (`.u.sub; tab; syms)];
    };

// @desc Register an enrichment function for `tab`
// If a function with the same name is already registered, it is overwritten (with a warn log).
//
// @param func    {symbol}    Name of the global enrichment function
// @param tab     {symbol}    Source table — the function is invoked when this table publishes
.rte.addEnrichment:{[func;tab]
    .log.trace[(".rte.addEnrichment: function [%s] and table [%s]"; string[func]; string[tab])];
    if[func in key[.rte.enrichmentDict];
        .log.warn[("Enrichment function [%s] already exists (target table [%s]), overwriting"; string[func]; string[.rte.enrichmentDict[func]])];
        ];
    .rte.enrichmentDict[func]: tab;
    .log.info[("Added enrichment function [%s] for table [%s]"; string[func]; string[tab])];
    };

// @desc Connect to TP and subscribe to every table registered in `.rte.subscriptions`
// No `.u.rep` wrapper — enrichment is stateless so the initial snapshot is discarded;
// we only want live updates.
//
// @return        {boolean}   1b on success, 0b if the TP was unreachable
.rte.connectTP:{[]
    h:@[hopen; `$"::",first CLI_ARGS[`tpPort]; {.log.warn["Failed to connect to TP: ",x]; 0N}];
    if[null h; :0b];
    TP_H::h;
    {[t;s] TP_H (`.u.sub; t; s)} ' [key[.rte.subscriptions];value[.rte.subscriptions]];
    .log.info[("Connected to TP at port [%s] and subscribed to [%s]";
        first CLI_ARGS[`tpPort]; ", " sv string key .rte.subscriptions)];
    1b
    };

// @desc Open a TP connection with exponential backoff + jitter
// Mirrors `.rdb.connectTPWithRetry` and `.fh.connectTPWithRetry`.
//
// @param maxRetries  {long}      Maximum number of connection attempts
//
// @return            {boolean}   1b if any attempt succeeded, 0b after exhausting retries
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

// @desc Publish enriched rows back to TP — called from inside enrichment functions
// Sends `(`.u.upd; t; <columns>)` asynchronously and emits a `[FLOW RTE] pub -> TP` debug line.
// Logs (and continues) on any failure rather than throwing.
//
// @param t       {symbol}    Target table on the TP
// @param x       {table}     Rows to publish (must match the target table schema)
.rte.pub:{[t;x]
    if[null TP_H; .log.warn["Cannot publish enriched rows - TP_H is null"]];
    nrows:$[98h=type x; count x; count first x];
    .[{[t;x;nrows]
        neg[TP_H] (`.u.upd; t; value flip x); neg[TP_H][];
        .log.debug[("[FLOW RTE] pub -> TP | table=%s rows=%d"; string t; nrows)];
      }; (t;x;nrows); {.log.error["Publish to TP failed: ",x]}];
    };

// Optional enrichment file — if `-enrichFile` is supplied, load it now so the file
// can call `.rte.addEnrichment` / `.rte.addSubscription` before TP connect happens.
// Nothing is loaded by default; the RTE starts idle and waits for IPC-driven registration.
if[(`enrichFile in key CLI_ARGS) and not any first[CLI_ARGS[`enrichFile]]~/:(();"");
    enrichPath:first CLI_ARGS[`enrichFile];
    .log.info[("Loading enrichment file [%s]";enrichPath)];
    system "l ",enrichPath
    ];

// Initial TP connect. If TP is not yet available, timer will reconnect when it comes up.
// With no subscriptions registered this is just an idle handle; subsequent
// `.rte.addSubscription` calls will both register locally and forward to the live TP.
if[not .rte.connectTPWithRetry[10];
    .log.warn["TP not available on startup - timer will retry"];
    ];

if[0=count .rte.enrichmentDict;
    .log.info["RTE started with no enrichments registered — use .rte.addEnrichment / .rte.addSubscription to extend"];
    ];

// @desc upd handler called by TP on publish
// Looks up enrichment functions registered for `t` in `.rte.enrichmentDict` and runs each
// against `x`. Each function is responsible for calling `.rte.pub` to publish its results.
// Per-function errors are caught and logged; sibling functions still run.
//
// @param t       {symbol}    Source table name
// @param x       {table|*}   Rows just published by TP
upd:{[t;x]
    .log.debug[("[FLOW RTE] upd received | table=%s rows=%d"; string t; $[98h=type x; count x; count first x])];
    if[not t in value[.rte.enrichmentDict];
        .log.warn[("No enrichment function registered for table [%s]"; string t)];
        :()
        ];
    enrichmentFuncs: where .rte.enrichmentDict = t;
    .log.debug[("Enrichment functions for table [%s]: [%s]"; string[t]; ", " sv string enrichmentFuncs)];
    {[f;t;x]
        .log.debug[("Running enrichment function [%s] for table [%s]"; string f; string t)];
        @[value[f];  x; {[f;t;e] .log.error[("Enrichment function [%s] failed for table [%s]: %s"; string f; string t; e)]}[f;t;]]
        }[;t;x] each enrichmentFuncs;
    };

// @desc EOD handler — RTE has no persistence, so this is a no-op beyond logging
//
// @param d       {date}      EOD date forwarded from TP
.u.end:{[d] .log.info[("RTE received .u.end for date %s"; string d)]};

// @desc Reconnection timer — re-establishes the TP subscription when `TP_H` is null
.timer.funcs[`rteReconnectTP]:{[]
    if[null TP_H;
        .log.info["Attempting TP reconnect"];
        .rte.connectTP[];
    ];
    };

// @desc Periodic garbage collection — keeps memory returned to the heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// @desc Connection disconnect hook — clears `TP_H` when the tracked TP handle closes
//
// @param h       {int}       Handle that just closed
.z.pc:{[h]
    if[h~TP_H;
        .log.warn["Lost connection to TP"];
        TP_H::0N;
    ];
    };

// 60s housekeeping timer (reconnect, log rollover, etc.)
system"t 60000";

.log.info[("RTE successfully initialised on port [%s]"; `long$first system"p")];
