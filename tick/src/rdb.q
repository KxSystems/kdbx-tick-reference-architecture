// tick/tick/rdb.q - Realtime Database Process
//
// q tick/tick/rdb.q -p $RDB_PORT -tpPort $TICK_PORT -hdbPort $HDB_PORT \
//                   -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -procName RDB
//
// Subscribes to the Tickerplant (with exponential-backoff retry), holds today's
// data in memory, and writes it down to the HDB partition on `.u.end[date]`.
// If the TP is unreachable after all retries, schemas are loaded from $SCHEMA_DIR
// so the process stays alive (empty tables) and reconnects on a 60s timer.

if[not "w"=first string .z.o;system "sleep 1"];

system"l tick/utils/main.q";

.log.info["Initialising RDB"];

// @desc Standard kdb-tick subscriber upd hook — append rows into the matching root table
// Emits a `[FLOW RDB] upd received` debug line per call so the publish path is traceable.
//
// @param t       {symbol}    Target table name
// @param x       {table|*}   Rows to insert
upd:{[t;x]
    .log.debug[("[FLOW RDB] upd received | table=%s rows=%d";
        string t; $[98h=type x;count x;count first x])];
    t insert x;
    };

// @desc TP and HDB endpoints — ports come in bare; we prepend "::" for TCP loopback
.u.x:("::",first CLI_ARGS[`tpPort];"::",first CLI_ARGS[`hdbPort]);

// @desc EOD procedure — save in-memory tables to disk, clear them, signal HDB to reload
// Calls `.Q.hdpf` to splay each `g#sym` table under the HDB partition for date `x`,
// then re-applies the `g#` attribute on the now-empty in-memory tables.
//
// @param x       {date}      Partition date to write under
.u.end:{
    .log.info["Running .u.end"];
    .log.info["Running EOD Save"];
    t:tables`.;t@:where `g=attr each t@\:`sym;
    .Q.hdpf[`$.u.x 1;`:.;x;`sym];
    @[;`sym;`g#] each t;
    };

// @desc Replay the TP log into root tables, then `cd` into the HDB dir for save-down
// Re-applies each insert via `.[;();:;]`, replays the disk log via `-11!`, and changes directory.
//
// @param x       {list}      List of (table; ()::; rows) tuples to splay back into the namespace
// @param y       {list}      (logcount; logfile) — replay -11!y messages then cd to the HDB dir
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",first CLI_ARGS[`hdbDir]};

// @desc Tickerplant handle — null until `.rdb.connectTP[]` succeeds; cleared by `.z.pc` on disconnect
TP_H:0N;

// @desc Connect to TP, subscribe to every table, and replay the TP log
// Returns 1b on success, 0b on failure (handle could not be opened).
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
// Handles TCP backlog exhaustion when many processes start simultaneously.
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

.log.info[("RDB successfully initialised on port [%s] HDB location [%s]";`long$first system"p";first system"pwd")];
