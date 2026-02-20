// Initialise log library
system"l utils/logging.q";
.log.procStarted["HDB"];

// Parse command line arguments
cliArgs:.Q.opt .z.x;

.log.info["Initialising HDB."];

// Load DB
system"l ",first cliArgs[`hdbDir];
.log.info[("HDB successfully initailised. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];