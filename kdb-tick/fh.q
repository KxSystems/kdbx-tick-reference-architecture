//Load utility scripts
system"l utils/main.q";

.log.info["Initialising FH"];

//Open connection to TP
TP_H:hopen`$"::",first CLI_ARGS[`tpPort];

//Ingest custom data
system"l ",first CLI_ARGS[`customData];

//Live data stimulation
.z.ts:{[] .upsert.data[]};

