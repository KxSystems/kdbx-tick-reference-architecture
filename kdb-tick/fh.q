//Load utility scripts
system"l utils/main.q";

.log.info["Initialising FH"];

//Open connection to TP
TP_H:hopen`$"::",first CLI_ARGS[`tpPort];

//Ingest sample data
.log.info["Ingesting sample data"];
system"l ",first CLI_ARGS[`sampleData];

//Live data stimulation using timer function. Sample data is upserted to the TP every set interval
//On failure, logs error message
.z.ts:{[] 
        //
        @[.fh.upsert.data; (::); {.log.error["Upsert failed | ERROR: ", x]}];
        };

//Set timer interval
system"t ",first CLI_ARGS[`fhTimer];
.log.info[enlist["Timer interval set to every [%s] ms"],(CLI_ARGS[`fhTimer])];

.log.info["Successfully initialised FH"];