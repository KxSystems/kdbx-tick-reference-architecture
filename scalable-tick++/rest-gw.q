// REST Gateway
// Thin HTTP → q-IPC adapter. N instances share the same HTTP port via Linux
// SO_REUSEPORT socket sharding (kdb `rp` listen mode). The kernel distributes
// incoming HTTP connections across all REST_GW processes.
//
// Flow: HTTP client → kx.rest → endpoint qFunc → GW_H (`.kxgw.query; ...)
//       GW uses -30! deferred sync like any q IPC client. When the QP
//       callback resumes the deferred response, REST_GW's sync IPC call
//       unblocks and returns the result to kx.rest which serialises to JSON.
//
// All queuing, backpressure, timeout, and cancellation semantics are
// inherited from the GW's normal q-IPC query path — no duplication here.
//
// CLI args: -p rp,<port> -gwPort <port> -analyticsDir <dir> -procName REST_GW_N

system"l utils/main.q";

.log.info["Initialising REST_GW"];

// Connect to GW with retry + exponential backoff + jitter
// Handles TCP backlog exhaustion when multiple REST_GWs start simultaneously
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
    if[null h; .log.fatal["Failed to connect to GW after ",string[maxRetries]," attempts — exiting"]; exit 1];
    h
 };
GW_H:.restgw.connectGWWithRetry[10];

.log.info[("Connected to GW on port [%s]";first CLI_ARGS[`gwPort])];

// ── Delegation helper ─────────────────────────────────────────────────────
// Called by endpoint qFuncs. Sends the query to GW via sync q-IPC and returns
// the result (or re-raises an error for kx.rest to convert to HTTP 500).
// Because GW uses -30! deferred sync, we block here until the full GW → QR →
// QP round-trip completes — no busy-wait, no polling.
// Reason → HTTP-error tag. Lets REST clients distinguish BUSY (retryable) from
// TIMEOUT / UNAVAIL (transient) and from opaque query failures.
.restgw.tag:{[reason]
    // Reason is usually already a string (from `error`msg! dicts or caught
    // signals). Only stringify symbols via `string`; anything else goes
    // through `.Q.s1` as a last-resort. Avoid `.Q.s1` on strings — it wraps
    // them in quotes and breaks the starts-with `like` patterns below.
    r:$[10h=abs type reason; reason;
        -11h=type reason;   string reason;
                            .Q.s1 reason];
    $[r like "Server busy*";        "BUSY: ",r;
      r like "*timed out*";          "TIMEOUT: ",r;
      r like "No available QP*";     "UNAVAIL: ",r;
      r like "*cancelled*";          "CANCEL: ",r;
      r like "QR not connected*";    "UNAVAIL: ",r;
                                     "QUERY: ",r]
 };

.restgw.query:{[target;query]
    if[(null GW_H) or GW_H=0i;
        .log.warn["REST call but GW not connected"];
        '"UNAVAIL: gateway not connected"
    ];
    // Handler catches thrown signals (e.g. "Request timed out" / "Request cancelled"
    // delivered via GW's -30!(...;1b;...)) and reshapes them to the same `error`msg!
    // dict shape the QR returns, so the tag logic below sees a single contract.
    res:@[GW_H; (`.kxgw.query; target; query); {[e] `error`msg!(e;"")}];
    // GW/QR return `error`msg!(reason; detail). Re-raise as a tagged signal so
    // kx.rest returns HTTP 500 with `details` carrying the tag+reason.
    if[99h=type res;
        if[`error in key res;
            .log.warn[("REST query failed: error=%s msg=%s";.Q.s1 res`error;.Q.s1 res`msg)];
            '.restgw.tag[res`error]
        ];
    ];
    :res
 };

// ── Connection management ────────────────────────────────────────────────

.restgw.pc:{[h]
    if[h~GW_H;
        .log.warn["Lost connection to GW"];
        GW_H::0N;
    ];
 };
.z.pc:.restgw.pc;

// Reconnection timer - attempt to re-establish lost GW handle
.timer.funcs[`restgwReconnect]:{[]
    if[null GW_H;
        .log.info["Attempting to reconnect to GW"];
        GW_H::@[hopen; `$"::",first CLI_ARGS[`gwPort]; {.log.warn["GW reconnect failed: ",x]; 0N}];
        if[not null GW_H; .log.info["Reconnected to GW"]];
    ];
 };

// ── REST server ──────────────────────────────────────────────────────────
.log.info["Initialising REST server"];
.rest:use`kx.rest;
.rest.init enlist[`autoBind]!enlist[1b];

// Load analytics — endpoint handlers call .restgw.query to delegate to GW
{[x]
    .log.info["Loading analytics from ",x];
    system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x;
    .log.info[("Successfully loaded analytics:\t %s";`#f)];
 }[first CLI_ARGS[`analyticsDir]];

.log.info["Registering endpoints:\t",.j.j value 1_.endpoints[;`endpoint]];
.rest.register ./: value value each 1_.endpoints;

// Re-set .z.ts and .z.pc after kx.rest (module overrides both)
.z.ts:{value[.timer.funcs]@\:(::)};
.z.pc:.restgw.pc;

// Periodic GC to return memory to heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// Timer tick — 1s for reactive reconnection to GW if it drops
system"t 1000";

.log.info[("REST_GW successfully initialised on port [%s]";`long$first system"p")];
