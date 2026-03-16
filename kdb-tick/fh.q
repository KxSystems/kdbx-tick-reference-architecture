//Load utility scripts
system"l utils/main.q";

.log.info["Initialising FH"];

//Open connection to TP
TP_H:hopen`$"::",first CLI_ARGS[`tpPort];

//Ingest sample data
.log.info["Ingesting data"];
system"l ",first CLI_ARGS[`sampleData];

//Live data stimulation
.log.info["Upserting data to TP"];
.z.ts:{[] .fh.upsert.data[]};

//Set timer to run every hour for data ingestion
system"t 60000";

.log.info["Successfully initialised FH"];

