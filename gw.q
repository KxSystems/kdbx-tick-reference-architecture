cliArgs:.Q.opt .z.x;

rdbH:hopen`$"::",first cliArgs[`rdbPort];
hdbH:hopen`$"::",first cliArgs[`hdbPort];

// set up .z.pg/.z.pp on rdb/hdb?

// define query funcs on rdb/hdb?
rdbQuery:{[tab;t1;t2]
    /rdbH"?[tab;enlist(within;`time;(t1;t2));0b;()]"
    rdbH (?;tab;enlist(within;`time;(t1;t2));0b;())
 };
