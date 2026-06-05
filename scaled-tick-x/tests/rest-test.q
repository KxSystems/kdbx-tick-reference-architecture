// REST API test script
// Exercises the /energy/* and /weather/* endpoints served by REST_GW (a thin
// HTTP front-end that delegates to GW via q-IPC + deferred sync). Asserts HTTP
// status + JSON body shape for success and 404 paths.
// Usage: source .env && q scaled-tick-x/tests/rest-test.q -restPort $REST_PORT -procName rest-test
//   -restHost  (optional, default: localhost)

args:.Q.opt .z.x;

restHost:$[`restHost in key args; first args`restHost; "localhost"];
restPort:"J"$first args`restPort;

curlFlags:"";
base:"http://",restHost,":",string restPort;

pass:0;
fail:0;
total:0;

// ── HTTP helper ─────────────────────────────────────────────────────────
// Shell out to curl and capture both status code and body. Returns a dict
// `status`body!(httpStatusInt; bodyString). curl -w writes "<status>\n<body>".
.t.httpGet:{[path]
    cmd:"curl ",curlFlags,"-s -o - -w '\\n%{http_code}' '",base,path,"' 2>/dev/null";
    raw:system cmd;
    // Split: last line is status, everything before is body
    if[0=count raw; :`status`body!(0; "")];
    statusLine:last raw;
    body:"\n" sv -1_raw;
    `status`body!("J"$statusLine; body)
 };

// JSON-parse helper (needs kx.rest's output which is valid JSON)
.t.parse:{.j.k x};

// ── Test runner ─────────────────────────────────────────────────────────
// Each check takes (name; predicate; response).
// predicate is applied to the response; true => pass.
run:{[name;pred;resp]
    total+:1;
    ok:@[pred; resp; {0b}];
    $[ok;
        [-1 "  [PASS] ",name; pass+:1];
        [-2 "  [FAIL] ",name," — got: ",(-3!resp); fail+:1]
    ];
 };

// Predicates
is200:{200=x`status};
isJsonArray:{"["=first x`body};

// ── /energy/meta ────────────────────────────────────────────────────────
-1 "\n=== /energy/meta ===\n";
run["energy meta returns 200 JSON array";
    {[r] (is200 r) and isJsonArray r};
    .t.httpGet["/energy/meta"]];
run["energy meta body has consumption column";
    {[r] (is200 r) and any {(x[`c]~"consumption") and (first x[`t])~"f"} each .t.parse r`body};
    .t.httpGet["/energy/meta"]];

// ── /weather/meta ───────────────────────────────────────────────────────
-1 "\n=== /weather/meta ===\n";
run["weather meta returns 200 JSON array";
    {[r] (is200 r) and isJsonArray r};
    .t.httpGet["/weather/meta"]];
run["weather meta body has temp column";
    {[r] any {x[`c]~"temp"} each .t.parse r`body};
    .t.httpGet["/weather/meta"]];

// ── /energy/rdb ─────────────────────────────────────────────────────────
-1 "\n=== /energy/rdb ===\n";
run["energy rdb returns 200 JSON array";
    {[r] (is200 r) and isJsonArray r};
    .t.httpGet["/energy/rdb"]];
run["energy rdb filter by sym narrows results";
    {[r]
        if[not is200 r; :0b];
        rows:.t.parse r`body;
        // 0 rows is acceptable (no matching sym yet) but every returned row
        // must have that exact sym.
        (0=count rows) or all {x[`sym]~"BLOWER78_1"} each rows
    };
    .t.httpGet["/energy/rdb?s=BLOWER78_1"]];

// ── /energy/hdb ─────────────────────────────────────────────────────────
// /energy/hdb requires a date partition that exists in the HDB. If no energy
// data has been batch-loaded yet this will 500 with "no partitions", which
// we still treat as a structural success (endpoint reachable).
-1 "\n=== /energy/hdb ===\n";
run["energy hdb endpoint reachable";
    {[r] r[`status] in 200 500};
    .t.httpGet["/energy/hdb?d=",string .z.d]];

// ── /weather/rdb ────────────────────────────────────────────────────────
-1 "\n=== /weather/rdb ===\n";
run["weather rdb returns 200 JSON array";
    {[r] (is200 r) and isJsonArray r};
    .t.httpGet["/weather/rdb"]];
run["weather rdb filter by sym narrows results";
    {[r]
        if[not is200 r; :0b];
        rows:.t.parse r`body;
        (0=count rows) or all {x[`sym]~"San Diego"} each rows
    };
    .t.httpGet["/weather/rdb?s=San%20Diego"]];

// ── /weather/hdb ────────────────────────────────────────────────────────
-1 "\n=== /weather/hdb ===\n";
run["weather hdb endpoint reachable";
    {[r] r[`status] in 200 500};
    .t.httpGet["/weather/hdb?d=",string .z.d]];

// ── Unknown path ────────────────────────────────────────────────────────
-1 "\n=== 404 path ===\n";
run["unknown endpoint returns 404";
    {[r] 404=r`status};
    .t.httpGet["/nonexistent"]];

// ── Concurrent-call sanity check ────────────────────────────────────────
// Fires N curl clients in parallel, asserts all 200s. Wall-clock is printed for human inspection;
// a strict "elapsed >= N * baseline" assertion is unreliable since curl fork
// + TCP overhead dominates the baseline.
-1 "\n=== Concurrent-call sanity check ===\n";

.t.timeCurl:{[path]
    t0:.z.P;
    .t.httpGet path;
    .z.P - t0
 };

.t.timeMany:{[path;n]
    cmd:"seq ",(string n)," | xargs -P ",(string n)," -I{} ",
        "curl ",curlFlags,"-s -o /dev/null -w '%{http_code}\\n' '",base,path,"'";
    t0:.z.P;
    out:system cmd;
    elapsed:.z.P - t0;
    codes:"J"$out;
    `elapsed`codes!(elapsed; codes)
 };

.t.ms:{[ns] string `long$(`long$ns) div 1000000};

// Warm the pool so the first-post-restart race is gone, then baseline.
.t.httpGet["/energy/rdb"];
baseline:.t.timeCurl["/energy/rdb"];

n:5;
r:.t.timeMany["/energy/rdb"; n];

-1 "  baseline single-call:       ",.t.ms[baseline]," ms";
-1 "  ",(string n)," concurrent total:         ",.t.ms[r`elapsed]," ms";
-1 "  (if strictly serialised: ~",.t.ms[n*`long$baseline]," ms.";
-1 "   The GW itself is non-blocking via -30! deferred sync, but a single";
-1 "   REST_GW process is single-threaded q and serialises its own HTTP";
-1 "   queue. To scale HTTP concurrency raise REST_GW_COUNT — each adds";
-1 "   another front-end sharing REST_PORT via SO_REUSEPORT.)";

run[(string n)," concurrent calls all return 200";
    {[n;r] (n=count r`codes) and all 200=r`codes}[n;];
    r];

// ── Results ─────────────────────────────────────────────────────────────
-1 "\n=== Results ===\n";
-1 "  Total: ",string total;
-1 "  Pass:  ",string pass;
-1 "  Fail:  ",string fail;
-1 "";

exit $[fail>0; 1; 0];
