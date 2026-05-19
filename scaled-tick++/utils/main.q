// Script to load utility scripts/variables used across multiple processes

// Parse command line arguments
CLI_ARGS:.Q.opt .z.x;

// Initialise timer library
system"l scaled-tick++/utils/timer.q";

// Initialise log library
{[x]
    system"l scaled-tick++/utils/logging.q";
    .log.procStarted[x];
    .log.initFile[x;.z.z];
 }[first CLI_ARGS[`procName]];

// Log level - default is info. Override via:
//   - env var LOG_LEVEL=debug (or trace, warn, error, fatal)
//   - CLI arg -logLevel debug (takes precedence over env)
// Accepted: `trace`debug`info`warn`error`fatal (kx.log levels).
// Anything else is rejected with a warning and the level stays at info.
.main.validLevels:`trace`debug`info`warn`error`fatal;
{[]
    raw:$[`logLevel in key CLI_ARGS; first CLI_ARGS[`logLevel];
          0<count getenv`LOG_LEVEL; getenv`LOG_LEVEL;
          "info"];
    lvl:`$raw;
    if[not lvl in .main.validLevels;
        .log.warn[("Invalid log level [%s] - accepted: %s. Defaulting to info";
            raw; " " sv string .main.validLevels)];
        lvl:`info;
    ];
    if[lvl<>`info;
        .log.setlvl[lvl];
        .log.info[("Log level set to [%s]"; string lvl)];
    ];
 }[];

.z.exit:{.log.info[("%s Process ended with exit code: %r";first CLI_ARGS[`procName];x)]}