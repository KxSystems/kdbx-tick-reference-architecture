// Sample analytics - demonstrates the .kxgw.query convention for async dispatch
// These are example queries a q client would send to the GW

// Query RDB for data within a time range
// Usage from q client:
//   h:hopen `:localhost:5013
//   h (`.kxgw.query; `rdb; ({[tab;t1;t2] select from tab where time within (t1;t2)}; `energy; 0D15:34:00; 0D15:35:00))
//
// The query projection (func;arg1;arg2;...) is sent to a QP worker
// which executes it against an RDB process: rdbHandle (func;arg1;arg2;...)

// Query HDB for historical data
// Usage from q client:
//   h (`.kxgw.query; `hdb; ({[tab;d;t1;t2] select from tab where date=d, time within (t1;t2)}; `weather; 2026.02.18; 0D15:34:00; 0D15:35:00))

// Sym-filtered query
// Usage from q client:
//   h (`.kxgw.query; `rdb; ({[tab;t1;t2;s] select from tab where time within (t1;t2), sym=s}; `energy; 0D15:34:00; 0D15:35:00; `BLOWER78_1))

// Simple full-table select (string query form)
// Usage from q client:
//   h (`.kxgw.query; `rdb; "select from energy")

// Query both RDB and HDB in parallel (scatter-gather fan-out)
// Pass a two-element list: (rdbQuery; hdbQuery) — each can be different
// Returns `rdb`hdb!(rdbResult; hdbResult) — client handles aggregation
// Fails if either source is down or errors.
// Usage from q client:
//   h (`.kxgw.query; `both; ("select from energy"; "select from energy where date=2026.04.16"))
//   h (`.kxgw.query; `both; ("select from weather"; "select from weather where date within 2026.04.01 2026.04.16"))
//
// Access results:
//   res:h (`.kxgw.query; `both; ("select from energy"; "select from energy where date=2026.04.16"))
//   res`rdb   // real-time data
//   res`hdb   // historical data
//   raze value res  // combine if schemas match
