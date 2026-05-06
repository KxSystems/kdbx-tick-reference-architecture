// Load utility scripts
system"l utils/main.q";

.log.info["Initialising HDB"];

// Load DB
system"l ",first CLI_ARGS[`hdbDir];

// Reload HDB from disk - can be called via IPC to pick up data changes
.hdb.reload:{[]
    .log.info["Reloading HDB from disk"];
    system "l .";
    .log.info[("HDB reloaded. Tables [%s] from [%s]";`#tables[];first system"pwd")];
    `ok
 };

// Async query executor - called by QP during fan-out (`both target)
// Evaluates the query and sends result back to caller async
//  reqID  - guid from GW (passed through)
//  src    - `rdb or `hdb tag for collectResult
//  query  - string, projection, or function to eval on this process
.db.execAsync:{[reqID;src;query]
    res:@[value; query; {`error`msg!("Query failed";x)}];
    neg[.z.w] (`.qp.collectResult; reqID; src; res); neg[.z.w][];
 };

// Async message handler - ensure incoming async messages are evaluated (needed for fan-out queries)
.z.ps:{value x};

// Set timer to run every minute for logging checks
system"t 60000";

.log.info[("HDB successfully initialised. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];