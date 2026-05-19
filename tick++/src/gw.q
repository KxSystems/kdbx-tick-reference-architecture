// tick++/src/gw.q - Gateway Process (q-IPC + REST)
//
// q tick++/src/gw.q -p $GW_PORT -rdbPort $CHAINED_RDB_PORT -idbPort $IDB_PORT \
//                   -hdbPort $HDB_PORT -analyticsDir $ANALYTIC_DIR -procName GW
//
// Routes queries from q-IPC and REST clients across three tiers:
//   • `rdb`  — chained RDB (most recent in-memory data, not yet flushed)
//   • `idb`  — intraday DB (today's flushed int-partitions, in memory from disk)
//   • `hdb`  — historical DB (post-EOD on-disk partitions)
//   • `all`  — RDB + IDB + HDB (fan-out across all three tiers)
//
// Note that `-rdbPort` targets the chained RDB (`chainedrdb.q`), not the writedown-role
// main RDB — the main RDB never serves queries.
//
// Analytics files under `-analyticsDir` define REST endpoints whose handlers call
// `.restgw.query` (aliased to `.kxgw.query`) to issue queries through the gateway.

system"l tick++/utils/main.q";

.log.info["Initializing GW"];

.log.info[enlist["Connecting to DB processes [CHAINED_RDB port: %s] [IDB port: %s] [HDB port: %s]"],
    (CLI_ARGS[`rdbPort]; CLI_ARGS[`idbPort]; CLI_ARGS[`hdbPort])];

// @desc DB connection registry — one row per `(handle; proc; alive)` triple
CONNECTIONS:([handle:`int$()];proc:`$();alive:`boolean$());

// @desc Attempt to connect to each port in `ports`, registering successes in CONNECTIONS
// Failures log a warning and are skipped; nothing is fatal so the GW can start ahead of DB processes.
//
// @param label   {string}    Label prefix for the entry's `proc` symbol (e.g. "RDB_", "IDB_", "HDB_")
// @param ports   {string[]}  List of port strings to try in order
.kxgw.tryConnect:{[label;ports]
    {[label;i;port]
        h:@[hopen; `$"::",port; {0N}];
        if[null h;
            .log.warn[("Cannot connect to ",label,(string i)," on port ",port," - will retry on timer")];
            :()
        ];
        `CONNECTIONS upsert (h; `$label,string i; 1b);
     }[label] ./: flip (1+til count ports; ports);
    };

.kxgw.tryConnect["RDB_"; CLI_ARGS[`rdbPort]];
.kxgw.tryConnect["IDB_"; CLI_ARGS[`idbPort]];
.kxgw.tryConnect["HDB_"; CLI_ARGS[`hdbPort]];

// @desc Mark the closed handle as not alive in CONNECTIONS
//
// @param x       {int}       Handle that just closed
.z.pc:{
    .log.warn[("Lost connection to DB process:\t %r"; CONNECTIONS[x])];
    CONNECTIONS[x;`alive]:0b;
    };

// @desc Return a random handle of an alive RDB (chained) connection, or 0N if none alive
//
// @return        {int}       Live RDB handle, or null
.kxgw.getRDB:{first exec 1?handle from CONNECTIONS where alive, proc like "RDB_*"};

// @desc Return a random handle of an alive IDB connection, or 0N if none alive
//
// @return        {int}       Live IDB handle, or null
.kxgw.getIDB:{first exec 1?handle from CONNECTIONS where alive, proc like "IDB_*"};

// @desc Return a random handle of an alive HDB connection, or 0N if none alive
//
// @return        {int}       Live HDB handle, or null
.kxgw.getHDB:{first exec 1?handle from CONNECTIONS where alive, proc like "HDB_*"};

// @desc Query dispatch entry point — routes opaque `query` to the chosen target(s)
// `target` selects which database is queried; `query` may be a string, parse-tree, or
// (for `all`) a 3-element list of (rdbQuery; idbQuery; hdbQuery). All errors are caught
// and returned as ``error`msg!(...; ...)`` dictionaries rather than thrown.
//
// @param target  {symbol}    `` `rdb`` | `` `idb`` | `` `hdb`` | `` `all`` (rdb + idb + hdb)
// @param query   {*}         String / parse-tree / 3-list (`all` only)
//
// @return        {*}         Query result, or `` `error`msg!`` dictionary on failure
.kxgw.query:{[target;query]
    $[target=`rdb;
        [h:.kxgw.getRDB[];
         if[null h; :`error`msg!("No available RDB";"")];
         @[h; query; {`error`msg!("RDB query failed";x)}]
        ];
      target=`idb;
        [h:.kxgw.getIDB[];
         if[null h; :`error`msg!("No available IDB";"")];
         @[h; query; {`error`msg!("IDB query failed";x)}]
        ];
      target=`hdb;
        [h:.kxgw.getHDB[];
         if[null h; :`error`msg!("No available HDB";"")];
         @[h; query; {`error`msg!("HDB query failed";x)}]
        ];
      target=`all;
        [rh:.kxgw.getRDB[]; ih:.kxgw.getIDB[]; hh:.kxgw.getHDB[];
         if[null rh; :`error`msg!("No available RDB";"")];
         if[null ih; :`error`msg!("No available IDB";"")];
         if[null hh; :`error`msg!("No available HDB";"")];
         rq:$[0h=type query; query 0; query];
         iq:$[0h=type query; query 1; query];
         hq:$[0h=type query; query 2; query];
         rr:@[rh; rq; {`error`msg!("RDB query failed";x)}];
         ir:@[ih; iq; {`error`msg!("IDB query failed";x)}];
         hr:@[hh; hq; {`error`msg!("HDB query failed";x)}];
         `rdb`idb`hdb!(rr;ir;hr)
        ];
      [`error`msg!("Unknown target: ",string[target];"")]
    ]
    };

// @desc Alias used by REST analytics handlers — identical to `.kxgw.query`
.restgw.query:.kxgw.query;

// REST server bootstrap — initialize kx.rest and load every analytic from `-analyticsDir`
.log.info["Initializing REST server"];
.rest:use`kx.rest;
.rest.init enlist[`autoBind]!enlist[1b];

{[x]
    .log.info["Loading analytics from ",x];
    system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x;
    .log.info[("Successfully loaded analytics:\t %s";`#f)];
    }[first CLI_ARGS[`analyticsDir]];

.log.info["Registering endpoints:\t",.j.j value 1_.endpoints[;`endpoint]];
.rest.register ./: value value each 1_.endpoints;

// @desc Periodic garbage collection — keeps memory returned to the heap
.timer.funcs[`gc]:{[] .Q.gc[]};

system"t 60000";

.log.info[("GW successfully initialized on port [%s]"; `long$first system"p")];
