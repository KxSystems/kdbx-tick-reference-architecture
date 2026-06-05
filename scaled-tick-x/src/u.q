// scaled-tick-x/src/u.q - Pub/Sub Tickerplant Functionality
//
// Helper functions used by scaled-tick-x/src/tick.q
// Extends the base kdb-tick u.q with an RDB leader/follower failover hook driven from `.z.pc`.
//
// See https://github.com/KxSystems/kdb-tick for the base pattern

\d .u

// @desc Initialize the per-table subscription map `.u.w` (table -> list of (handle; syms))
init:{w::t!(count t::tables`.)#()};

// @desc Remove a (handle;syms) pair for table `x` whose handle is `y`
// Bound to .z.pc so subscriber disconnects auto-clean across every table.
// Additionally triggers `.u.failoverRDB[x]` when the closing handle belongs to a tracked RDB,
// promoting a follower to leader if the leader was the one that died.
//
// @param x       {symbol}    Table name to clean up
// @param y       {int}       Subscriber handle to remove
del:{w[x]_:w[x;;0]?y};.z.pc:{del[;x]each t;if[x in key .u.RDB_CONNECTIONS;failoverRDB[x]]};

// @desc Filter rows in `x` by sym set `y`, or pass through when y is `` (no filter)
//
// @param x       {table}     Rows to filter
// @param y       {symbol[]}  Symbols to include, or `` for all
//
// @return        {table}     Filtered rows
sel:{$[`~y;x;select from x where sym in y]};

// @desc Publish a batch from table `t` to every interested subscriber
// For each (handle; syms) entry in `.u.w[t]`, applies the sym filter and sends `(`upd; t; rows)`.
// Emits a `[FLOW TP] pub` debug line per call.
//
// @param t       {symbol}    Table name being published
// @param x       {table}     Rows to publish
pub:{[t;x]
    .log.debug[("[FLOW TP] pub | table=%s rows=%d subs=%d"; string t; $[98h=type x;count x;count first x]; count w t)];
    {[t;x;w]if[count x:sel[x]w 1;(neg first w)(`upd;t;x)]}[t;x] each w t
    };

// @desc Add the calling subscriber (.z.w) to table `x`'s subscription list with sym filter `y`
// Returns (table; current snapshot) so the subscriber can backfill before live updates begin
//
// @param x       {symbol}    Table name to subscribe to
// @param y       {symbol[]}  Sym filter (`` for all)
//
// @return        {list}      (table-name; current sym-filtered snapshot)
add:{$[(count w x)>i:w[x;;0]?.z.w;.[`.u.w;(x;i;1);union;y];w[x],:enlist(.z.w;y)];(x;$[99=type v:value x;sel[v]y;@[0#v;`sym;`g#]])};

// @desc Subscribe entry point — called remotely by RDB / RDB_CHAIN / RTE / other downstream clients
// When `x` is ``, recursively subscribes to every table; otherwise validates `x` is known,
// drops any stale entry for the calling handle, and adds a fresh one
//
// @param x       {symbol}    Table name to subscribe to (`` = all)
// @param y       {symbol[]}  Sym filter (`` for all)
//
// @return        {list}      Per-table (name; snapshot) tuples
sub:{if[x~`;:sub[;y]each t];if[not x in t;'x];del[x].z.w;add[x;y]};

// @desc Broadcast `(.u.end; x)` to every distinct subscriber across all tables
//
// @param x       {date}      EOD date to forward to subscribers
end:{(neg union/[w[;;0]])@\:(`.u.end;x)};
