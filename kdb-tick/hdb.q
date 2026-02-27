// Load utility scripts
system"l utils/main.q";

.log.info["Initialising HDB"];

// Load DB
system"l ",first CLI_ARGS[`hdbDir];
.log.info[("HDB successfully initailised. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];