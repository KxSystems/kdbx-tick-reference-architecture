// End-to-end test — Track 1 Tick Reference Architecture
//
// Covers:
//   Phase 2  — FH ingest + RDB row counts (data-flow gate)
//   Phase 3  — q-IPC query tests (delegates to api-test.q)
//   Phase 4  — RTE enrichment (weatherHeatIndex — not in api-test.q)
//   Phase 5  — EOD trigger + HDB verification
//   Phase 6  — REST endpoint tests post-EOD (delegates to rest-test.q)
//   Phase 7  — RDB leader failover to RDB_CHAIN_0
//   Phase 8  — restart.sh GW (kills GW, expects restart)
//
// Usage (from project root):
//   source .env && q scaled-tick++/tests/e2e-test.q -gwPort $GW_PORT -tpPort $TICK_PORT -fhPort $FH_PORT -procName e2e

system "l scaled-tick++/utils/main.q";

GW_PORT: "I"$first CLI_ARGS[`gwPort];
TP_PORT: "I"$first CLI_ARGS[`tpPort];
FH_PORT: "I"$first CLI_ARGS[`fhPort];

// ── Harness ───────────────────────────────────────────────────────────────
.t.pass:0; .t.fail:0;

.t.check:{[name;pred;val]
    ok:@[pred; val; {0b}];
    $[ok;
        [.log.info["[PASS] ",name];  .t.pass+:1];
        [.log.error["[FAIL] ",name," — got: ",-3!val]; .t.fail+:1]
    ];
 };

.t.section:{.log.info["=== ",x," ==="]};

// Run a sub-test script; returns 1b on exit 0, 0b on any non-zero exit.
.t.runScript:{[cmd] @[{system x; 1b}; cmd; {0b}]};

// ── Helpers ───────────────────────────────────────────────────────────────

// Find pid of a q process by exact procName (no partial matches like RDB_CHAIN).
.t.findPid:{[name]
    first system "pgrep -af 'q.*-procName ",name,"(\\s|$)' | awk '{print $1}'"
 };

// Safe pid cast — returns 0Ni on empty string or cast failure.
.t.toPid:{@["I"$;x;{0Ni}]};

// ── Connections ───────────────────────────────────────────────────────────
gwh:@[hopen; `$"::",string GW_PORT; {.log.error["Cannot connect to GW on port ",string GW_PORT]; exit 1}];
tph:@[hopen; `$"::",string TP_PORT; {.log.error["Cannot connect to TP on port ",string TP_PORT]; exit 1}];
fhh:@[hopen; `$"::",string FH_PORT; {.log.error["Cannot connect to FH on port ",string FH_PORT]; exit 1}];
.log.info["Connected — GW[",string[GW_PORT],"] TP[",string[TP_PORT],"] FH[",string[FH_PORT],"]"];

// ── Phase 2: FH ingest + RDB row counts ──────────────────────────────────
.t.section "Phase 2: FH ingest + RDB row counts";

fhh "\\t 1000";
.log.info["FH timer set to 1000ms — polling for RDB data (max 15s)..."];

i:0;
while[i<15;
    counts:gwh(`.kxgw.query; `rdb; "tables[]!count each value each tables[]");
    if[(99h=type counts) and any 0<value counts; i:99];
    if[i<15; system "sleep 1"; i+:1]
 ];
.t.check["RDB has data within 15s"; {x~99}; i];

rdbCounts:gwh(`.kxgw.query; `rdb; "tables[]!count each value each tables[]");
.log.info["RDB counts: ",-3!rdbCounts];
.t.check["energy rows on RDB";  {0<x`energy};  rdbCounts];
.t.check["weather rows on RDB"; {0<x`weather}; rdbCounts];

// ── Phase 3: q-IPC query tests ────────────────────────────────────────────
// Delegates to api-test.q which covers: string queries, parse-tree queries,
// sym filters, HDB (empty-safe), both target, and error handling.
.t.section "Phase 3: q-IPC query tests (api-test.q)";

apiCmd:"q scaled-tick++/tests/api-test.q -gwPort ",string[GW_PORT]," -procName api-test";
.log.info["Running: ",apiCmd];
.t.check["api-test.q passed"; {x}; .t.runScript[apiCmd]];

// ── Phase 4: RTE enrichment ───────────────────────────────────────────────
// weatherHeatIndex is not covered by api-test.q.
.t.section "Phase 4: RTE enrichment (weatherHeatIndex)";

heatRdb:gwh(`.kxgw.query; `rdb; "select from weatherHeatIndex");
.t.check["weatherHeatIndex on RDB returns table"; {98h=type x};  heatRdb];
.t.check["weatherHeatIndex on RDB has rows";      {0<count x};   heatRdb];

heatBoth:gwh(`.kxgw.query; `both; "select from weatherHeatIndex");
.t.check["weatherHeatIndex via both returns dict"; {(99h=type x) and `rdb`hdb~key x}; heatBoth];

// ── Phase 5: EOD trigger + HDB verify ────────────────────────────────────
.t.section "Phase 5: EOD trigger + HDB verification";

.log.info["Triggering .u.end[.z.d] on TP..."];
tph(".u.end"; .z.d);
.log.info["Waiting 3s for HDB write..."];
system "sleep 3";

hdbCounts:gwh(`.kxgw.query; `hdb; "tables[]!count each value each tables[]");
.log.info["HDB counts post-EOD: ",-3!hdbCounts];
.t.check["HDB energy has rows after EOD";  {0<x`energy};  hdbCounts];
.t.check["HDB weather has rows after EOD"; {0<x`weather}; hdbCounts];

both5:gwh(`.kxgw.query; `both; "select from energy");
.t.check["both post-EOD returns dict";       {(99h=type x) and `rdb`hdb~key x}; both5];
.t.check["both post-EOD: HDB side has rows"; {0<count x`hdb};                   both5];

// ── Phase 6: REST endpoint tests (post-EOD) ───────────────────────────────
// rest-test.q checks HTTP status AND response body shape. Running post-EOD
// ensures HDB-targeted endpoints (/energy/hdb, /weather/hdb) have real data
// and return JSON arrays rather than error bodies with HTTP 200.
.t.section "Phase 6: REST endpoint tests post-EOD (rest-test.q)";

restCmd:"q scaled-tick++/tests/rest-test.q -gwPort ",string[GW_PORT]," 2>&1";
.log.info["Running: q scaled-tick++/tests/rest-test.q -gwPort ",string GW_PORT];
.t.check["rest-test.q passed"; {x}; .t.runScript[restCmd]];

// ── Phase 7: RDB leader failover ──────────────────────────────────────────
.t.section "Phase 7: RDB leader failover";

rdbPid:.t.findPid["RDB"];
rdbPidI:.t.toPid[rdbPid];
.t.check["RDB leader process found"; {not null x}; rdbPidI];

if[not null rdbPidI;
    .log.info["Killing RDB leader (pid ",rdbPid,")..."];
    system "kill -9 ",rdbPid;
    system "sleep 1";
    failRes:gwh(`.kxgw.query; `rdb; "select from energy");
    .t.check["GW routes to RDB_CHAIN_0 after leader failure (no error)";
        {98h=type x};
        failRes];
 ];

// ── Phase 8: restart.sh GW ───────────────────────────────────────────────
.t.section "Phase 8: restart.sh GW";

gwPid:.t.findPid["GW"];
gwPidI:.t.toPid[gwPid];
.t.check["GW process found before kill"; {not null x}; gwPidI];

if[not null gwPidI;
    hclose gwh;
    .log.info["Killing GW (pid ",gwPid,")..."];
    system "kill -9 ",gwPid;
    system "sleep 0.5";
    system "./scaled-tick++/scripts/restart.sh GW -e .env -m 1";
    system "sleep 3";
    newGwh:@[hopen; `$"::",string GW_PORT; {0Ni}];
    .t.check["restart.sh restarted GW"; {not null x}; newGwh];
    if[not null newGwh;
        testQuery:newGwh(`.kxgw.query; `rdb; "select from energy");
        .t.check["restarted GW responds to queries"; {98h=type x}; testQuery];
        hclose newGwh;
    ];
 ];

// Reset FH timer — reconnect if Phase 8a restarted it
@[hclose; fhh; {[x] .log.info["FH handle was stale, reconnecting"]}];
fhh:@[hopen; `$"::",string FH_PORT; {0Ni}];
if[not null fhh; fhh "\\t 60000"; .log.info["FH timer reset to 60000ms"]; hclose fhh];
hclose tph;

// ── Summary ───────────────────────────────────────────────────────────────
.t.section "Summary";
.log.info["Passed: ",string .t.pass];
$[.t.fail>0; .log.error["Failed: ",string .t.fail]; .log.info["Failed: 0"]];

exit $[.t.fail>0; 1; 0];
