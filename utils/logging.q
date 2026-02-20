// Initialise log library
.logger:use`kx.log;
.log:.logger.createLog[];

// Show q command run to start the current process.
//  - proc == string to prepend to log line
//      .e.g "Tickerplant"
.log.procStarted:{[proc] .log.info proc," started using command:\t ", " " sv .z.X};