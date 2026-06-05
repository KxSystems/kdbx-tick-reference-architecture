// scaled-tick-x/src/idb.q - Intraday Database (single instance)
//
// Loads flushed int-partitions from <IDB_DIR>/today/<i>/<table>/ into memory and serves
// queries on them. Whichever RDB currently holds the writedown role (`MAIN_FLAG=1b` — the
// leader) owns the staging dir: it writes int-partitions there on every periodic flush and
// calls `.idb.reload[]` over IPC after each flush. At EOD the leader merges the staging dir
// into the HDB date partition and clears it; a subsequent reload yields an empty in-memory
// view (the data is now in the HDB). There is exactly one IDB for the whole system — it is
// not replicated with the chained RDBs
//
// q scaled-tick-x/src/idb.q -p $IDB_PORT -hdbDir $HDB_DIR -idbDir $IDB_DIR -procName IDB

system"l scaled-tick-x/utils/main.q";

.log.info["Initializing IDB"];

// @desc Staging directory (hsym) — root of <idbDir>/today/<i>/<table>/
.idb.dir:` sv (hsym `$first CLI_ARGS[`idbDir]),`today;

// @desc HDB root path (string) — used for sym enumeration on reload
.idb.hdb:first CLI_ARGS[`hdbDir];

.log.info["IDB staging dir = ",string .idb.dir];
.log.info["IDB hdb root    = ",.idb.hdb];

// Load schemas locally so the in-memory tables exist (with `g#sym`) even before the
// first reload. `.idb.reload` discovers tables to repopulate by their `g#sym` attribute.
{[x]
    system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
    .log.info[("Loaded schemas from files: %s"; tables[])];
    }[getenv[`SCHEMA_DIR]];

// Change directory to HDB root and load the sym vector for enumeration resolution.
// On a fresh install the sym file doesn't exist yet — the first reload triggered by
// the leader's first flush will populate it.
system"cd ",.idb.hdb;
@[{`sym set get`:sym};`;{.log.info["IDB: sym file not loaded (will load on first reload)"]}];

// @desc Read a splayed table off disk if its directory exists, else return an empty list
//
// @param x       {hsym}      Filesystem handle pointing at a splayed table directory
//
// @return        {table|()}  The table on disk, or empty list when the path is missing
.idb.get:{$[count key x;select from get x;()]};

// @desc Refresh sym domain, clear root tables, and reload all today/<i>/ int-partitions into memory
// Triggered by the leader RDB over IPC after each intraday flush and at EOD. Discovers tables
// by `g#sym` attribute and razes int-partition slices into each.
.idb.reload:{[]
    @[{`sym set get`:sym};`;{}];
    t:tables`.;
    t@:where `g=attr each t@\:`sym;
    @[`.;t;0#];
    parts:asc key .idb.dir;
    if[not count parts;
        @[;`sym;`g#] each t;
        .log.info["IDB reload: empty (no int-partitions in staging)"];
        :()
        ];
    {[parts;tbl]
        d:raze .idb.get each {` sv .idb.dir,x,y,`}[;tbl] each parts;
        if[count d; tbl set @[d;`sym;`g#]]
        }[parts] each t;
    .log.info["IDB reload: loaded ",string[count parts]," int-partitions"];
    };

// Initial load on startup in case the leader has already flushed before the IDB came up.
.idb.reload[];

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

// @desc Evaluate incoming async messages — required for `.idb.reload` signals and GW dispatches
.z.ps:{value x};

// One-minute housekeeping timer (used by `.timer.funcs`)
system"t 60000";

.log.info[("IDB successfully initialized on port [%s]"; `long$first system"p")];
