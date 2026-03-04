// Load utility scripts
system"l utils/main.q";

.log.info["Initialising GW"];

// Identify whether to connect to main or chained RDBs
RDB_PORTS:$[()~CLI_ARGS[`crdbPort];
    CLI_ARGS[`rdbPort];
    CLI_ARGS[`crdbPort]
 ];

// Initialise DB connections in a table
.log.info[enlist["Connecting to DB processes on ports [RDB: %s] and [HDB: %s]"],(RDB_PORTS;CLI_ARGS[`hdbPort])];
CONNECTIONS:([]proc:`$();handle:`int$());
{[str;ports]
    c:count h:`$"::",/: ports;
    `CONNECTIONS upsert (`$str,/:string 1+til[c]),'hopen each h;
 }./:(enlist"RDB_";enlist"HDB_"),'enlist each (RDB_PORTS;CLI_ARGS[`hdbPort]);

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