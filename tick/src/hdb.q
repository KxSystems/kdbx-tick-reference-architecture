// tick/src/hdb.q - Historical Database Process
//
// Loads the on-disk partitioned database from `-hdbDir` and serves queries from the gateway.
// Exposes `.hdb.reload[]` so external tooling (e.g. scripts/reload-hdb.sh after a batch load)
// can refresh the in-memory view of disk without restarting the process.
//
// q tick/src/hdb.q -p $HDB_PORT -hdbDir $HDB_DIR -procName HDB

// Load utility scripts
system"l tick/utils/main.q";

.log.info["Initializing HDB"];

// Load table schemas so the HDB answers meta / queries before its first EOD partition
// exists. Loaded BEFORE mounting the db so real partitions override these empty in-memory
// tables once they are written.
{[x]
    system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
    .log.info[("Loaded schemas from files: %s"; tables[])];
    }[getenv[`SCHEMA_DIR]];

// It's the HDB: present the `date` partition column up front so meta and date-filtered
// queries (e.g. /<tbl>/hdb?d=...) match the post-EOD partitioned shape and don't error on
// a cold start. Tables that already carry a `date` column keep their own (moved to front).
{[tn] t:value tn; if[not `date in cols t; t:update date:`date$() from t]; tn set `date xcols t;} each tables`.;
@[;`sym;`g#] each tables`.;

// Mount the on-disk historical database (partitioned tables override the empty in-mem schema)
system"l ",first CLI_ARGS[`hdbDir];

// @desc Reload the HDB from disk — picks up data added outside the normal tick EOD path
// Called via IPC by reload-hdb.sh after a batch load, or directly during ad-hoc maintenance.
// Returns `` `ok`` so callers can verify success.
//
// @return        {symbol}    `` `ok`` once `system "l ."` completes
.hdb.reload:{[]
    .log.info["Reloading HDB from disk"];
    system "l .";
    .log.info[("HDB reloaded. Tables [%s] from [%s]";`#tables[];first system"pwd")];
    `ok
    };

// @desc Evaluate incoming async messages — required for receiving TP-style upd calls
.z.ps:{value x};

// One-minute housekeeping timer (used by `.timer.funcs`)
system"t 60000";

.log.info[("HDB successfully initialized. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];
