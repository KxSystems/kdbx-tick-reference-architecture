// scaled-tick++/src/fh.q - Feedhandler Process
//
// q scaled-tick++/src/fh.q -p $FH_PORT -tpPort $TICK_PORT -fhDir $FH_ANALYTIC_DIR \
//                    -fhTimer $FH_TIMER -procName FH
//
// Connects to the Tickerplant with exponential-backoff retry, loads every `.q` analytic file
// from `-fhDir` (each expected to populate the `.fh.upsert` namespace), and pushes a batch
// from each registered upsert to the TP on every timer tick.

system"l scaled-tick++/utils/main.q";

.log.info["Initialising FH"];

// @desc Open a TP connection with exponential backoff + jitter, fatal-exiting after `maxRetries`
// Handles TCP backlog exhaustion when multiple processes start simultaneously.
//
// @param maxRetries  {long}    Maximum number of connection attempts
//
// @return            {int}     Open TP handle
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

// @desc Tickerplant handle — established with up to 10 retry attempts at startup
TP_H:.fh.connectTPWithRetry[10];

// Load every `.q` file under `-fhDir`. Each is expected to register one or more
// `.fh.upsert.<name>` functions which the timer dispatch below invokes.
.log.info["Loading FH analytics"];
{[x]
    system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x
    }(first CLI_ARGS[`fhDir]);

// @desc Timer dispatch — invokes every registered `.fh.upsert.*` function once per tick
// Each upsert is responsible for publishing its own batch to the TP. Errors are caught
// per-upsert via `.Q.trp` so a failure in one upsert does not abort the others.
.timer.funcs[`fhUpsert]:{[]
    .Q.trp[{value[1_.fh.upsert]@\:(::)};::; {.log.error["Upsert failed | ERROR: ", x]}];
    };

// Activate the timer at the configured interval (ms)
system"t ",first CLI_ARGS[`fhTimer];
.log.info[enlist["Timer interval set to every [%s] ms"],(CLI_ARGS[`fhTimer])];

.log.info["Successfully initialised FH"];
