// scaled-tick++/src/rdb.q - Realtime Database
//
// Subscribes to the Tickerplant (with exponential-backoff retry) and holds today's
// data in memory. The single process serves two roles distinguished by `MAIN_FLAG`:
//     leader (MAIN_FLAG=1b)   — dedicated to writedown. Every `-flushIntvMin` minutes it
//                               flushes rows older than the cutoff to int-partitions under
//                               <IDB_DIR>/today/<i>/, drops them from memory, and signals the
//                               IDB to reload. At EOD it merges those int-partitions into the
//                               HDB date partition and reloads every HDB. It does NOT serve
//                               `rdb`-tier queries (the gateway routes those to followers)
//     follower (MAIN_FLAG=0b) — full-data read replica. Serves `rdb`-tier queries via the
//                               gateway and clears its tables on EOD without writing down
//
// All RDBs are configured for writedown (idb endpoint, staging dir, flush interval) because
// any follower may be promoted to leader by `.u.failoverRDB` (tick.q) — the flush is gated on
// `MAIN_FLAG`, so a promoted follower begins writing down automatically. The next int-partition
// index is derived from the staging dir, so a promoted leader continues the prior sequence
// rather than clobbering existing partitions
//
// If the TP is unreachable after all retries, schemas are loaded from $SCHEMA_DIR
// so the process stays alive (empty tables) and reconnects on a 60s timer
//
// q scaled-tick++/src/rdb.q -p $RDB_PORT       -tpPort $TICK_PORT -hdbPort $HDB_PORTS \
//                     -idbPort $IDB_PORT -idbDir $IDB_DIR -flushIntvMin $FLUSH_INTV_MIN \
//                     -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -procName RDB
// q scaled-tick++/src/rdb.q -p $RDB_CHAIN_PORT -tpPort $TICK_PORT -hdbPort $HDB_PORTS \
//                     -idbPort $IDB_PORT -idbDir $IDB_DIR -flushIntvMin $FLUSH_INTV_MIN \
//                     -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -procName RDB_CHAIN_<N>

if[not "w"=first string .z.o;system "sleep 1"];

system"l scaled-tick++/utils/main.q";

.log.info["Initializing RDB"];

// @desc Writedown role flag — true when `-procName` is exactly "RDB" (the leader)
// Followers (`RDB_CHAIN_*`) carry data but do not write down at EOD; the TP failover
// hook (`.u.failoverRDB` in tick.q) flips this flag on a promoted follower.
MAIN_FLAG:"RDB"~first CLI_ARGS[`procName];

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

// @desc TP endpoint + HDB port list — ports come in bare; we prepend "::" for TCP loopback
// `.u.x[0]` is the TP target; `.u.x[1]` is the primary HDB port. The full `-hdbPort` list is
// walked by `.u.end` to reload every HDB after the leader writes the new date partition.
.u.x:("::",first CLI_ARGS[`tpPort];"::",first CLI_ARGS[`hdbPort]);

// @desc IDB endpoint (hsym) — target for post-flush `.idb.reload[]` signals
.rdb.idb:hsym `$":",first CLI_ARGS[`idbPort];

// @desc HDB root dir (hsym) — sym enumeration domain when writing int-partitions / date partition
.rdb.hdb:hsym `$first CLI_ARGS[`hdbDir];

// @desc Staging directory (hsym) — root of <idbDir>/today/<i>/<table>/
.rdb.tmp:` sv (hsym `$first CLI_ARGS[`idbDir]),`today;

// @desc Flush interval in minutes — drives `.rdb.flush` cadence (floored at 1)
.rdb.flushIntv:1|"J"$first CLI_ARGS[`flushIntvMin];

// @desc Timestamp of the last completed flush — gates the flush cadence on the 60s timer
.rdb.lastFlush:.z.P;

// @desc Read a splayed table off disk if its directory exists, else return an empty list
//
// @param x       {hsym}      Filesystem handle pointing at a splayed table directory
//
// @return        {table|()}  The table on disk, or empty list when the path is missing
.rdb.get:{$[count key x;select from get x;()]};

// @desc Fire-and-forget IPC to the IDB to reload its int-partitions
// Logs (and continues) on any failure rather than throwing — the IDB may be down,
// restarting, or not yet up at startup; the next flush will retry.
.rdb.sigIDB:{[]
    @[{neg[hopen x]".idb.reload[]"}; .rdb.idb; {.log.warn["IDB signal failed: ",x]}]
    };

// @desc Periodic intraday flush (leader only) — move rows older than cutoff to disk
// Picks the next int-partition index from the staging dir so a promoted leader continues the
// prior sequence rather than overwriting it. Each non-empty `g#sym` root table is enumerated
// against the shared HDB sym domain, written to <staging>/<i>/<table>/, then dropped from memory.
// After flushing, signals the IDB to reload.
.rdb.flush:{[]
    cutoff:"n"$.z.P - .rdb.flushIntv * 0D00:01;
    idx:count key .rdb.tmp;
    flushed:0b;
    {[cutoff;idx;t]
        v:value t;
        n:sum v[`time]<cutoff;
        if[not n;:()];
        (` sv .rdb.tmp,`$string idx,t,`) set .Q.en[.rdb.hdb] @[;`sym;`g#] 0!n#v;
        @[`.;t;n _];
        @[t;`sym;`g#];
        flushed::1b
        }[cutoff;idx] each tables[`.] where 0<count each value each tables`.;
    if[flushed;
        .rdb.sigIDB[];
        .log.info[("Intraday flush complete | int-partition=%d | cutoff=%s"; idx; string cutoff)]
        ];
    .rdb.lastFlush::.z.P;
    };

// @desc EOD procedure — leader merges int-partitions into the HDB date partition; followers clear
// Branches on `MAIN_FLAG`. The leader:
//   1. Flushes any remaining in-memory rows as the final int-partition
//   2. Merges every int-partition under <IDB_DIR>/today/ into a sorted `p#sym` date partition
//      under <HDB_DIR>/<date>/, then clears the staging dir
//   3. Sends `system "l ."` to every HDB port and signals the IDB to clear
// Followers simply clear in-memory tables (preserving `g#sym`); durability is the leader's job.
//
// @param x       {date}      Partition date to write under
.u.end:{
    .log.info["Running .u.end"];
    t:tables`.;t@:where `g=attr each t@\:`sym;
    $[MAIN_FLAG;
        [
            .log.info["Running EOD writedown (final flush + int-partition merge)"];
            // Flush remaining in-memory rows as the final int-partition
            idx:count key .rdb.tmp;
            {[idx;tbl] if[count v:value tbl;
                (` sv .rdb.tmp,`$string idx,tbl,`) set .Q.en[.rdb.hdb] @[;`sym;`g#] 0!v]
                }[idx] each t;
            @[`.;t;0#];
            // Merge all int-partitions -> sorted date partition under the HDB
            if[count parts:asc key .rdb.tmp;
                dest:` sv .rdb.hdb,`$string x;
                {[parts;dest;tbl]
                    d:`sym xasc raze .rdb.get each {` sv .rdb.tmp,x,y,`}[;tbl] each parts;
                    if[count d; (` sv dest,tbl,`) set @[d;`sym;`p#]]
                    }[parts;dest] each t;
                system"rm -rf ",1_string .rdb.tmp
                ];
            .rdb.lastFlush::.z.P;
            // Reload every HDB (all share <HDB_DIR>), then signal the IDB to clear
            @[;"system \"l .\"";{x}] each `$"::",/:CLI_ARGS[`hdbPort];
            .rdb.sigIDB[];
            @[;`sym;`g#] each t;
            .log.info["EOD complete — int-partitions merged into HDB date partition"]
        ];
        @[`.;t;@[;`sym;`g#]0#]
    ];
    };

// @desc Replay the TP log into root tables, then `cd` into the HDB dir for save-down
// Re-applies each insert via `.[;();:;]`, replays the disk log via `-11!`, and changes directory.
//
// @param x       {list}      List of (table; ()::; rows) tuples to splay back into the namespace
// @param y       {list}      (logcount; logfile) — replay -11!y messages then cd to the HDB dir
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",first CLI_ARGS[`hdbDir]};

// @desc Tickerplant handle — null until `.rdb.connectTP[]` succeeds; cleared by `.z.pc` on disconnect
TP_H:0N;

// @desc Connect to TP, register self in `.u.RDB_CONNECTIONS`, subscribe, replay log
// Sends a function to TP that upserts `(handle; procName; alive; leader)` into the
// connection registry (leader = true iff procName is exactly "RDB"), then returns the
// standard `(subs; logInfo)` tuple consumed by `.u.rep`.
//
// @return        {boolean}   1b on success, 0b if the TP was unreachable
.rdb.connectTP:{[]
    h:@[hopen; `$.u.x 0; {.log.warn["Failed to connect to TP: ",x]; 0N}];
    if[null h; :0b];
    TP_H::h;
    .u.rep . {[h;pn]
        h ({`.u.RDB_CONNECTIONS upsert (.z.w;`$x;1b;"RDB"~x);
            ((.u.sub[;`] each .u.t); `.u `i`L)}; pn)
    }[h; first CLI_ARGS[`procName]];
    .log.info[("Connected to TP at port [%s]";2_.u.x[0])];
    1b
    };

// @desc Open a TP connection with exponential backoff + jitter
// Handles TCP backlog exhaustion when many RDB / RDB_CHAIN processes start simultaneously.
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

// @desc Intraday flush timer (leader only) — runs `.rdb.flush` once per flush interval
// Gated on `MAIN_FLAG` so only the leader writes down, and on elapsed time so the flush
// cadence stays at `-flushIntvMin` while the housekeeping timer keeps its faster 60s tick.
.timer.funcs[`rdbFlush]:{[]
    if[MAIN_FLAG and .z.P > .rdb.lastFlush + .rdb.flushIntv * 0D00:01;
        .rdb.flush[]
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

// @desc Evaluate a GW-dispatched query and async-respond with the result
// Called from the GW via (neg h)(`.gw.evalAndRespond; reqID; tier; query)
// Errors are caught and returned as (`error`msg!``) so the callback path never crashes the DB
//
// @param reqID   {guid}      Request id originally assigned by the GW
// @param tier    {symbol}    `rdb, `hdb, or `idb — caller's tier label
// @param query   {*}         Query payload — string / parse-tree / projection
.gw.evalAndRespond:{[reqID;tier;query]
    res:@[value; query; {`error`msg!("Query failed";x)}];
    (neg .z.w) (`.kxgw.callback; reqID; tier; res)
    };

// @desc Evaluate incoming async messages — required for TP upd calls and GW dispatches
.z.ps:{value x};

// 60s housekeeping timer (reconnect, log rollover, etc.)
system"t 60000";

.log.info[("RDB successfully initialized on port [%s] HDB location [%s]";`long$first system"p";first system"pwd")];
