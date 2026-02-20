// Initialise log library
system"l utils/logging.q";
.log.procStarted["HDB"];


// Parse command line arguments
cliArgs:.Q.opt .z.x;

// Load DB
system"l ",first cliArgs[`hdbDir];