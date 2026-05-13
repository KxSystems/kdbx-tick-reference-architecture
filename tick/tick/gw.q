// Gateway — serves both REST (kx.rest) and q-IPC clients.
// Analytics files define REST endpoints; handlers call .restgw.query
// (aliased to .kxgw.query) to route queries through the gateway.
//
// CLI args: -p <port> -analyticsDir <dir> -rdbPort <port> -hdbPort <port> -procName GW

system"l tick/utils/main.q";

.log.info["Initialising GW"];

// ── Database connections ─────────────────────────────────────────────────
.log.info[enlist["Connecting to DB processes [RDB port: %s] [HDB port: %s]"],
    (CLI_ARGS[`rdbPort]; CLI_ARGS[`hdbPort])];

CONNECTIONS:([handle:`int$()];proc:`$();alive:`boolean$());

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

.z.pc:{
    .log.warn[("Lost connection to DB process:\t %r"; CONNECTIONS[x])];
    CONNECTIONS[x;`alive]:0b;
 };

// ── Query helpers ────────────────────────────────────────────────────────
.kxgw.getRDB:{first exec 1?handle from CONNECTIONS where alive, proc like "RDB_*"};
.kxgw.getHDB:{first exec 1?handle from CONNECTIONS where alive, proc like "HDB_*"};

// ── Query entry point ─────────────────────────────────────────────────────
// target : `rdb | `hdb | `both
// query  : string | parse-tree | (rdbQuery;hdbQuery) for `both
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

// Alias used by analytics files.
.restgw.query:.kxgw.query;

// ── REST server ───────────────────────────────────────────────────────────
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

// ── Timer ─────────────────────────────────────────────────────────────────
.timer.funcs[`gc]:{[] .Q.gc[]};

system"t 60000";

.log.info[("GW successfully initialised on port [%s]"; `long$first system"p")];
