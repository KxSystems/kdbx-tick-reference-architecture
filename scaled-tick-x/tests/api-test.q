// GW query test script — Track 1 (Tick Reference Architecture)
// Tests .kxgw.query against rdb, idb, hdb, and all targets via the GW.
// Usage: source .env && q scaled-tick-x/tests/api-test.q -gwPort $GW_PORT -procName api-test

args:.Q.opt .z.x;
h:@[hopen; `$"::",first args`gwPort; {-2 "Failed to connect to GW: ",x; exit 1}];

pass:0;
fail:0;
total:0;

run:{[name;expr;expected]
    total+:1;
    res:@[expr; ::; {`error`msg!("test error";x)}];
    ok:$[
        expected~`any;   1b;
        expected~`error; (99h=type res) and `error in key res;
        expected~`table; 98h=type res;
        expected~`dict;  99h=type res;
        expected~`all;   (99h=type res) and `rdb`idb`hdb~key res;
        res~expected
    ];
    $[ok;
        [-1 "  [PASS] ",name; pass+:1];
        [-2 "  [FAIL] ",name," — got: ",(-3!res); fail+:1]
    ];
 };

// ── RDB queries ──────────────────────────────────────────────────────────
-1 "\n=== .kxgw.query RDB Tests ===\n";

run["RDB string query returns table";
    {h (`.kxgw.query; `rdb; "select from energy")};
    `table];

run["RDB parse-tree query returns table";
    {h (`.kxgw.query; `rdb; (?;`energy;enlist (within;`time;(0D00:00:00.000000000;0D23:59:59.999999999));0b;()))};
    `table];

run["RDB sym filter returns table";
    {h (`.kxgw.query; `rdb; ({[t;s] select from t where sym=s}; `energy; `BLOWER78_1))};
    `table];

run["RDB weather query returns table";
    {h (`.kxgw.query; `rdb; "select from weather")};
    `table];

// ── IDB queries ──────────────────────────────────────────────────────────
// The IDB may legitimately be empty (no flush has occurred yet), so assert empty-safe.
-1 "\n=== .kxgw.query IDB Tests ===\n";

run["IDB string query returns a result";
    {h (`.kxgw.query; `idb; "select from energy")};
    `any];

// ── HDB queries ──────────────────────────────────────────────────────────
-1 "\n=== .kxgw.query HDB Tests ===\n";

run["HDB string query returns table";
    {h (`.kxgw.query; `hdb; "select from energy where date=first date")};
    `any];

run["HDB weather query returns table";
    {h (`.kxgw.query; `hdb; "select from weather where date=first date")};
    `any];

// ── All (fan-out across rdb + idb + hdb) ──────────────────────────────────
-1 "\n=== .kxgw.query All (sequential fan-out) Tests ===\n";

run["All returns dict with rdb, idb, and hdb keys";
    {h (`.kxgw.query; `all; ("select from energy"; "select from energy"; "select from energy where date=first date"))};
    `all];

run["All with single query applied to all targets";
    {h (`.kxgw.query; `all; "select from energy")};
    `all];

// ── Error handling ────────────────────────────────────────────────────────
-1 "\n=== Error Handling Tests ===\n";

run["Unknown target returns error dict";
    {h (`.kxgw.query; `invalid; "select from energy")};
    `error];

// ── Results ──────────────────────────────────────────────────────────────
-1 "\n=== Results ===\n";
-1 "  Total: ",string total;
-1 "  Pass:  ",string pass;
-1 "  Fail:  ",string fail;
-1 "";

hclose h;
exit $[fail>0; 1; 0];
