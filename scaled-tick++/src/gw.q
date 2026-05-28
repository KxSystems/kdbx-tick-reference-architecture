// scaled-tick++/src/gw.q - Gateway Process (q-IPC, deferred sync)
//
// Pure q-IPC entry point. Both direct q-IPC clients (`.kxgw.query`) and REST_GW
// processes (which delegate HTTP requests here over q-IPC) converge on this single
// deferred pipeline. Per request the GW:
//   1. assigns a guid `reqID` and records `(clientHandle; ts; target)` in REQUESTS,
//   2. async-dispatches to the chosen DB replica(s) via `(`.gw.evalAndRespond; reqID; tier; query)`,
//   3. calls `-30!(::)` to defer the client's sync response,
//   4. resumes the response from `.z.ps → .kxgw.callback` when the DB calls back.
//
// Routes across four tiers:
//   • `rdb`  — chained RDB followers (full in-memory). Leader excluded (it sheds).
//   • `idb`  — single intraday DB.
//   • `hdb`  — historical DB(s).
//   • `all`  — rdb + idb + hdb fan-out, aggregated into `rdb`idb`hdb!(...) dict.
//
// Failover-aware: the writedown leader is identified by polling each RDB's
// `MAIN_FLAG`. Polling runs on a 2s timer + on `.z.pc`, NOT per query — synchronous
// polling inside the deferred path would re-block the GW it is meant to unblock
//
// q scaled-tick++/src/gw.q -p $GW_PORT -rdbPort $RDB_PORT [-crdbPort $RDB_CHAIN_PORTS] \
//                    -idbPort $IDB_PORT -hdbPort $HDB_PORTS -reqTimeout $REQ_TIMEOUT \
//                    -procName GW

system"l scaled-tick++/utils/main.q";

.log.info["Initializing GW"];

// @desc Combined RDB port list — leader RDB + every chained `-crdbPort` value
RDB_PORTS:CLI_ARGS[`rdbPort],$[()~CLI_ARGS[`crdbPort]; (); CLI_ARGS[`crdbPort]];

.log.info[enlist["Connecting to DB processes [RDB port(s): %s] [IDB port: %s] [HDB port(s): %s]"],
    (RDB_PORTS; CLI_ARGS[`idbPort]; CLI_ARGS[`hdbPort])];

// @desc DB connection registry — one row per `(handle; proc; alive; leader)` tuple
// `leader` only applies to RDB rows; it is refreshed from each RDB's `MAIN_FLAG` so
// the writedown leader can be excluded from the rdb query pool
// IDB / HDB rows keep `leader=0b`
CONNECTIONS:([handle:`long$()];proc:`$();alive:`boolean$();leader:`boolean$());

// @desc Inflight request tracker; one row per deferred sync client
REQUESTS:([reqID:`guid$()];clientHandle:`long$();ts:`timestamp$();target:`$());

// @desc Per-reqID partial results for `all` fan-out
PENDING_ALL:(`guid$())!();

// @desc Request timeout — clients receive a tagged timeout error if a callback never arrives
// Default 60s; override via `-reqTimeout <timespan>`
REQ_TIMEOUT:0D00:01:00^`timespan$1e9*"J"$first CLI_ARGS[`reqTimeout];
.log.info[("Request timeout set to [%s]"; string REQ_TIMEOUT)];

// @desc Attempt to connect to each port in `ports`, registering successes in CONNECTIONS
// Failures log a warning and are skipped; nothing is fatal so the GW can start ahead of DBs
//
// @param label   {string}    Label prefix for the entry's `proc` symbol (e.g. "RDB_")
// @param ports   {string[]}  List of port strings to try in order
.kxgw.tryConnect:{[label;ports]
    {[label;i;port]
        h:@[hopen; `$"::",port; {0N}];
        if[null h;
            .log.warn[("Cannot connect to ",label,(string i)," on port ",port," - will retry on timer")];
            :()
        ];
        `CONNECTIONS upsert (h; `$label,string i; 1b; 0b);
     }[label] ./: flip (1+til count ports; ports);
    };

.kxgw.tryConnect["RDB_"; RDB_PORTS];
.kxgw.tryConnect["IDB_"; CLI_ARGS[`idbPort]];
.kxgw.tryConnect["HDB_"; CLI_ARGS[`hdbPort]];

// @desc Refresh the leader flag for every alive RDB by polling its `MAIN_FLAG`
// Runs on a 2s timer + on .z.pc, never inline in .kxgw.query
.kxgw.refreshLeaders:{[]
    {[h] CONNECTIONS[h;`leader]:@[h; "MAIN_FLAG"; {[e] 0b}]} each
        exec handle from CONNECTIONS where alive, proc like "RDB_*";
    };
.kxgw.refreshLeaders[];

// @desc Return a random handle of an alive *follower* RDB, or null if none alive.
// Reads cached `leader` flags — no IPC.
//
// @return        {int}       Live follower-RDB handle, or null
.kxgw.getRDB:{first exec 1?handle from CONNECTIONS where alive, not leader, proc like "RDB_*"};

// @desc Return a random handle of an alive IDB connection, or null if none alive.
//
// @return        {int}       Live IDB handle, or null
.kxgw.getIDB:{first exec 1?handle from CONNECTIONS where alive, proc like "IDB_*"};

// @desc Return a random handle of an alive HDB connection, or null if none alive.
//
// @return        {int}       Live HDB handle, or null
.kxgw.getHDB:{first exec 1?handle from CONNECTIONS where alive, proc like "HDB_*"};

// @desc Async-dispatch a query to a DB and flush the socket
// Sends (`.gw.evalAndRespond; reqID; tier; query) — the DB evaluates and calls back to .kxgw.callback
//
// @param reqID   {guid}      Request id assigned by the GW
// @param tier    {symbol}    `rdb, `hdb, or `idb — passed through callback so the GW can route fan-out results
// @param dbH     {long}      Open handle to the target DB
// @param query   {*}         Query payload — string / parse-tree / projection
.kxgw.dispatch:{[reqID;tier;dbH;query]
    neg[dbH] (`.gw.evalAndRespond; reqID; tier; query);
    neg[dbH][];
    };

// @desc Query dispatch entry point — deferred sync via `-30!`
// Records the request, async-dispatches to the chosen DB(s), and calls `-30!(::)` to defer
//
// @param target  {symbol}    `rdb, `hdb, `idb, or `all
// @param query   {*}         String / parse-tree / 3-list (`all` only)
//
// @return        {*}         Sync error dict on unavailability; otherwise deferred (resumed via `.kxgw.callback`)
.kxgw.query:{[target;query]
    if[not target in `rdb`idb`hdb`all; :`error`msg!("Unknown target: ",string target; "")];
    // Resolve required handle(s) up front — fail with a sync error dict if any are down
    rdbH:$[target in `rdb`all; .kxgw.getRDB[]; 0Ni];
    idbH:$[target in `idb`all; .kxgw.getIDB[]; 0Ni];
    hdbH:$[target in `hdb`all; .kxgw.getHDB[]; 0Ni];
    if[(target in `rdb`all) and null rdbH; :`error`msg!("No available RDB"; "")];
    if[(target in `idb`all) and null idbH; :`error`msg!("No available IDB"; "")];
    if[(target in `hdb`all) and null hdbH; :`error`msg!("No available HDB"; "")];

    reqID:first -1?0Ng;
    `REQUESTS upsert (reqID; .z.w; .z.P; target);
    .log.debug[("Received query reqID=%s target=%s from client=%s";
        string reqID; string target; string .z.w)];

    if[target=`rdb; .kxgw.dispatch[reqID;`rdb;rdbH;query]];
    if[target=`idb; .kxgw.dispatch[reqID;`idb;idbH;query]];
    if[target=`hdb; .kxgw.dispatch[reqID;`hdb;hdbH;query]];
    if[target=`all;
        PENDING_ALL[reqID]:()!();
        rq:$[0h=type query; query 0; query];
        iq:$[0h=type query; query 1; query];
        hq:$[0h=type query; query 2; query];
        .kxgw.dispatch[reqID;`rdb;rdbH;rq];
        .kxgw.dispatch[reqID;`idb;idbH;iq];
        .kxgw.dispatch[reqID;`hdb;hdbH;hq]
        ];

    // Deferred sync response so GW stays unblocked
    -30!(::)
    };

// @desc Resume the deferred response for a completed single-target request, or
// hand off to the fan-out collector if the request was for `all`
// Called async from each DB after .gw.evalAndRespond evaluates the query
//
// @param rid     {guid}      Request id originally assigned by `.kxgw.query`
// @param tier    {symbol}    Source tier (`` `rdb`` | `` `idb`` | `` `hdb``)
// @param result  {*}         Query result (or `` `error`msg! `` dict on DB-side eval failure)
.kxgw.callback:{[rid;tier;result]
    req:REQUESTS[rid];
    if[null req`clientHandle;
        .log.debug[("Callback for unknown/expired reqID=%s tier=%s — discarding";
            string rid; string tier)];
        :()
    ];
    if[req`target = `all;
        .kxgw.collectAll[rid; tier; result];
        :()
    ];
    @[-30!; (req`clientHandle; 0b; result); {.log.warn["Failed to resume deferred response: ",x]}];
    REQUESTS::REQUESTS _ rid;
    };

// @desc Accumulate per-tier results for an `all` fan-out request
//
// @param rid     {guid}      Request id
// @param tier    {symbol}    Source tier
// @param result  {*}         Per-tier result
.kxgw.collectAll:{[rid;tier;result]
    PENDING_ALL[rid]:(PENDING_ALL[rid]),(enlist tier)!enlist result;
    if[3=count PENDING_ALL[rid];
        full:`rdb`idb`hdb#PENDING_ALL[rid];
        PENDING_ALL::rid _ PENDING_ALL;
        clientH:REQUESTS[rid;`clientHandle];
        @[-30!; (clientH; 0b; full); {.log.warn["Failed to resume deferred response: ",x]}];
        REQUESTS::REQUESTS _ rid
        ];
    };

// @desc Connection disconnect hook
// Marks dead RDB/IDB/HDB rows, refreshes leader flags (a dead RDB may have been the leader),
// and clears any inflight REQUESTS rows belonging to a disconnected client
//
// @param h       {int}       Handle that just closed
.z.pc:{[h]
    if[h in exec handle from CONNECTIONS;
        .log.warn[("Lost connection to DB process: %r"; CONNECTIONS[h])];
        CONNECTIONS[h;`alive]:0b;
        .kxgw.refreshLeaders[]
    ];
    stale:exec reqID from REQUESTS where clientHandle=h;
    if[count stale;
        .log.warn[("Client ",string[h]," disconnected with ",string[count stale]," inflight request(s)")];
        REQUESTS::delete from REQUESTS where reqID in stale;
        PENDING_ALL::stale _ PENDING_ALL
    ];
    };

// @desc Periodic refresh of cached leader flags. Bounded failover-detection window.
.timer.funcs[`gwLeaderRefresh]:{[] .kxgw.refreshLeaders[]};

// @desc Periodic sweep for requests older than `REQ_TIMEOUT`. Sends a tagged
// timeout signal to each stale client and removes the rows
.timer.funcs[`gwTimeout]:{[]
    cutoff:.z.P - REQ_TIMEOUT;
    stale:select from REQUESTS where ts < cutoff;
    if[count stale;
        .log.warn[("Timing out ",string[count stale]," stale request(s) (> ",string[REQ_TIMEOUT],")")];
        {@[-30!; (x`clientHandle; 1b; "TIMEOUT: Request timed out");
            {.log.warn["Failed to send timeout to client: ",x]}]} each value stale;
        staleIDs:exec reqID from stale;
        REQUESTS::delete from REQUESTS where reqID in staleIDs;
        PENDING_ALL::staleIDs _ PENDING_ALL
        ];
    };

// @desc Async message handler — required to receive callback dispatches from DBs
.z.ps:{value x};

// @desc Periodic garbage collection — keeps memory returned to the heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// 2s timer drives leader refresh, timeout sweep, and gc.
system"t 2000";

.log.info[("GW successfully initialized on port [%s]"; `long$first system"p")];
