// tick/tick/gw.q - Gateway Process (q-IPC + REST)
//
// q tick/tick/gw.q -p $GW_PORT -rdbPort $RDB_PORT -hdbPort $HDB_PORT \
//                  -analyticsDir $ANALYTIC_DIR -procName GW
//
// Routes queries from q-IPC and REST clients to a single RDB and a single HDB.
// Analytics files under `-analyticsDir` define REST endpoints whose handlers call
// `.restgw.query` (aliased to `.kxgw.query`) to issue queries through the gateway.

system"l tick/utils/main.q";

.log.info["Initialising GW"];

.log.info[enlist["Connecting to DB processes [RDB port: %s] [HDB port: %s]"],
    (CLI_ARGS[`rdbPort]; CLI_ARGS[`hdbPort])];

// @desc DB connection registry — one row per `(handle; proc; alive)` triple
CONNECTIONS:([handle:`int$()];proc:`$();alive:`boolean$());

// @desc Attempt to connect to each port in `ports`, registering successes in CONNECTIONS
// Failures log a warning and are skipped; nothing is fatal so the GW can start ahead of DB processes.
//
// @param label   {string}    Label prefix for the entry's `proc` symbol (e.g. "RDB_", "HDB_")
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
.kxgw.tryConnect["HDB_"; CLI_ARGS[`hdbPort]];

// @desc Mark the closed handle as not alive in CONNECTIONS
//
// @param x       {int}       Handle that just closed
.z.pc:{
    .log.warn[("Lost connection to DB process:\t %r"; CONNECTIONS[x])];
    CONNECTIONS[x;`alive]:0b;
    };

// @desc Return a random handle of an alive RDB connection, or 0N if none alive
//
// @return        {int}       Live RDB handle, or null
.kxgw.getRDB:{first exec 1?handle from CONNECTIONS where alive, proc like "RDB_*"};

// @desc Return a random handle of an alive HDB connection, or 0N if none alive
//
// @return        {int}       Live HDB handle, or null
.kxgw.getHDB:{first exec 1?handle from CONNECTIONS where alive, proc like "HDB_*"};

// @desc Query dispatch entry point — routes opaque `query` to the chosen target(s)
// `target` selects which database is queried; `query` may be a string, parse-tree, or
// (for `both`) a 2-element list of (rdbQuery; hdbQuery). All errors are caught and
// returned as ``error`msg!(...; ...)`` dictionaries rather than thrown.
//
// @param target  {symbol}    `` `rdb`` | `` `hdb`` | `` `both``
// @param query   {*}         String / parse-tree / 2-list (`both` only)
//
// @return        {*}         Query result, or `` `error`msg!`` dictionary on failure
.kxgw.query:{[target;query]
    $[target=`rdb;
        [h:.kxgw.getRDB[];
         if[null h; :`error`msg!("No available RDB";"")];
         @[h; query; {`error`msg!("RDB query failed";x)}]
        ];
      target=`hdb;
        [h:.kxgw.getHDB[];
         if[null h; :`error`msg!("No available HDB";"")];
         @[h; query; {`error`msg!("HDB query failed";x)}]
        ];
      target=`both;
        [rh:.kxgw.getRDB[]; hh:.kxgw.getHDB[];
         if[null rh; :`error`msg!("No available RDB";"")];
         if[null hh; :`error`msg!("No available HDB";"")];
         rq:$[0h=type query; first query; query];
         hq:$[0h=type query; last  query; query];
         rr:@[rh; rq; {`error`msg!("RDB query failed";x)}];
         hr:@[hh; hq; {`error`msg!("HDB query failed";x)}];
         `rdb`hdb!(rr;hr)
        ];
      [`error`msg!("Unknown target: ",string[target];"")]
    ]
    };

// @desc Alias used by REST analytics handlers — identical to `.kxgw.query`
.restgw.query:.kxgw.query;

// REST server bootstrap — initialise kx.rest and load every analytic from `-analyticsDir`
.log.info["Initialising REST server"];
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

.log.info[("GW successfully initialised on port [%s]"; `long$first system"p")];
