// Load utility scripts
system"l utils/main.q";

.log.info["Initialising GW"];

// Open DB connections
.log.info[enlist["Connecting to DB processes on ports [RDB: %s] and [HDB: %s]"],CLI_ARGS[`rdbPort`hdbPort]];
/RDB_H:hopen`$"::",first CLI_ARGS[`rdbPort];
HDB_H:hopen`$"::",first CLI_ARGS[`hdbPort];
// Initialise DB connections in a table
CONNECTIONS:([]proc:`$();handle:`int$());
// Add RDB connections
/
{
    c:count h:`$"::",/:"," vs x;
    `CONNECTIONS upsert (`$"RDB_",/:string 1+til[c]),'hopen each h;
 }[first CLI_ARGS[`rdbPort]];
// Add HDB connections
{
    c:count h:`$"::",/:"," vs x;
    `CONNECTIONS upsert (`$"HDB_",/:string 1+til[c]),'hopen each h;
 }[first CLI_ARGS[`hdbPort]];
\
{[str;ports]
    c:count h:`$"::",/: ports;
    `CONNECTIONS upsert (`$str,/:string 1+til[c]),'hopen each h;
    }./:(enlist"RDB_";enlist"HDB_"),'enlist each CLI_ARGS[`rdbPort`hdbPort];

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