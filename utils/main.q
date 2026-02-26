// Script to load utility scripts/variables used across multiple processes

// Parse command line arguments
CLI_ARGS:.Q.opt .z.x;

// Initialise log library
{[x]
    system"l utils/logging.q";
    .log.initFile[x];
    .log.procStarted[x];
 }[first CLI_ARGS[`procName]];