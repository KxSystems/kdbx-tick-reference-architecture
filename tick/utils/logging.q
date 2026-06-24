// initialize log library
.logger:use`kx.log;
.log:.logger.createLog[];

// Add custom logic
.log.fileHandle:()!();

// initialize the log file
//  - proc == string to prepend to log file name
//      .e.g "Tickerplant"
//  - dt == datetime to append to log file name
//      .e.g .z.z
.log.initFile:{[proc;dt]
    // Define log file based on current time and sanitise file name
    timeStr:ssr[;;""]/[string dt;(".";":")];
    // Default to app/proclogs when PROCESS_LOG_DIR is unset
    dir:$[count d:getenv`PROCESS_LOG_DIR; d; "app/proclogs"];

    system "mkdir -p \"",dir,"\"";
    fp:hsym `$dir,"/",proc,"_",timeStr,".log";
    // Remove default output to stderr/stdout (1/2) and replace with log file
    // TODO: review this method
    .log.remove[1;`trace`debug`info`warn];
    .log.remove[2;`error`fatal];
    // Open handle and add custom file to log sinks
    h:hopen fp;
    // Store file handle and date for rollover management
    .log.fileHandle[h]:"D"$first "T" vs timeStr;
    .log.add[h;`trace`debug`info`warn`error`fatal];
 };

// Rollover the log file to a new date
//  - proc == string to prepend to log file name
//            .e.g "Tickerplant"
//  - d    == date to set new log file name to
//            .e.g .z.d+1
.log.rollover:{[proc;d]
    // Remove previous log file from sinks
    h:first key .log.fileHandle;
    .log.remove[h;`trace`debug`info`warn`error`fatal];
    // Close handle to previous file
    hclose h;
    .log.fileHandle:()!();
    // Set new log file to be new day
    .log.initFile[proc;`datetime$d];
 };

// Add rollover to timer (if loaded)
if[count key `.timer;
    .timer.funcs[`loggingRoller]:{[]
        // If logging file date is still yesterday, roll to today
        if[first[value .log.fileHandle]=.z.d-1;
            .log.rollover[first CLI_ARGS[`procName];.z.d]
        ];
    };
 ];

// Show the q command that was run to start the current process.
//  - proc == string to prepend to log line
//      .e.g "Tickerplant"
.log.procStarted:{[proc] .log.info proc," started using command:\t ", " " sv .z.X};