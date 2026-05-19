// tick/src/fh.q - Feedhandler Process
//
// q tick/src/fh.q -p $FH_PORT -tpPort $TICK_PORT -fhTimer $FH_TIMER -procName FH
//
// Connects to the Tickerplant with exponential-backoff retry, then publishes a single
// synthetic row to each of the `energy` and `weather` tables on every timer tick.
// To extend, customise the body of `.timer.funcs[`fhUpsert]` below — read from your
// own source, transform as needed, and call `neg[TP_H] (`.u.upd; <table>; <row data>)`.

system"l tick/utils/main.q";

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

// @desc Timer dispatch — publish one synthetic row to `energy` and one to `weather` each tick
// Replace the row construction here with your own data source / transformation.
.timer.funcs[`fhUpsert]:{[]
    neg[TP_H] (`.u.upd; `energy;
        (enlist .z.n; enlist `BLOWER78_1; enlist .z.d; enlist .z.t; enlist 50f + rand 100f));
    neg[TP_H] (`.u.upd; `weather;
        (enlist .z.n; enlist `SanDiego; enlist .z.z; enlist 20f + rand 10f; enlist 40f + rand 30f; enlist rand 5f; enlist rand 20f));
    };

// Activate the timer at the configured interval (ms)
system"t ",first CLI_ARGS[`fhTimer];
.log.info[enlist["Timer interval set to every [%s] ms"],(CLI_ARGS[`fhTimer])];

.log.info["Successfully initialised FH"];
