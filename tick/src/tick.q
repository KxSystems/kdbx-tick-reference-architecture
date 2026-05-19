// tick/src/tick.q - Tickerplant Process
//
// Globals used:
//   .u.w - dictionary of tables->(handle;syms)
//   .u.i - msg count in log file
//   .u.j - total msg count (log file plus those held in buffer)
//   .u.t - table names
//   .u.L - tp log filename, e.g. `:./sym2008.09.11
//   .u.l - handle to tp log file
//   .u.d - date
//
// q tick/src/tick.q -p $TICK_PORT -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP
//
// Loads every `.q` schema from $SCHEMA_DIR, opens (or rotates) the TP log under
// $TPLOG_NAME/$TPLOG_DIR, accepts subscriptions from RDB / RTE / other clients,
// fans publishes out, and rolls the day over via `.u.endofday` on midnight.

system"l tick/utils/main.q";

.log.info["Initializing tickerplant"];

// Load every schema file under $SCHEMA_DIR so every table this TP publishes is defined locally.
{[x]
    .log.info["Loading schemas from ",x];
    system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x;
    .log.info[("Successfully loaded schemas:\t %s"; tables[])];
    }[first CLI_ARGS[`schemaDir]];

if[not system"p";system"p 5010"];

\l tick/src/u.q
\d .u

// @desc Open or rotate the tickerplant log for date `x`
// Creates the log if missing, replays it via `-11!(-2;L)` to recover counts, aborts on corruption.
//
// @param x       {date}      Date used to derive the log filename suffix
//
// @return        {int}       Open log handle
ld:{if[not type key L::`$(-10_string L),string x;.[L;();:;()]];
    i::j::-11!(-2;L);
    if[0<=type i;-2 (string L)," is a corrupt log. Truncate to length ",(string last i)," and restart";exit 1];
    hopen L
    };

// @desc Bootstrap the tickerplant — initialize pub/sub state, validate schema, open log
// Validates that every published table starts with `time,sym (else throws 'timesym),
// applies `g#sym` to in-memory tables, sets the date, and opens the TP log when y is non-empty.
//
// @param x       {string}    TP log file prefix (e.g. "sym")
// @param y       {string}    Log directory ("" disables on-disk logging)
tick:{init[];
    if[not min(`time`sym~2#key flip value@)each t;'`timesym];
    @[;`sym;`g#]each t;
    d::.z.D;
    if[l::count y;L::`$":",y,"/",x,10#".";l::ld d]
    };

// @desc End-of-day procedure — broadcast `.u.end` to subscribers, advance the date, rotate log
endofday:{end d;d+:1;if[l;hclose l;l::0(`.u.ld;d)]};

// @desc Date-rollover guard — fires `endofday` when a new wall-clock day begins
// Aborts the timer if more than one day's gap is detected (clock-skew safety).
//
// @param x       {date}      Current wall-clock date
ts:{if[d<x;if[d<x-1;system"t 0";'"more than one day?"];endofday[]]};

// Two timer / upd shapes depending on whether the system timer was already running at load.
// Variant A (system timer pre-set): publish-then-clear loop, zero-latency upd.
if[system"t";
    .timer.funcs[`tick]:{pub'[t;value each t];@[`.;t;@[;`sym;`g#]0#];i::j;ts .z.D};
    upd:{[t;x]
        .log.debug[("[FLOW TP] upd received | table=%s rows=%d subs=%d"; string t; $[98h=type x;count x;count first x]; count .u.w t)];
        if[not -16=type first first x;if[d<"d"$a:.z.P;.z.ts[]];a:"n"$a;x:$[0>type first x;a,x;(enlist(count first x)#a),x]];
        t insert x;if[l;l enlist (`upd;t;x);j+:1];
        }
    ];

// Variant B (no system timer set): start a 1s timer and publish on upd (latency-first).
if[not system"t";system"t 1000";
    .timer.funcs[`tick]:{ts .z.D};
    upd:{[t;x]ts"d"$a:.z.P;
        .log.debug[("[FLOW TP] upd received | table=%s rows=%d subs=%d"; string t; $[98h=type x;count x;count first x]; count .u.w t)];
        if[not -16=type first first x;a:"n"$a;x:$[0>type first x;a,x;(enlist(count first x)#a),x]];
        f:key flip value t;pub[t;$[0>type first x;enlist f!x;flip f!x]];if[l;l enlist (`upd;t;x);i+:1];
        }
    ];

\d .

// Boot the tickerplant: log-file prefix from $TPLOG_NAME, log directory from -tplogDir.
.u.tick[getenv[`TPLOG_NAME]; first CLI_ARGS[`tplogDir]];
.log.info[("Tickerplant successfully initialized. Logging to:\t %r"; .u.L)];
