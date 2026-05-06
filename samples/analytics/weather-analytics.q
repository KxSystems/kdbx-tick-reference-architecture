// REST endpoints for the weather table.
//   /weather/rdb   - query realtime weather
//   /weather/hdb   - query historical weather
//   /weather/meta  - return meta (schema) for weather
//
// These analytics are loaded by the GW. Each handler builds a
// parse-tree query and delegates to the main GW via sync q-IPC through
// .restgw.query. The GW uses -30! deferred sync, routes via QR to a QP,
// and returns the result — same path as q-IPC clients.

// ── RDB query ───────────────────────────────────────────────────────────

weatherRdbQuery:{[t1;t2;s]
    w:enlist (within;`time;(t1;t2));
    if[not null s; w:w,enlist (=;`sym;enlist s)];
    .restgw.query[`rdb; (?;`weather;w;0b;())]
 };

weatherRdbREST:{weatherRdbQuery . value x[`arg]};

// ── HDB query ───────────────────────────────────────────────────────────
// HDB partitions expose the partition key as virtual column `date`.

weatherHdbQuery:{[d;t1;t2;s]
    w:((=;`date;d);(within;`time;(t1;t2)));
    if[not null s; w:w,enlist (=;`sym;enlist s)];
    .restgw.query[`hdb; (?;`weather;w;0b;())]
 };

weatherHdbREST:{weatherHdbQuery . value x[`arg]};

// ── Meta ────────────────────────────────────────────────────────────────
// Meta delegated to HDB (authoritative schema including date column).

weatherMetaREST:{[x] .restgw.query[`hdb; "0!meta `weather"]};

// ── Endpoint registrations ──────────────────────────────────────────────

.endpoints.weatherRdb:(!). flip (
    (`request; `get);
    (`endpoint; "/weather/rdb");
    (`description; "Query the weather table on an RDB (realtime)");
    (`qFunc; weatherRdbREST);
    (
        `params;
        .rest.reg.data[`t1;-16h;0b;0D00:00:00.000000000;"Lower time bound (timespan)"],
        .rest.reg.data[`t2;-16h;0b;0D23:59:59.999999999;"Upper time bound (timespan)"],
        .rest.reg.data[`s;-11h;0b;`;"Location sym (e.g. `$\"San Diego\") to filter for"]
    )
 );

.endpoints.weatherHdb:(!). flip (
    (`request; `get);
    (`endpoint; "/weather/hdb");
    (`description; "Query the weather table on an HDB (historical)");
    (`qFunc; weatherHdbREST);
    (
        `params;
        .rest.reg.data[`d;-14h;1b;.z.d-1;"Partition date to query"],
        .rest.reg.data[`t1;-16h;0b;0D00:00:00.000000000;"Lower time bound (timespan)"],
        .rest.reg.data[`t2;-16h;0b;0D23:59:59.999999999;"Upper time bound (timespan)"],
        .rest.reg.data[`s;-11h;0b;`;"Location sym (e.g. `$\"San Diego\") to filter for"]
    )
 );

.endpoints.weatherMeta:(!). flip (
    (`request; `get);
    (`endpoint; "/weather/meta");
    (`description; "Return meta (schema) for the weather table");
    (`qFunc; weatherMetaREST);
    (`params; ())
 );
