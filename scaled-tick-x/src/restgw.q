// scaled-tick-x/src/restgw.q - REST Gateway
//
// Thin HTTP --> q-IPC adapter. N instances share the same HTTP port via Linux SO_REUSEPORT
// socket sharding. The kernel distributes incoming connections across processes
//
// Flow: HTTP client --> kx.rest --> registered endpoint qFunc --> .restgw.query
//       --> sync IPC to GW --> GW defers via `-30!` --> REST_GW's sync send blocks
//       until the GW resumes the deferred response --> kx.rest serialises to JSON
//
// All queuing, backpressure, timeout, and failover semantics are inherited from
// the GW's deferred-sync path — REST_GW carries no policy of its own
//
// q scaled-tick-x/src/restgw.q -p rp,$REST_PORT -gwPort $GW_PORT \
//                          -analyticsDir $ANALYTIC_DIR -procName REST_GW_<N>

system"l scaled-tick-x/utils/main.q";

.log.info["Initializing REST_GW"];

// @desc Connect to the GW with exponential-backoff retry + jitter. Handles TCP
// backlog exhaustion when REST_GW and GW are started back-to-back by the launcher.
//
// @param maxRetries  {long}    Maximum number of connection attempts before fatal
//
// @return            {int}     Open IPC handle to the GW
.restgw.connectGWWithRetry:{[maxRetries]
    i:0;
    h:0N;
    while[(i < maxRetries) and null h;
        h:@[hopen; `$"::",first CLI_ARGS[`gwPort]; {.log.warn[x]; 0N}];
        if[null h;
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("GW connect attempt %d/%d failed, retrying in %s ms";i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
            ];
        i+:1;
        ];
    if[null h;
        .log.fatal["Failed to connect to GW after ",string[maxRetries]," attempts — exiting"];
        exit 1
        ];
    h
    };

GW_H:.restgw.connectGWWithRetry[10];
.log.info[("Connected to GW on port [%s]"; first CLI_ARGS[`gwPort])];

// @desc Map an error string from .kxgw.query `error`msg!`` dict to an
// HTTP-friendly tag prefix
//
// @param reason  {*}         Error reason (usually a string)
//
// @return        {string}    "TIMEOUT: ..." | "UNAVAIL: ..." | "QUERY: ..."
.restgw.tag:{[reason]
    r:$[10h=abs type reason; reason;
        -11h=type reason;   string reason;
                            .Q.s1 reason];
    $[r like "*timed out*";          "TIMEOUT: ",r;
      r like "No available *";       "UNAVAIL: ",r;
      r like "*cancelled*";          "CANCEL: ",r;
      r like "GW *";                 "UNAVAIL: ",r;
                                     "QUERY: ",r]
    };

// @desc REST analytic entry point; called by endpoint APIs
// Issues a sync q-IPC call to the GW (uses `-30!` deferred sync)
//
// @param target  {symbol}    `rdb, `hdb, `idb, or `all
// @param query   {*}         String / parse-tree / 3-list (`all` only)
//
// @return        {*}         Query result (table / dict / atom)
.restgw.query:{[target;query]
    if[(null GW_H) or GW_H=0i;
        .log.warn["REST call but GW not connected"];
        '"UNAVAIL: gateway not connected"
    ];
    // Handler catches any throws (e.g. -30!(...;1b;reason) timeouts from the GW)
    // and reshapes them to the same `error`msg! dict the GW returns on no-available tiers
    res:@[GW_H; (`.kxgw.query; target; query); {[e] `error`msg!(e;"")}];
    if[99h=type res;
        if[`error in key res;
            .log.warn[("REST query failed: error=%s msg=%s"; .Q.s1 res`error; .Q.s1 res`msg)];
            '.restgw.tag[res`error]
            ];
        ];
    :res
    };

// @desc Connection disconnect hook
// Clears GW_H when the tracked GW handle closes
//
// @param h       {int}       Handle that just closed
.restgw.pc:{[h]
    if[h~GW_H;
        .log.warn["Lost connection to GW"];
        GW_H::0N
        ];
    };
.z.pc:.restgw.pc;

// @desc Reconnection timer
// Re-establishes the GW handle on each timer tick if null
.timer.funcs[`restgwReconnect]:{[]
    if[null GW_H;
        .log.info["Attempting to reconnect to GW"];
        GW_H::@[hopen; `$"::",first CLI_ARGS[`gwPort]; {.log.warn["GW reconnect failed: ",x]; 0N}];
        if[not null GW_H; .log.info["Reconnected to GW"]]
        ];
    };

// REST server bootstrap — initialize kx.rest and load every analytic from `-analyticsDir`
.log.info["Initializing REST server"];
.rest:use`kx.rest;
.rest.init enlist[`autoBind]!enlist[1b];

{[x]
    .log.info["Loading analytics from ",x];
    system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x;
    .log.info[("Successfully loaded analytics:\t %s";`#f)];
    }[first CLI_ARGS[`analyticsDir]];

.log.info["Registering endpoints:\t",.j.j value 1_.endpoints[;`endpoint]];
.rest.register ./: value value each 1_.endpoints;

// kx.rest overrides `.z.ts` and `.z.pc` during init — re-bind ours so the timer
// fires our `.timer.funcs` and disconnects trigger our reconnect path
.z.ts:{value[.timer.funcs]@\:(::)};
.z.pc:.restgw.pc;

// @desc Periodic garbage collection — keeps memory returned to the heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// 1s timer — reactive reconnection to GW
system"t 1000";

.log.info[("REST_GW successfully initialized on port [%s]"; `long$first system"p")];
