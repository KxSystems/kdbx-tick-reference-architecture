// scaled-tick++/src/hdb.q - Historical Database
//
// Loads the on-disk partitioned database from `-hdbDir` and serves queries from the gateway.
// Started in two flavours: the base HDB (always) and one HDB_EXTRA_<N> per chained RDB_CHAIN_<N>
// when the stack is launched with `-m N`.
// Exposes `.hdb.reload[]` so external tooling (e.g. scripts/reload-hdb.sh after a batch load)
// can refresh the in-memory view of disk without restarting the process
//
// q scaled-tick++/src/hdb.q -p $HDB_PORT -hdbDir $HDB_DIR -procName HDB
// q scaled-tick++/src/hdb.q -p $HDB_EXTRA_PORT -hdbDir $HDB_DIR -procName HDB_EXTRA_<N>

// Load utility scripts
system"l scaled-tick++/utils/main.q";

.log.info["Initializing HDB"];

// Mount the on-disk historical database
system"l ",first CLI_ARGS[`hdbDir];

// @desc Reload the HDB from disk — picks up data added outside the normal tick EOD path
// Called via IPC by reload-hdb.sh after a batch load, or directly during ad-hoc maintenance
// Returns `` `ok`` so callers can verify success
//
// @return        {symbol}    `` `ok`` once `system "l ."` completes
.hdb.reload:{[]
    .log.info["Reloading HDB from disk"];
    system "l .";
    .log.info[("HDB reloaded. Tables [%s] from [%s]";`#tables[];first system"pwd")];
    `ok
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

// @desc Evaluate incoming async messages — required for receiving GW dispatches + TP-style upd calls
.z.ps:{value x};

// One-minute housekeeping timer (used by `.timer.funcs`)
system"t 60000";

.log.info[("HDB successfully initialized. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];
