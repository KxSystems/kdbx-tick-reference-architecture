// Script to load utility scripts/variables used across multiple processes

// Parse command line arguments
CLI_ARGS:.Q.opt .z.x;

// Initialise timer library
system"l utils/timer.q";

// Initialise log library
{[x]
    system"l utils/logging.q";
    .log.procStarted[x];
    .log.initFile[x;.z.z];
 }[first CLI_ARGS[`procName]];

.z.exit:{.log.info[("%s Process ended with exit code: %r";first CLI_ARGS[`procName];x)]}