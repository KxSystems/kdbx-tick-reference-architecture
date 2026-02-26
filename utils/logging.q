// Initialise log library
.logger:use`kx.log;
.log:.logger.createLog[];

// Add custom logic

// Initialise the log file
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

// Show the q command that was run to start the current process.
//  - proc == string to prepend to log line
//      .e.g "Tickerplant"
.log.procStarted:{[proc] .log.info proc," started using command:\t ", " " sv .z.X};