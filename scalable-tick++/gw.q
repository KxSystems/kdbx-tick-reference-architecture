// Gateway
// Pure q-IPC entry point. Tracks requests, dispatches to QR, uses -30!
// deferred sync so the GW process stays non-blocking under load.
//
// Both q-IPC clients (via `.kxgw.query`) and REST clients (via REST_GW
// processes which delegate to us over q-IPC) converge here — there is a
// single code path and a single set of back-pressure/timeout/cancellation
// semantics.
//
// CLI args: -p <port> -qrPort <port> -reqTimeout <timespan> -procName GW

system"l utils/main.q";

.log.info["Initialising GW"];

// Request tracking - maps reqID to the suspended client handle (q IPC or
// REST_GW; both hit the same code path because both speak q IPC to us).
REQUESTS:([reqID:`guid$()] clientHandle:`int$(); ts:`timestamp$(); status:`$());

// Timeout threshold for inflight requests (timespan). Default 60s, override via -reqTimeout
REQ_TIMEOUT:0D00:01:00^`timespan$1e9*"J"$first CLI_ARGS[`reqTimeout];
.log.info[("Request timeout set to [%s]";string REQ_TIMEOUT)];

// Connect to QR with retry + exponential backoff + jitter
// Handles TCP backlog exhaustion when multiple processes start simultaneously
.gw.connectQRWithRetry:{[maxRetries]
    i:0;
    h:0N;
    while[(i < maxRetries) and null h;
        h:@[hopen; `$"::",first CLI_ARGS[`qrPort]; {.log.warn[x]; 0N}];
        if[null h;
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("QR connect attempt %d/%d failed, retrying in %s ms";i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
        ];
        i+:1;
    ];
    if[null h; .log.fatal["Failed to connect to QR after ",string[maxRetries]," attempts — exiting"]; exit 1];
    h
 };
QR_H:.gw.connectQRWithRetry[10];

.log.info[("Connected to QR on port [%s]";first CLI_ARGS[`qrPort])];

// ── API LAYER ────────────────────────────────────────────────────────────
// Structured query interface with validation and sanitisation.
// Builds safe functional selects from validated parameters — prevents
// arbitrary q execution from upstream clients (e.g. MCP servers).
// Raw .kxgw.query still available for advanced/internal use.

// Schema registry: table -> dict of (col -> type char)
.api.schema:()!();
// Allowed table names
.api.tables:`$();

// Initialise from loaded schema files
.api.init:{[]
    .api.tables:except[tables[];`REQUESTS];
    .api.schema:.api.tables!{(cols x)!(value meta[x])`t} each .api.tables;
    .log.info[("API layer initialised. Tables: %s"; .api.tables)];
 };

// Load schemas for validation (same files TP loads, used here for metadata only)
{[x]
    .log.info["Loading schemas for API validation from ",x];
    system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
 }[getenv[`SCHEMA_DIR]];
.api.init[];

// ── Validation ───────────────────────────────────────────────────────────

.api.validateTable:{[tab]
    if[not tab in .api.tables; '"Unknown table: ",string tab];
 };

.api.validateTarget:{[target]
    if[not target in `rdb`hdb`both; '"Invalid target: must be `rdb, `hdb, or `both"];
 };

.api.validateFilters:{[tab;filters]
    if[count filters;
        unknown:(key filters) except key .api.schema[tab];
        if[count unknown; '"Unknown filter column(s) for ",string[tab],": "," " sv string unknown];
    ];
 };

.api.validateCols:{[tab;c]
    if[count c;
        unknown:c except key .api.schema[tab];
        if[count unknown; '"Unknown select column(s) for ",string[tab],": "," " sv string unknown];
    ];
 };

// ── Query building ───────────────────────────────────────────────────────

// Build a functional select projection from validated inputs.
// Returns a projection that QP sends to the DB for remote execution:
//   ({[t;w;g;c] ?[t;w;g;c]}; tab; whereClause; 0b; colDict)
.api.buildQuery:{[tab;filters;selCols]
    // Build where clause: list of parse tree conditions
    wc:$[0=count filters; ();
        {[col;val]
            $[(2=count val) and 0h<=type val;  // 2-element list (any type) = within
                (within; col; val);
              -11h=type val;                    // symbol atom = enlist for equality
                (=; col; enlist val);
                (=; col; val)                   // scalar equality
            ]
        } ./: flip (key filters; value filters)
    ];
    // Column dict: () = all columns, else name!name
    cd:$[count selCols; selCols!selCols; ()];
    // Projection: executed on remote DB as ?[tab; where; groupby; cols]
    ({[t;w;g;c] ?[t;w;g;c]}; tab; wc; 0b; cd)
 };

// ── Structured query entry point ─────────────────────────────────────────

// Structured query - validates inputs then dispatches via .kxgw.query.
// Params dict:
//   `table   (sym, required)      - table name (must exist in schema registry)
//   `target  (sym, required)      - `rdb `hdb `both
//   `where   (dict, optional)     - col!value filters. Single value = equality,
//                                   2-element list = within range
//   `cols    (sym list, optional) - columns to return (empty = all)
//
// Usage:
//   h (`.api.query; `table`target!(`energy;`rdb))
//   h (`.api.query; `table`target`where!(`energy;`rdb;`time`sym!((0D00:00:00;0D23:59:59);`BLOWER78_1)))
//   h (`.api.query; `table`target`cols!(`energy;`hdb;`time`consumption))
//   h (`.api.query; `table`target`where`cols!(`energy;`both;(enlist `sym)!(enlist `BLOWER78_1);`time`consumption))
.api.query:{[params]
    if[not `table in key params; '"Missing required param: table"];
    if[not `target in key params; '"Missing required param: target"];
    tab:params`table;
    target:params`target;
    .api.validateTable[tab];
    .api.validateTarget[target];
    filters:$[`where in key params; params`where; ()!()];
    selCols:$[`cols in key params; params`cols; `$()];
    .api.validateFilters[tab;filters];
    .api.validateCols[tab;selCols];
    q:.api.buildQuery[tab;filters;selCols];
    // For `both, send the same query to both targets
    if[target=`both; q:(q;q)];
    .kxgw.query[target;q]
 };

// ── q IPC client entry point ─────────────────────────────────────────────
// Deferred-sync dispatch. Used by:
//   - Direct q clients
//   - REST_GW processes delegating HTTP requests here
//  target - `rdb, `hdb, or `both
//  query  - string / projection / parse tree to evaluate on the DB
.kxgw.query:{[target;query]
    if[(null QR_H) or QR_H=0i;
        .log.warn["QR not connected"];
        :`error`msg!("QR not connected";"")
    ];
    reqID:first -1?0Ng;
    `REQUESTS upsert (reqID; .z.w; .z.P; `inflight);
    .log.info[("Received query [%s] target [%s] from client [%s]";string reqID;string target;string .z.w)];
    neg[QR_H] (`.qr.dispatch; reqID; query; target); neg[QR_H][];
    // Suspend the sync response - GW stays non-blocking
    -30!(::)
 };

// Callback from QP - resumes the suspended client response via -30!.
.kxgw.callback:{[reqID;result]
    req:REQUESTS[reqID];
    if[null req`clientHandle;
        .log.warn["Callback for unknown reqID: ",string reqID];
        :()
    ];
    .log.info[("Returning result for reqID [%s] to client [%s]";string reqID;string req`clientHandle)];
    .log.debug[("Resuming -30! with handle [%s] result type [%s]";string req`clientHandle;string type result)];
    @[-30!; (req`clientHandle; 0b; result); {.log.error["Failed to resume deferred response: ",x]}];
    ![`REQUESTS; enlist (=;`reqID;reqID); 0b; `symbol$()];
 };

// Cancel an inflight request - removes from REQUESTS and sends error to client.
// The QP will still finish its work but the callback will find "unknown reqID" and discard.
.kxgw.cancel:{[reqID]
    req:REQUESTS[reqID];
    if[null req`clientHandle; :`error`msg!("Unknown reqID";"")];
    -30!(req`clientHandle; 1b; "Request cancelled");
    ![`REQUESTS; enlist (=;`reqID;reqID); 0b; `symbol$()];
    // Notify QR to remove from queue (if still queued)
    if[not null QR_H;
        neg[QR_H] (`.qr.dequeue; enlist reqID); neg[QR_H][];
    ];
    .log.info[("Cancelled request [%s]";string reqID)];
    :`ok
 };

// ── Timeout cleanup ──────────────────────────────────────────────────────
.timer.funcs[`gwTimeout]:{[]
    stale:select from REQUESTS where status=`inflight, ts < .z.P - REQ_TIMEOUT;
    if[count stale;
        staleIDs:exec reqID from stale;
        .log.warn[("Timing out %d stale request(s)";count stale)];
        {-30!(x`clientHandle; 1b; "Request timed out")} each value stale;
        ![`REQUESTS; enlist (in;`reqID;enlist staleIDs); 0b; `symbol$()];
        // Notify QR to remove these from its queue (if still queued)
        if[not null QR_H;
            neg[QR_H] (`.qr.dequeue; staleIDs); neg[QR_H][];
        ];
    ];
 };

// ── Connection management ────────────────────────────────────────────────
.z.pc:{[h]
    if[h~QR_H;
        .log.warn["Lost connection to QR"];
        QR_H::0N;
        // Immediately fail all inflight requests — QR can't route them anymore
        inflight:select from REQUESTS where status=`inflight;
        if[count inflight;
            .log.warn[("Failing %d inflight request(s) due to QR disconnect";count inflight)];
            {-30!(x`clientHandle; 1b; "QR disconnected, request failed")} each value inflight;
            ![`REQUESTS; enlist (=;`status;`inflight); 0b; `symbol$()];
        ];
    ];
    // Clean up any inflight requests from disconnected clients (q clients or REST_GWs)
    stale:exec reqID from REQUESTS where clientHandle=h;
    if[count stale;
        .log.warn[("Client [%s] disconnected with %d inflight request(s)";string h;count stale)];
        ![`REQUESTS; enlist (in;`reqID;enlist stale); 0b; `symbol$()];
    ];
 };

// Reconnection timer - attempt to re-establish lost QR handle
.timer.funcs[`gwReconnect]:{[]
    if[null QR_H;
        .log.info["Attempting to reconnect to QR"];
        QR_H::@[hopen; `$"::",first CLI_ARGS[`qrPort]; {.log.warn["QR reconnect failed: ",x]; 0N}];
        if[not null QR_H; .log.info["Reconnected to QR"]];
    ];
 };

// Async message handler
.z.ps:{value x};

// Periodic GC to return memory to heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// Timer tick — must be < REQ_TIMEOUT for timeouts to fire promptly
system"t 10000";

.log.info[("Successfully initialised GW at port [%s]";`long$first system"p")];
