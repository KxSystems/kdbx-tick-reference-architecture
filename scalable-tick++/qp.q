// Query Processor (Worker)
// Self-registers with QR, executes queries against RDB/HDB, callbacks to GW
// Supports single target (`rdb/`hdb) and parallel fan-out (`both)
// CLI args: -p <port> -qrPort <port> -gwPort <port> -rdbPort <port(s)> -hdbPort <port(s)> -procName QP_N

system"l utils/main.q";

.log.info["Initialising QP"];

// Connect with retry + exponential backoff + jitter
// Handles TCP backlog exhaustion when many QPs start simultaneously
//  name       - human-readable name for logging
//  port       - port string to connect to
//  maxRetries - how many attempts before giving up
.qp.connectWithRetry:{[name;port;maxRetries]
    i:0;
    h:0N;
    while[(i < maxRetries) and null h;
        h:@[hopen; `$"::",port; {.log.warn[x]; 0N}];
        if[null h;
            // Exponential backoff with jitter: 100ms, 200ms, 400ms, ... + random 0-100ms
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("%s connect attempt %d/%d failed, retrying in %s ms";name;i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
        ];
        i+:1;
    ];
    if[null h;
        .log.fatal[("Failed to connect to %s after %d attempts — exiting";name;maxRetries)];
        exit 1;
    ];
    h
 };

// DB connections - same pattern as original gw.q
DB_CONNECTIONS:([handle:`int$()] proc:`$(); alive:`boolean$());

{[str;ports]
    c:count ports;
    handles:{.qp.connectWithRetry[x;y;10]}'["DB_",/:string 1+til c; ports];
    `DB_CONNECTIONS upsert handles,'(`$str,/:string 1+til c),'c#1b;
 }./:(enlist"RDB_";enlist"HDB_"),'enlist each (CLI_ARGS[`rdbPort];CLI_ARGS[`hdbPort]);

.log.info[("Connected to DB processes: %r";select proc, alive from DB_CONNECTIONS)];

// Connect to QR and register. Payload includes the paired RDB/HDB ports so
// QR can hand them back to the GW for REST routing (.qr.pickFreeWorker).
.qp.regCfg:{[]
    `port`procName`rdbPort`hdbPort!(
        `long$first system"p";
        `$first CLI_ARGS[`procName];
        "J"$first CLI_ARGS[`rdbPort];
        "J"$first CLI_ARGS[`hdbPort])
 };

QR_H:.qp.connectWithRetry["QR"; first CLI_ARGS[`qrPort]; 10];
neg[QR_H] (`.qr.register; .qp.regCfg[]);

.log.info[("Registered with QR on port [%s]";first CLI_ARGS[`qrPort])];

// Connect to GW on startup for callbacks
GW_H:.qp.connectWithRetry["GW"; first CLI_ARGS[`gwPort]; 10];

.log.info[("Connected to GW on port [%s]";first CLI_ARGS[`gwPort])];

// Get DB handle by target type
.qp.getDB:{[target]
    pattern:$[target=`rdb;"RDB_*";"HDB_*"];
    first exec 1?handle from DB_CONNECTIONS where alive, proc like pattern
 };

// Pending fan-out trackers — separate flat global dicts (avoid nested assignment type issues)
.qp.pendingRdb:()!();    // reqID -> rdb result
.qp.pendingHdb:()!();    // reqID -> hdb result

// Execute query - called async by QR
//  reqID  - guid from GW
//  query  - for `rdb/`hdb: single query (string, projection, or lambda)
//           for `both: two-element list (rdbQuery; hdbQuery)
//  target - `rdb, `hdb, or `both
.qp.execute:{[reqID;query;target]
    .log.info[("Executing reqID [%s] on [%s]";string reqID;string target)];
    $[target=`both;
        .qp.execBoth[reqID;query];
        .qp.execSingle[reqID;query;target]
    ];
 };

// Single target - sync IPC to one DB
.qp.execSingle:{[reqID;query;target]
    dbH:.qp.getDB[target];
    res:$[null dbH;
        `error`msg!("No alive DB connection for target";"target: ",string target);
        @[{x y}[dbH]; query; {`error`msg!("Query execution failed";x)}]
    ];
    .qp.sendResult[reqID;res];
 };

// Both targets - parallel async fan-out to RDB and HDB
// Calls .db.execAsync on each DB, which sends results back via .qp.collectResult
//  query must be a two-element list: (rdbQuery; hdbQuery)
//  Returns `rdb`hdb!(rdbResult; hdbResult) — client handles aggregation
.qp.execBoth:{[reqID;query]
    rdbH:.qp.getDB[`rdb];
    hdbH:.qp.getDB[`hdb];
    // Fail immediately if either DB is down
    if[(null rdbH) or null hdbH;
        src:$[null rdbH;"RDB";"HDB"];
        .qp.sendResult[reqID; `error`msg!("DB not available for fan-out";src," connection is down")];
        :()
    ];
    // Validate query is a pair
    if[2 <> count query;
        .qp.sendResult[reqID; `error`msg!("Invalid query for `both target";"Expected (rdbQuery; hdbQuery)")];
        :()
    ];
    // Dispatch async to both DBs in parallel. Each DB calls back .qp.collectResult
    // GW's REQ_TIMEOUT handles hang cases if a DB never responds
    neg[rdbH] (`.db.execAsync; reqID; `rdb; query 0); neg[rdbH][];
    neg[hdbH] (`.db.execAsync; reqID; `hdb; query 1); neg[hdbH][];
 };

// Collect a result from fan-out - called async by RDB or HDB
//  src - `rdb or `hdb identifying which source returned
.qp.collectResult:{[reqID;src;result]
    // Store result
    $[src=`rdb; .qp.pendingRdb[reqID]:result; .qp.pendingHdb[reqID]:result];
    // Check if both results have arrived
    if[(reqID in key .qp.pendingRdb) and reqID in key .qp.pendingHdb;
        rdbRes:.qp.pendingRdb[reqID];
        hdbRes:.qp.pendingHdb[reqID];
        .qp.pendingRdb _: reqID;
        .qp.pendingHdb _: reqID;
        // Determine if either result is an error dict
        rdbErr:$[99h=type rdbRes; `error in key rdbRes; 0b];
        hdbErr:$[99h=type hdbRes; `error in key hdbRes; 0b];
        if[rdbErr or hdbErr;
            .qp.sendResult[reqID; $[rdbErr; rdbRes; hdbRes]];
            :()
        ];
        .qp.sendResult[reqID; `rdb`hdb!(rdbRes; hdbRes)];
    ];
 };

// Common result sender - callbacks to GW and notifies QR
.qp.sendResult:{[reqID;res]
    neg[GW_H] (`.kxgw.callback; reqID; res);
    neg[QR_H] (`.qr.complete; reqID);
    neg[QR_H][];
    .log.info[("Completed reqID [%s]";string reqID)];
 };

// Liveness
.z.pc:{[h]
    if[h~QR_H;
        .log.warn["Lost connection to QR"];
        QR_H::0N;
    ];
    if[h~GW_H;
        .log.warn["Lost connection to GW"];
        GW_H::0N;
    ];
    if[h in exec handle from DB_CONNECTIONS;
        .log.warn[("Lost connection to DB: %r";DB_CONNECTIONS[h])];
        DB_CONNECTIONS[h;`alive]:0b;
    ];
 };

// Reconnection timer - attempt to re-establish lost handles
.timer.funcs[`qpReconnect]:{[]
    // Reconnect to QR and re-register
    if[null QR_H;
        .log.info["Attempting to reconnect to QR"];
        QR_H::@[hopen; `$"::",first CLI_ARGS[`qrPort]; {.log.warn["QR reconnect failed: ",x]; 0N}];
        if[not null QR_H;
            neg[QR_H] (`.qr.register; .qp.regCfg[]);
            .log.info["Reconnected and re-registered with QR"];
        ];
    ];
    // Reconnect to GW
    if[null GW_H;
        .log.info["Attempting to reconnect to GW"];
        GW_H::@[hopen; `$"::",first CLI_ARGS[`gwPort]; {.log.warn["GW reconnect failed: ",x]; 0N}];
        if[not null GW_H; .log.info["Reconnected to GW"]];
    ];
    // Reconnect dead DB processes
    dead:select handle, proc from DB_CONNECTIONS where not alive;
    if[count dead;
        .log.info[("Attempting to reconnect to %d dead DB process(es)";count dead)];
        {[row]
            // Derive port from original proc name pattern
            newH:@[hopen; `$"::",string row`handle; {0N}];
            if[not null newH;
                // Remove old entry, insert new
                delete from `DB_CONNECTIONS where handle=row`handle;
                `DB_CONNECTIONS upsert (newH; row`proc; 1b);
                .log.info[("Reconnected to DB: %s";string row`proc)];
            ];
        } each value dead;
    ];
 };

// Async message handler - ensure incoming async messages are evaluated
.z.ps:{value x};

// Periodic GC to return memory to heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// Set timer for logging checks and reconnection
system"t 60000";

.log.info[("QP successfully initialised on port [%s]";`long$first system"p")];
