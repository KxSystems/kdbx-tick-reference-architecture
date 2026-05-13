//Load utility scripts
system"l tick/utils/main.q";

.log.info["Initialising FH"];

// Open connection to TP with retry + exponential backoff + jitter
// Handles TCP backlog exhaustion when multiple processes start simultaneously
.fh.connectTPWithRetry:{[maxRetries]
    i:0;
    h:0N;
    while[(i < maxRetries) and null h;
        h:@[hopen; `$"::",first CLI_ARGS[`tpPort]; {.log.warn[x]; 0N}];
        if[null h;
            delay:(0.1 * 2 xexp i) + 0.1 * first 1?1f;
            .log.warn[("TP connect attempt %d/%d failed, retrying in %s ms";i+1;maxRetries;string`long$1000*delay)];
            system"sleep ",string delay;
        ];
        i+:1;
    ];
    if[null h; .log.fatal["Failed to connect to TP after ",string[maxRetries]," attempts — exiting"]; exit 1];
    h
 };
TP_H:.fh.connectTPWithRetry[10];

//Loading FH analytics 
.log.info["Loading FH analytics"];

{[x]
        system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x       
 }(first CLI_ARGS[`fhDir]);

//Live data stimulation using timer. Sample data is upserted to the TP every set interval
//On failure, logs error message
.timer.funcs[`fhUpsert]:{[]
        .Q.trp[{value[1_.fh.upsert]@\:(::)};::; {.log.error["Upsert failed | ERROR: ", x]}];
        };

//Timer interval
system"t ",first CLI_ARGS[`fhTimer];
.log.info[enlist["Timer interval set to every [%s] ms"],(CLI_ARGS[`fhTimer])];

.log.info["Successfully initialised FH"];
