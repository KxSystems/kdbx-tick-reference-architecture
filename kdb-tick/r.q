/q tick/r.q [host]:port[:usr:pwd] [host]:port[:usr:pwd]
/2008.09.09 .k ->.q

if[not "w"=first string .z.o;system "sleep 1"];

// Load utility scripts
system"l utils/main.q";

.log.info["Initialising RDB"];

MAIN_FLAG:"RDB_MAIN"~first CLI_ARGS[`procName];

upd:insert;

/ get the ticker plant and history ports, defaults are 5010,5012
/.u.x:.z.x,(count .z.x)_(":5010";":5012");
// 0 == tp port
// 1 == hdb port
/TODO: logging/defaults
/.u.x:raze CLI_ARGS[`tpPort`hdbPort];
// Handle single vs multiple HDBs
.u.x:(first CLI_ARGS[`tpPort];":",first CLI_ARGS[`hdbPort]);

/ end of day: save, clear, hdb reload
/.u.end:{t:tables`.;t@:where `g=attr each t@\:`sym;.Q.hdpf[`$":",.u.x 1;`:.;x;`sym];@[;`sym;`g#] each t;};
// Only save/reload if main RDB
.u.end:{
    .log.info["Running .u.end"];
    t:tables`.;t@:where `g=attr each t@\:`sym;
    $[MAIN_FLAG;
        [
            .log.info["Running EOD Save"];
            .Q.hdpf[`$":",.u.x 1;`:.;x;`sym];
            @[;`sym;`g#] each t;
            // Reload additional HDBs
            @[;"system \"l .\"";{x}] each `$"::",/:1_CLI_ARGS[`hdbPort]
        ];
        @[`.;t;@[;`sym;`g#]0#]
    ];
 };

/ init schema and sync up from log file;cd to hdb(so client save can run)
/.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",1_-10_string first reverse y};
/ HARDCODE \cd if other than logdir/db
// Custom DB location
/TODO: logging for tplog replay
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",first CLI_ARGS[`hdbDir]};

/ connect to ticker plant for (schema;(logcount;log))
/.u.rep .(hopen `$":",.u.x 0)"(.u.sub[`;`];`.u `i`L)";
// Connect to TP to initialise as leader/follower and subscribe
.u.rep . {[h]
    h ({`.u.RDB_CONNECTIONS upsert (.z.w;`$x;1b;"RDB_MAIN"~x);(.u.sub[`;`];`.u `i`L)};first CLI_ARGS[`procName])
 }[(hopen `$":",.u.x 0)];

.log.info[("RDB successfully initialised. Connected to TP at port [%s] and HDB at location [%s]";1_.u.x[0];first system"pwd")];
