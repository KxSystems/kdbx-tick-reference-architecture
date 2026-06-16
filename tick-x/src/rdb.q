// tick-x/src/rdb.q - Realtime Database (Writedown Role)
//
// In tick-x/, the main RDB is dedicated to writedown. It subscribes to the TP, holds
// today's data in memory just long enough to flush periodically to disk, and at EOD
// merges those int-partitions into the HDB date partition. Query serving is offloaded
// to the chained RDB (chainedrdb.q) so this process never blocks on a query.
//
// Flush flow (every `-flushIntvMin` minutes):
//   1. cutoff := now - flushIntvMin minutes
//   2. for each `g#sym` table, write rows where time<cutoff to <IDB_DIR>/today/<i>/<table>/
//   3. drop those rows from memory
//   4. signal IDB (`-idbPort`) to reload its in-memory view
//
// EOD flow (`.u.end[date]`):
//   1. flush remaining in-memory rows as the final int-partition
//   2. merge all int-partitions under <IDB_DIR>/today/ into <HDB_DIR>/<date>/
//   3. clean up the staging dir, signal HDB + IDB to reload, reset counters
//
// q tick-x/src/rdb.q -p $RDB_PORT -tpPort $TICK_PORT -hdbPort $HDB_PORT \
//                    -idbPort $IDB_PORT -hdbDir $HDB_DIR -idbDir $IDB_DIR \
//                    -tplogDir $TPLOG_DIR -flushIntvMin $FLUSH_INTV_MIN -procName RDB

if[not "w"=first string .z.o;system "sleep 1"];

system"l tick-x/utils/main.q";

.log.info["Initializing RDB (writedown role)"];

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

// @desc TP and HDB endpoints — bare ports from CLI, prepended with "::" for TCP loopback
.u.x:("::",first CLI_ARGS[`tpPort];"::",first CLI_ARGS[`hdbPort]);

// @desc IDB endpoint — target for post-flush `.idb.reload[]` signals. Must use the "::" TCP
// form (like `.u.x`); a single colon (`:5015`) is a FILE handle, so the signal would be written
// to a junk file instead of sent to the IDB and the reload would never fire.
.rdb.idb:`$"::",first CLI_ARGS[`idbPort];

// @desc HDB root dir (hsym) — sym enumeration domain when writing int-partitions
.rdb.hdb:hsym `$first CLI_ARGS[`hdbDir];

// @desc Staging directory (hsym) — root of <idbDir>/today/<i>/<table>/
.rdb.tmp:` sv (hsym `$first CLI_ARGS[`idbDir]),`today;

// @desc Watermark file (hsym) — single timespan: "every row with time < W is persisted to the IDB".
// Lives at <idbDir>/.watermark, OUTSIDE today/, so it never inflates `count key .rdb.tmp`
// (the int-partition index) nor the IDB's `asc key today/` reload. Written atomically on each
// flush; read on (re)start to drop already-persisted rows so replay never re-flushes.
.rdb.watermarkFile:hsym `$(first CLI_ARGS[`idbDir]),"/.watermark";

// @desc Flush interval in minutes — drives `.rdb.flush` cadence (floored at 1)
.rdb.flushIntv:1|"J"$first CLI_ARGS[`flushIntvMin];

// @desc Read a splayed table off disk if its directory exists, else return an empty list
//
// @param x       {hsym}      Filesystem handle pointing at a splayed table directory
//
// @return        {table|()}  The table on disk, or empty list when the path is missing
.rdb.get:{$[count key x;select from get x;()]};

// @desc Read the persisted flush watermark, or null timespan when nothing has been flushed today
//
// @return        {timespan}  Watermark W (rows with time < W are on disk), or 0Nn
.rdb.readWatermark:{[] @[get; .rdb.watermarkFile; 0Nn]};

// @desc Atomically persist the flush watermark (temp file + rename) so a mid-write crash
// never leaves a torn value a restart/failover would misread
//
// @param w       {timespan}  New watermark to persist
.rdb.setWatermark:{[w]
    tmp:hsym `$(1_string .rdb.watermarkFile),".tmp";
    tmp set w;
    system "mv ",(1_string tmp)," ",1_string .rdb.watermarkFile;
    };

// @desc Drop rows older than `w` from every `g#sym` root table (in-memory shed, no disk write)
// Assumes time-ordered insert (drops the first n rows). Re-applies `g#sym` after the drop.
//
// @param w       {timespan}  Shed cutoff — rows where time < w are removed
.rdb.shedBelow:{[w]
    if[null w; :()];
    t:tables`.; t@:where `g=attr each t@\:`sym;
    {[w;tbl]
        n:sum (value tbl)[`time]<w;
        if[n; @[`.;tbl;n _]; @[tbl;`sym;`g#]]
        }[w] each t;
    };

// @desc Shed rows already persisted before this point — read the watermark and drop below it.
// Called post-replay on (re)start so a restarted writedown RDB never re-flushes disk-backed rows.
.rdb.applyWatermark:{[] .rdb.shedBelow .rdb.readWatermark[]};

// @desc Fire-and-forget IPC to IDB to reload its int-partitions
// Logs (and continues) on any failure rather than throwing — the IDB may be down,
// restarting, or not yet up at startup; the next flush will retry.
.rdb.sigIDB:{[]
    @[{h:hopen x; neg[h]".idb.reload[]"; neg[h][]; hclose h}; .rdb.idb; {.log.warn["IDB signal failed: ",x]}]
    };

// @desc Periodic flush — move rows older than cutoff to disk as a fresh int-partition
// Assumes time-ordered insert (n_ drops first n rows). After flushing, signals IDB.
// Each non-empty `g#sym` root table is enumerated against the shared HDB sym domain
// and written to <staging>/<i>/<table>/.
.rdb.flush:{[]
    // Cutoff is a UTC time-of-day, matching the feed's `time` column (.z.n is UTC).
    // Using `.z.P` (local) here skews the flush window by the machine's UTC offset: in
    // UTC+ zones every row reads as already-old and is shed by the watermark floor below
    // WITHOUT being persisted (silent intraday data loss); in UTC- zones nothing flushes
    // until rows age past the offset. Keep this on the same clock as the feed.
    cutoff:"n"$.z.p - .rdb.flushIntv * 0D00:01;
    // Drop anything already persisted (time < watermark) before selecting the flush slice. After a
    // restart the TP re-delivers buffered-but-already-logged rows via live `upd` — which can land
    // after the connect-time applyWatermark — so without this floor the flush would re-persist them
    // and duplicate into the IDB. Makes the flush idempotent w.r.t. the watermark.
    .rdb.shedBelow .rdb.readWatermark[];
    idx:count key .rdb.tmp;
    // Each table returns 1b if it wrote a partition; `any` aggregates into a real local so the
    // post-flush signalling below fires. (A `flushed::1b` inside the lambda would set a GLOBAL,
    // never this local — keep it a local return value.)
    flushed:any {[cutoff;idx;t]
        v:value t;
        n:sum v[`time]<cutoff;
        if[not n;:0b];
        (` sv .rdb.tmp,`$string idx,t,`) set .Q.en[.rdb.hdb] @[;`sym;`g#] 0!n#v;
        @[`.;t;n _];
        @[t;`sym;`g#];
        1b
        }[cutoff;idx] each tables[`.] where 0<count each value each tables`.;
    if[flushed;
        // Advance the watermark, reload the IDB, and tell the query RDB(s) to shed to the same
        // boundary. The shed broadcast goes via the TP so it rides the same ordered connection
        // as `upd` — the query RDB has every to-be-shed row before it sheds. The persisted
        // watermark backs restart/failover; the broadcast keeps the rdb/idb tiers disjoint live.
        .rdb.setWatermark[cutoff];
        .rdb.sigIDB[];
        if[not null TP_H; (neg TP_H)(`.u.broadcastWatermark; cutoff); (neg TP_H)[]];
        .log.info[("Intraday flush complete | int-partition=%d | cutoff=%s"; idx; string cutoff)]
        ];
    };

// @desc EOD procedure — flush remaining rows, merge int-partitions into HDB date partition,
// clean up staging, signal HDB + IDB to reload, reset counters.
// Builds the date partition by `xasc`-ing all int-partitions by sym and applying `p#sym`.
//
// @param x       {date}      Partition date to write under
.u.end:{
    .log.info["Running .u.end (final flush + EOD merge)"];
    t:tables`.;
    t@:where `g=attr each t@\:`sym;
    // Flush remaining in-memory rows as the final int-partition (next index from the staging dir)
    idx:count key .rdb.tmp;
    {[idx;tbl] if[count v:value tbl;
        (` sv .rdb.tmp,`$string idx,tbl,`) set .Q.en[.rdb.hdb] @[;`sym;`g#] 0!v]
        }[idx] each t;
    @[`.;t;0#];
    if[count parts:asc key .rdb.tmp;
        // Merge all int-partitions -> sorted date partition under HDB
        dest:` sv .rdb.hdb,`$string x;
        {[parts;dest;tbl]
            // Gather this table's rows from every int-partition. A `g#sym` table with no rows
            // in any partition yields an empty general list `()` here, and `` `sym xasc () ``
            // throws 'type — so guard on count BEFORE sorting, not after.
            raw:raze .rdb.get each {` sv .rdb.tmp,x,y,`}[;tbl] each parts;
            if[count raw; (` sv dest,tbl,`) set @[`sym xasc raw;`sym;`p#]]
            }[parts;dest] each t;
        // Clean up staging dir
        system"rm -rf ",1_string .rdb.tmp;
        ];
    // Reset the watermark — staging is gone, the new day starts unflushed
    @[{system "rm -f ",1_string .rdb.watermarkFile};(::);{[e]}];
    // Signal HDB to reload its on-disk view
    @[{neg[hopen x]".hdb.reload[]"}; `$.u.x 1; {.log.warn["HDB signal failed: ",x]}];
    // Signal IDB to clear (HDB has the data now, staging dir is gone)
    .rdb.sigIDB[];
    @[;`sym;`g#] each t;
    .log.info["EOD complete — int-partitions merged into HDB date partition"];
    };

// @desc Replay the TP log into root tables, then `cd` into the HDB dir for save-down
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
    // Replay rebuilds the whole day in memory; drop everything already persisted to the IDB
    // so the next flush only writes new rows (no re-flush / duplication after a mid-day restart).
    .rdb.applyWatermark[];
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

// @desc Periodic intraday flush — runs `.rdb.flush` on each timer tick
.timer.funcs[`rdbFlush]:{[] .rdb.flush[]};

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

// Drive both reconnect-check and intraday flush off the same timer (flushIntv minutes).
system"t ",string `long$.rdb.flushIntv * 60000;

.log.info[("RDB (writedown) initialized on port [%s] | flush every [%d] min | HDB=[%s] | staging=[%s]";
    `long$first system"p"; .rdb.flushIntv; first CLI_ARGS[`hdbDir]; string .rdb.tmp)];
