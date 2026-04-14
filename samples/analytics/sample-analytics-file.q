// Sample script for defining a REST API endpoint for querying the RDB

rdbQuery:{[tab;t1;t2;s]
    // "select from tab where time within (t1;t2), sym=s"
    // Default to all syms when not provided
    w:enlist (within;`time;(t1;t2));
    if[not null s;w:w,enlist (=;`sym;enlist s)];
    // IPC with parse tree
    h:first exec 1?handle from CONNECTIONS where alive, proc like "RDB_*";
    if[null h;:"No RDBs available"];
    /show h "CLI_ARGS[`procName]";
    h (?;tab;w;0b;())
 };

// Wrapper of rdbQuery for REST endpoint
rdbREST:{
    /.dbg.rdb:`time`inputs!(.z.p;x);
    rdbQuery . value x[`arg]
 };

// RDB REST endpoint params for .rest.register
.endpoints.rdb:(!). flip (
    (`request; `get);
    (`endpoint; "/rdb");
    (`description; "Query data in the RDB");
    (`qFunc; rdbREST);
    (
        `params; 
        .rest.reg.data[`tab;-11h;1b;`energy;"Table to query"],
        .rest.reg.data[`t1;-17h;0b;00:00;"Lower time bound"],
        .rest.reg.data[`t2;-17h;0b;23:59;"Upper time bound"],
        .rest.reg.data[`s;-11h;0b;`;"Sym to filter for"]
    )
 );