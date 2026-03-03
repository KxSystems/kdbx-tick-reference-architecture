// Sample script for defining a REST API endpoint for querying the HDB

hdbQuery:{[tab;d;t1;t2;s]
    // "select from tab where time within (t1;t2), sym=s"
    // Default to all syms when not provided
    w:((=;`date;d);(within;`time;(t1;t2)));
    if[not null s;w:w,enlist (=;`sym;enlist s)];
    // IPC with parse tree
    h:first exec 1?handle from CONNECTIONS where proc like "HDB_*";
    /show h "CLI_ARGS[`procName]";
    h (?;tab;w;0b;())
 };

// Wrapper of hdbQuery for REST endpoint
hdbREST:{
    /.dbg.hdb:`time`inputs!(.z.p;x);
    hdbQuery . value x[`arg]
 };

// HDB REST endpoint params for .rest.register
.endpoints.hdb:(!). flip (
    (`request; `get);
    (`endpoint; "/hdb");
    (`description; "Query data in the HDB");
    (`qFunc; hdbREST);
    (
        `params; 
        .rest.reg.data[`tab;-11h;1b;`trade;"Table to query"],
        .rest.reg.data[`d;-14h;0b;.z.d-1;"Date to query"],
        .rest.reg.data[`t1;-17h;0b;00:00;"Lower time bound"],
        .rest.reg.data[`t2;-17h;0b;23:59;"Upper time bound"],
        .rest.reg.data[`s;-11h;0b;`;"Sym to filter for"]
    )
 );