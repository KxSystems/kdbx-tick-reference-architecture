// Load utility scripts
system"l tick/utils/main.q";

.log.info["Initialising HDB"];

// Load DB
system"l ",first CLI_ARGS[`hdbDir];

// Reload HDB from disk - can be called via IPC to pick up data changes
.hdb.reload:{[]
    .log.info["Reloading HDB from disk"];
    system "l .";
    .log.info[("HDB reloaded. Tables [%s] from [%s]";`#tables[];first system"pwd")];
    `ok
 };

// Evaluates incoming async messages (required for receiving TP upd calls)
.z.ps:{value x};

// Set timer to run every minute for logging checks
system"t 60000";

.log.info[("HDB successfully initialised. Loaded tables [%s] from [%s]";`#tables[];first system"pwd")];
