// tick++/src/chainedrdb.q - Chained Realtime Database (Query Role)
//
// q tick++/src/chainedrdb.q -p $CHAINED_RDB_PORT -tpPort $TICK_PORT \
//                          -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -procName CHAINED_RDB
//
// Subscribes to the Tickerplant in parallel with the main RDB and holds today's data
// in memory. All RDB-tier queries from the gateway hit this process instead of the
// main RDB, so the main RDB is free to perform intraday writedowns without contending
// for the q event loop. Owns no disk I/O — `.u.end[date]` simply clears in-memory
// tables (the main RDB is responsible for durability).

if[not "w"=first string .z.o;system "sleep 1"];

system"l tick++/utils/main.q";

.log.info["Initialising CHAINED_RDB (query role)"];

// @desc Standard kdb-tick subscriber upd hook — append rows into the matching root table
// Emits a `[FLOW CHAINED_RDB] upd received` debug line per call so the publish path is traceable.
//
// @param t       {symbol}    Target table name
// @param x       {table|*}   Rows to insert
upd:{[t;x]
    .log.debug[("[FLOW CHAINED_RDB] upd received | table=%s rows=%d";
        string t; $[98h=type x;count x;count first x])];
    t insert x;
    };

// @desc TP endpoint — bare port from CLI, prepended with "::" for TCP loopback
// Wrapped as a single-element list so `.u.x 0` stays uniform with the main RDB shape.
.u.x:enlist "::",first CLI_ARGS[`tpPort];

// @desc EOD procedure — clear in-memory tables only; writedown is owned by the main RDB
// Discovers `g#sym` tables at root, empties them, and re-applies the `g#` attribute.
//
// @param x       {date}      EOD date (kept for kdb-tick signature; unused here)
.u.end:{
    .log.info["Running .u.end (clear memory only — writedown is owned by main RDB)"];
    t:tables`.;
    t@:where `g=attr each t@\:`sym;
    @[`.;t;0#];
    @[;`sym;`g#] each t;
    };

// @desc Replay the TP log into root tables, then `cd` into the HDB dir
// Re-applies each insert via `.[;();:;]`, replays the disk log via `-11!`, and changes directory.
//
// @param x       {list}      List of (table; ()::; rows) tuples to splay back into the namespace
// @param y       {list}      (logcount; logfile) — replay -11!y messages then cd to the HDB dir
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",first CLI_ARGS[`hdbDir]};

// @desc Tickerplant handle — null until `.rdb.connectTP[]` succeeds; cleared by `.z.pc` on disconnect
TP_H:0N;

// @desc Connect to TP, subscribe to every table, replay the TP log
//
// @return        {boolean}   1b on success, 0b if the TP was unreachable
.rdb.connectTP:{[]
    h:@[hopen; `$.u.x 0; {.log.warn["Failed to connect to TP: ",x]; 0N}];
    if[null h; :0b];
    TP_H::h;
    .u.rep . h ({((.u.sub[;`] each .u.t); `.u `i`L)};::);
    .log.info[("Connected to TP at port [%s]";2_.u.x[0])];
    1b
    };

// @desc Open a TP connection with exponential backoff + jitter
//
// @param maxRetries  {long}      Maximum number of connection attempts
//
// @return            {boolean}   1b if any attempt succeeded, 0b after exhausting retries
.rdb.connectTPWithRetry:{[maxRetries]
    i:0;
    connected:0b;
    while[(i < maxRetries) and not connected;
        connected:.rdb.connectTP[];
        if[not connected;
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("TP connect attempt %d/%d failed, retrying in %s ms";i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
        ];
        i+:1;
    ];
    connected
    };

// Initial TP connect — if unreachable after retries, load schemas from $SCHEMA_DIR so
// the process stays alive with empty tables and the reconnect timer can catch up later.
if[not .rdb.connectTPWithRetry[10];
    .log.warn["TP not available — loading schemas from files"];
    {[x]
        system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
        .log.info[("Loaded schemas from files: %s"; tables[])];
    }[getenv[`SCHEMA_DIR]];
    system "cd ",first CLI_ARGS[`hdbDir]
    ];

// @desc Reconnection timer — re-establishes the TP subscription when `TP_H` is null
.timer.funcs[`rdbReconnectTP]:{[]
    if[null TP_H;
        .rdb.connectTP[];
    ];
    };

// @desc Connection disconnect hook — clears `TP_H` when the tracked TP handle closes
//
// @param h       {int}       Handle that just closed
.z.pc:{[h]
    if[h~TP_H;
        .log.warn["Lost connection to TP"];
        TP_H::0N;
    ];
    };

// @desc Evaluate incoming async messages — required for receiving TP upd calls
.z.ps:{value x};

// 60s housekeeping timer (reconnect, log rollover, etc.)
system"t 60000";

.log.info[("CHAINED_RDB (query) initialised on port [%s] HDB location [%s]";`long$first system"p";first system"pwd")];
