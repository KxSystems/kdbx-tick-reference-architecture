// GW query test script — Track 1 (Tick Reference Architecture)
// Tests .kxgw.query against rdb, hdb, and both targets via the GW.
// Usage: source .env && q tick++/tests/api-test.q -gwPort $GW_PORT -procName api-test

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
        expected~`both;  (99h=type res) and `rdb`hdb~key res;
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

// ── HDB queries ──────────────────────────────────────────────────────────
-1 "\n=== .kxgw.query HDB Tests ===\n";

run["HDB string query returns table";
    {h (`.kxgw.query; `hdb; "select from energy where date=first date")};
    `any];

run["HDB weather query returns table";
    {h (`.kxgw.query; `hdb; "select from weather where date=first date")};
    `any];

// ── Both (fan-out) ────────────────────────────────────────────────────────
-1 "\n=== .kxgw.query Both (sequential fan-out) Tests ===\n";

run["Both returns dict with rdb and hdb keys";
    {h (`.kxgw.query; `both; ("select from energy"; "select from energy where date=first date"))};
    `both];

run["Both with single query applied to both targets";
    {h (`.kxgw.query; `both; "select from energy")};
    `both];

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
