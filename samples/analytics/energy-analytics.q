// REST endpoints for the energy table.
//   /energy/rdb   - query realtime energy
//   /energy/idb   - query intraday-flushed energy (tick-x/, scaled-tick-x/ only)
//   /energy/hdb   - query historical energy
//   /energy/meta  - return meta (schema) for energy
//
// These analytics are loaded by the GW. Each handler builds a
// parse-tree query and delegates to the main GW via sync q-IPC through
// .restgw.query. The GW uses -30! deferred sync, routes via QR to a QP,
// and returns the result — same path as q-IPC clients.

// ── RDB query ───────────────────────────────────────────────────────────

energyRdbQuery:{[t1;t2;s]
    w:enlist (within;`time;(t1;t2));
    if[not null s; w:w,enlist (=;`sym;enlist s)];
    .restgw.query[`rdb; (?;`energy;w;0b;())]
 };

energyRdbREST:{energyRdbQuery . value x[`arg]};

// ── IDB query ───────────────────────────────────────────────────────────
// Same shape as the RDB query — no `date` filter since IDB only holds today's
// flushed int-partitions. Returns an error dict on tick/ (no `idb` tier).

energyIdbQuery:{[t1;t2;s]
    w:enlist (within;`time;(t1;t2));
    if[not null s; w:w,enlist (=;`sym;enlist s)];
    .restgw.query[`idb; (?;`energy;w;0b;())]
 };

energyIdbREST:{energyIdbQuery . value x[`arg]};

// ── HDB query ───────────────────────────────────────────────────────────

energyHdbQuery:{[d;t1;t2;s]
    w:((=;`date;d);(within;`time;(t1;t2)));
    if[not null s; w:w,enlist (=;`sym;enlist s)];
    .restgw.query[`hdb; (?;`energy;w;0b;())]
 };

energyHdbREST:{energyHdbQuery . value x[`arg]};

// ── Meta ────────────────────────────────────────────────────────────────
// Meta delegated to HDB (authoritative schema including date column).

energyMetaREST:{[x] .restgw.query[`hdb; "0!meta `energy"]};

// ── Endpoint registrations ──────────────────────────────────────────────

.endpoints.energyRdb:(!). flip (
    (`request; `get);
    (`endpoint; "/energy/rdb");
    (`description; "Query the energy table on an RDB (realtime)");
    (`qFunc; energyRdbREST);
    (
        `params;
        .rest.reg.data[`t1;-16h;0b;0D00:00:00.000000000;"Lower time bound (timespan)"],
        .rest.reg.data[`t2;-16h;0b;0D23:59:59.999999999;"Upper time bound (timespan)"],
        .rest.reg.data[`s;-11h;0b;`;"Blower sym (e.g. BLOWER78_1) to filter for"]
    )
 );

.endpoints.energyIdb:(!). flip (
    (`request; `get);
    (`endpoint; "/energy/idb");
    (`description; "Query the energy table on the IDB (intraday)");
    (`qFunc; energyIdbREST);
    (
        `params;
        .rest.reg.data[`t1;-16h;0b;0D00:00:00.000000000;"Lower time bound (timespan)"],
        .rest.reg.data[`t2;-16h;0b;0D23:59:59.999999999;"Upper time bound (timespan)"],
        .rest.reg.data[`s;-11h;0b;`;"Blower sym (e.g. BLOWER78_1) to filter for"]
    )
 );

.endpoints.energyHdb:(!). flip (
    (`request; `get);
    (`endpoint; "/energy/hdb");
    (`description; "Query the energy table on an HDB (historical)");
    (`qFunc; energyHdbREST);
    (
        `params;
        .rest.reg.data[`d;-14h;1b;.z.d-1;"Partition date to query"],
        .rest.reg.data[`t1;-16h;0b;0D00:00:00.000000000;"Lower time bound (timespan)"],
        .rest.reg.data[`t2;-16h;0b;0D23:59:59.999999999;"Upper time bound (timespan)"],
        .rest.reg.data[`s;-11h;0b;`;"Blower sym (e.g. BLOWER78_1) to filter for"]
    )
 );

.endpoints.energyMeta:(!). flip (
    (`request; `get);
    (`endpoint; "/energy/meta");
    (`description; "Return meta (schema) for the energy table");
    (`qFunc; energyMetaREST);
    (`params; ())
 );
