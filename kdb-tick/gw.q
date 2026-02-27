// Load utility scripts
system"l utils/main.q";

.log.info["Initialising GW"];

.log.info[enlist["Connecting to DB processes on ports [RDB: %s] and [HDB: %s]"],raze CLI_ARGS[`rdbPort`hdbPort]];
RDB_H:hopen`$"::",first CLI_ARGS[`rdbPort];
HDB_H:hopen`$"::",first CLI_ARGS[`hdbPort];

// set up .z.pg/.z.pp on rdb/hdb?

// define query funcs on rdb/hdb?
rdbQuery:{[tab;t1;t2;s]
    // "select from tab where time within (t1;t2), sym=s"
    // Default to all syms when not provided
    w:enlist (within;`time;(t1;t2));
    if[not null s;w:w,enlist (=;`sym;enlist s)];
    // IPC with parse tree
    RDB_H (?;tab;w;0b;())
 };

// Wrapper of rdbQuery for REST endpoint
rdbREST:{
    .dbg.rdb:`time`inputs!(.z.p;x);
    rdbQuery . value x[`arg]
 };

.log.info["Initialising REST server"];

// REST server config
.rest:use`kx.rest;
// Init with autobind enabled
.rest.init enlist[`autoBind]!enlist[1b];

// Register endpoints
/TODO: investigate POST requests, json bodies

// RDB Query
.endpoints.rdb:(!). flip (
    (`request; `get);
    (`endpoint; "/rdb");
    (`description; "Query data in the RDB");
    (`qFunc; rdbREST);
    (
        `params; 
        .rest.reg.data[`tab;-11h;1b;`trade;"Table to query"],
        .rest.reg.data[`t1;-17h;0b;00:00;"Lower time bound"],
        .rest.reg.data[`t2;-17h;0b;23:59;"Upper time bound"],
        .rest.reg.data[`s;-11h;0b;`;"Sym to filter for"]
    )
 );

.log.info["Registering endpoints:\t",.j.j value 1_.endpoints[;`endpoint]];
.rest.register . value .endpoints.rdb;

/TODO: log hostname to show full endpoint?
.log.info[("Successfully initialised GW at port [%s]";`long$first system"p")];
/
.rest.register[`get;
    // Endpoint
    "/rdb";
    // Description
    "Query data in the RDB";
    // q function
    rdbREST;
    // Parameter registration
    //  - name, type, required flag, default, description
    .rest.reg.data[`tab;-11h;1b;`trade;"Table to query"],
    .rest.reg.data[`t1;-17h;0b;00:00;"Lower time bound"],
    .rest.reg.data[`t2;-17h;0b;23:59;"Upper time bound"],
    .rest.reg.data[`s;-11h;0b;`;"Sym to filter for"]
 ];


// Example curls

// curl 'localhost:<gwPort>/rdb'
// {"code":"400","text":"missing","details":"tab"}

// curl 'localhost:<gwPort>/rdb?tab=trade'
// <json object of all trade data in rdb>

// curl 'localhost:<gwPort>/rdb?tab=trade&t1=15:34&t2=15:35'
// <json object of trade data in rdb within 15:34 and 15:35>

// curl 'localhost:<gwPort>/rdb?tab=trade&t1=15:34&t2=15:35&s=MSFT'
// <json object of trade data in rdb within 15:34 and 15:35 matching sym=`MSFT>