// Load utility scripts
system"l utils/main.q";

.log.info["Initialising GW"];

// Open DB connections
.log.info[enlist["Connecting to DB processes on ports [RDB: %s] and [HDB: %s]"],raze CLI_ARGS[`rdbPort`hdbPort]];
RDB_H:hopen`$"::",first CLI_ARGS[`rdbPort];
HDB_H:hopen`$"::",first CLI_ARGS[`hdbPort];

// REST server config
.log.info["Initialising REST server"];
.rest:use`kx.rest;
// Init with autobind enabled
.rest.init enlist[`autoBind]!enlist[1b];

// Load analytics
{[x]
    .log.info["Loading analytics from ",x];
    system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x;
    .log.info[("Successfully loaded analytics:\t %s";`#f)];
 }[first CLI_ARGS[`analyticsDir]];

/TODO: investigate POST requests, json bodies

// Register endpoints
.log.info["Registering endpoints:\t",.j.j value 1_.endpoints[;`endpoint]];
.rest.register ./: value value each 1_.endpoints;

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

// curl 'localhost:<gwPort>/hdb'
// {"code":"400","text":"missing","details":"tab"}

// curl 'localhost:<gwPort>/hdb?tab=trade'
// <json object of all yesterdays trade data in hdb>

// curl 'localhost:<gwPort>/hdb?tab=trade&d=2026.02.18&t1=15:34&t2=15:35'
// <json object of trade data in hdb on 18th Feb 2026 within 15:34 and 15:35>

// curl 'localhost:<gwPort>/hdb?tab=trade&d=2026.02.18&t1=15:34&t2=15:35&s=MSFT'
// <json object of trade data in hdb on 18th Feb 2026 within 15:34 and 15:35 matching sym=`MSFT>