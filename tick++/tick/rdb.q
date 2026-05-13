/q tick/r.q [host]:port[:usr:pwd] [host]:port[:usr:pwd]
/2008.09.09 .k ->.q

if[not "w"=first string .z.o;system "sleep 1"];

// Load utility scripts
system"l tick/utils/main.q";

.log.info["Initialising RDB"];

MAIN_FLAG:"RDB"~first CLI_ARGS[`procName];

upd:{[t;x]
    .log.debug[("[FLOW RDB] upd received | table=%s rows=%d";
        string t; $[98h=type x;count x;count first x])];
    t insert x;
 };

// Handle single vs multiple HDBs. Ports come in bare; we prepend "::" for TCP loopback.
.u.x:("::",first CLI_ARGS[`tpPort];"::",first CLI_ARGS[`hdbPort]);

// Only save/reload if main RDB
.u.end:{
    .log.info["Running .u.end"];
    t:tables`.;t@:where `g=attr each t@\:`sym;
    $[MAIN_FLAG;
        [
            .log.info["Running EOD Save"];
            .Q.hdpf[`$.u.x 1;`:.;x;`sym];
            @[;`sym;`g#] each t;
            // Reload additional HDBs
            @[;"system \"l .\"";{x}] each `$"::",/:1_CLI_ARGS[`hdbPort]
        ];
        @[`.;t;@[;`sym;`g#]0#]
    ];
 };

// Custom DB location
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",first CLI_ARGS[`hdbDir]};

// TP handle - tracked for reconnection
TP_H:0N;

// Connect to TP, register as leader/follower, subscribe, and replay log
// Returns 1b on success, 0b on failure
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

// Retry TP connection with exponential backoff + jitter to absorb startup bursts
// Handles TCP backlog exhaustion when many RDBs start simultaneously
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

// Attempt TP connection — if still unavailable after retries, load schemas from files so tables exist (empty)
if[not .rdb.connectTPWithRetry[10];
    .log.warn["TP not available — loading schemas from files"];
    {[x]
        system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
        .log.info[("Loaded schemas from files: %s"; tables[])];
    }[getenv[`SCHEMA_DIR]];
    system "cd ",first CLI_ARGS[`hdbDir]
    ];

// Reconnection timer - re-establish TP subscription when it becomes available
.timer.funcs[`rdbReconnectTP]:{[]
    if[null TP_H;
        .rdb.connectTP[];
    ];
 };

// Connection management
.z.pc:{[h]
    if[h~TP_H;
        .log.warn["Lost connection to TP"];
        TP_H::0N;
    ];
 };

// Evaluates incoming async messages (required for receiving TP upd calls)
.z.ps:{value x};

// Set timer for reconnection and logging checks
system"t 60000";

.log.info[("RDB successfully initialised on port [%s] HDB location [%s]";`long$first system"p";first system"pwd")];
