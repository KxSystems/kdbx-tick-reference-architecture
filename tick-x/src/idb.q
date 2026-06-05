// tick-x/src/idb.q - Intraday Database
//
// Loads flushed int-partitions from <IDB_DIR>/today/<i>/<table>/ into memory and serves
// queries on them. The main RDB owns the staging dir — it writes int-partitions there on
// every periodic flush and calls `.idb.reload[]` over IPC after each flush. At EOD the
// staging dir is cleared by the main RDB; a subsequent reload yields an empty in-memory
// view (the data is now in the HDB date partition)
//
// q tick-x/src/idb.q -p $IDB_PORT -hdbDir $HDB_DIR -idbDir $IDB_DIR -procName IDB

system"l tick-x/utils/main.q";

.log.info["Initializing IDB"];

// @desc Staging directory (hsym) — root of <idbDir>/today/<i>/<table>/
.idb.dir:` sv (hsym `$first CLI_ARGS[`idbDir]),`today;

// @desc HDB root path (string) — used for sym enumeration on reload
.idb.hdb:first CLI_ARGS[`hdbDir];

.log.info["IDB staging dir = ",string .idb.dir];
.log.info["IDB hdb root    = ",.idb.hdb];

// @desc Load schemas locally so the in-memory tables exist before the first reload
{[x]
    system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
    .log.info[("Loaded schemas from files: %s"; tables[])];
    }[getenv[`SCHEMA_DIR]];

// @desc Apply `g#sym` to the freshly-loaded schema tables for discovery from .idb.reload
@[;`sym;`g#] each tables`.;

// Change directory to HDB root and load the sym vector for enumeration resolution.
// On a fresh install the sym file doesn't exist yet — the first reload triggered by
// the main RDB's first flush will populate it.
system"cd ",.idb.hdb;
@[{`sym set get`:sym};`;{.log.info["IDB: sym file not loaded (will load on first reload)"]}];

// @desc Read a splayed table off disk if its directory exists, else return an empty list
//
// @param x       {hsym}      Filesystem handle pointing at a splayed table directory
//
// @return        {table|()}  The table on disk, or empty list when the path is missing
.idb.get:{$[count key x;select from get x;()]};

// @desc Refresh sym domain, clear root tables, and reload all today/<i>/ int-partitions into memory
// Triggered by the main RDB over IPC after each intraday flush and at EOD. Discovers tables
// by `g#sym` attribute and razes int-partition slices into each
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

// Initial load on startup in case the main RDB has already flushed before IDB came up
.idb.reload[];

// @desc Evaluate incoming async messages — required for receiving `.idb.reload` signals
.z.ps:{value x};

// One-minute housekeeping timer (used by `.timer.funcs`)
system"t 60000";

.log.info[("IDB successfully initialized on port [%s]"; `long$first system"p")];
