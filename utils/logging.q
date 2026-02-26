// Initialise log library
.logger:use`kx.log;
.log:.logger.createLog[];

// Add custom logic

// Initialise the log file
//  - proc == string to prepend to log file name
//      .e.g "Tickerplant"
.log.initFile:{[proc]
    // Define log file based on current time and sanitise file name
    timeStr:ssr[;;""]/[string .z.z;(".";":")];
    fp:hsym `$getenv[`PROCESS_LOG_DIR],"/",proc,"_",timeStr,".log";
    // Remove default output to stderr/stdout (1/2) and replace with log file
    /TODO: review this method
    .log.remove[1;`trace`debug`info`warn];
    .log.remove[2;`error`fatal];
    // Open handle and add custom file to log sinks
    .log.fileHandle:hopen fp;
    .log.add[.log.fileHandle;`trace`debug`info`warn`error`fatal];
 };

// Rollover the log file to a new date
//  - proc == string to prepend to log file name
//            .e.g "Tickerplant"
//  - d    == date to set new log file name to
//            .e.g .z.d+1
.log.rollover:{[proc;d]
    // Remove previous log file from sinks
    .log.remove[.log.fileHandle;`trace`debug`info`warn`error`fatal];
    // Close handle to previous file
    hclose .log.fileHandle;
    // Set new log file to be new day
    timeStr:ssr[;;""]/[string `datetime$d;(".";":")];
    fp:hsym `$getenv[`PROCESS_LOG_DIR],"/",proc,"_",timeStr,".log";
    .log.fileHandle:hopen fp;
    // Add new file to sinks
    .log.add[.log.fileHandle;`trace`debug`info`warn`error`fatal];
 };

// Show the q command that was run to start the current process.
//  - proc == string to prepend to log line
//      .e.g "Tickerplant"
.log.procStarted:{[proc] .log.info proc," started using command:\t ", " " sv .z.X};