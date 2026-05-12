// API layer test script
// Tests .api.query validation, query building, and end-to-end dispatch
// Usage: source .env && q tests/api-test.q -gwPort 5013 -procName api-test

args:.Q.opt .z.x;
h:@[hopen; `$"::",first args`gwPort; {-2 "Failed to connect to GW: ",x; exit 1}];

pass:0;
fail:0;
total:0;

// Test runner
run:{[name;expr;expected]
    total+:1;
    res:@[expr; ::; {`error`msg!("test error";x)}];
    ok:$[
        expected~`any;      1b;                       // any non-error result is fine
        expected~`error;    (99h=type res) and $[99h=type res; `error in key res; 0b];  // expect error dict or signal
        expected~`table;    98h=type res;              // expect a table
        expected~`dict;     99h=type res;              // expect a dict
        expected~`both;     (99h=type res) and `rdb`hdb~key res;  // expect `rdb`hdb dict
        res~expected                                   // exact match
    ];
    $[ok;
        [-1 "  [PASS] ",name; pass+:1];
        [-2 "  [FAIL] ",name," — got: ",(-3!res); fail+:1]
    ];
 };

// ============================================================
-1 "\n=== .api.query Validation Tests ===\n";

// Missing required params
run["Missing table param";
    {h (`.api.query; enlist[`target]!enlist `rdb)};
    `error];

run["Missing target param";
    {h (`.api.query; enlist[`table]!enlist `energy)};
    `error];

// Invalid table
run["Unknown table";
    {h (`.api.query; `table`target!(`nonexistent;`rdb))};
    `error];

// Invalid target
run["Invalid target";
    {h (`.api.query; `table`target!(`energy;`invalid))};
    `error];

// Invalid filter column
run["Unknown filter column";
    {h (`.api.query; `table`target`where!(`energy;`rdb;(enlist `badcol)!(enlist 42)))};
    `error];

// Invalid select column
run["Unknown select column";
    {h (`.api.query; `table`target`cols!(`energy;`rdb;`badcol))};
    `error];

// ============================================================
-1 "\n=== .api.query RDB Tests ===\n";

// Basic select all
run["RDB select all from energy";
    {h (`.api.query; `table`target!(`energy;`rdb))};
    `table];

// Select with column filter
run["RDB select specific columns";
    {h (`.api.query; `table`target`cols!(`energy;`rdb;`time`consumption))};
    `table];

// Select with sym equality filter
run["RDB filter by sym";
    {h (`.api.query; `table`target`where!(`energy;`rdb;(enlist `sym)!(enlist `BLOWER78_1)))};
    `table];

// Select with time range (within)
run["RDB filter by time range";
    {h (`.api.query; `table`target`where!(`energy;`rdb;(enlist `time)!(enlist (0D00:00:00.000000000; 0D23:59:59.999999999))))};
    `table];

// Combined filters + columns
run["RDB combined filters and columns";
    {h (`.api.query; `table`target`where`cols!(`energy;`rdb;(enlist `sym)!(enlist `BLOWER78_1);`time`consumption))};
    `table];

// ============================================================
-1 "\n=== .api.query HDB Tests ===\n";

run["HDB select all from energy";
    {h (`.api.query; `table`target!(`energy;`hdb))};
    `table];

run["HDB select specific columns";
    {h (`.api.query; `table`target`cols!(`energy;`hdb;`time`consumption))};
    `table];

// ============================================================
-1 "\n=== .api.query Both (Fan-out) Tests ===\n";

run["Both select all from energy";
    {h (`.api.query; `table`target!(`energy;`both))};
    `both];

run["Both select with columns";
    {h (`.api.query; `table`target`cols!(`energy;`both;`time`consumption))};
    `both];

run["Both select with filter";
    {h (`.api.query; `table`target`where!(`energy;`both;(enlist `sym)!(enlist `BLOWER78_1)))};
    `both];

// ============================================================
-1 "\n=== .kxgw.query Raw Tests ===\n";

run["Raw RDB string query";
    {h (`.kxgw.query; `rdb; "select from energy")};
    `table];

run["Raw HDB string query";
    {h (`.kxgw.query; `hdb; "d:first date;10?select from energy where date=d")};
    `table];

run["Raw both fan-out";
    {h (`.kxgw.query; `both; ("select from energy"; "d:first date; 10?select from energy where date=d"))};
    `both];

// ============================================================
-1 "\n=== Results ===\n";
-1 "  Total: ",string total;
-1 "  Pass:  ",string pass;
-1 "  Fail:  ",string fail;
-1 "";

hclose h;
exit $[fail>0; 1; 0];
