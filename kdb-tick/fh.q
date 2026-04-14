//Load utility scripts
system"l utils/main.q";

.log.info["Initialising FH"];

//Open connection to TP
TP_H:hopen`$"::",first CLI_ARGS[`tpPort];

//Loading FH analytics 
.log.info["Loading FH analytics"];

{[x]
        system each "l ",/:1_/:string .Q.dd[aDir;] each f:key aDir:hsym `$x       
 }(first CLI_ARGS[`fhDir]);

//Live data stimulation using timer. Sample data is upserted to the TP every set interval
//On failure, logs error message
.timer.funcs[`fhUpsert]:{[]
        .Q.trp[{value[1_.fh.upsert]@\:(::)};::; {.log.error["Upsert failed | ERROR: ", x]}];
        };

//Timer interval
system"t ",first CLI_ARGS[`fhTimer];
.log.info[enlist["Timer interval set to every [%s] ms"],(CLI_ARGS[`fhTimer])];

.log.info["Successfully initialised FH"];
