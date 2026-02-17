cliArgs:.Q.opt .z.x;

rdbH:hopen`$"::",first cliArgs[`rdbPort];
hdbH:hopen`$"::",first cliArgs[`hdbPort];

// set up .z.pg/.z.pp on rdb/hdb?

// define query funcs on rdb/hdb?
rdbQuery:{[tab;t1;t2;s]
    // "select from tab where time within (t1;t2), sym=s"
    // Default to all syms when not provided
    w:enlist (within;`time;(t1;t2));
    if[not null s;w:w,enlist (=;`sym;enlist s)];
    // IPC with parse tree
    rdbH (?;tab;w;0b;())
 };

// Wrapper of rdbQuery for REST endpoint
rdbREST:{
    .dbg.rdb:`time`inputs!(.z.p;x);
    rdbQuery . value x[`arg]
 };

// REST server config
.rest:use`kx.rest;
// Init with autobind enabled
.rest.init enlist[`autoBind]!enlist[1b];

// Register endpoints
/TODO: investigate POST requests, json bodies
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

// curl 'localhost:8080/rdb'
// {"code":"400","text":"missing","details":"tab"}

// curl 'localhost:8080/rdb?tab=trade'
// <json object of all trade data in rdb>

// curl 'localhost:8080/rdb?tab=trade&t1=15:34&t2=15:35'
// <json object of trade data in rdb within 15:34 and 15:35>

// curl 'localhost:8080/rdb?tab=trade&t1=15:34&t2=15:35&s=MSFT'
// <json object of trade data in rdb within 15:34 and 15:35 matching sym=`MSFT>