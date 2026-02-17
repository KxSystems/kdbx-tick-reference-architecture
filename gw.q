cliArgs:.Q.opt .z.x;

rdbH:hopen`$"::",first cliArgs[`rdbPort];
hdbH:hopen`$"::",first cliArgs[`hdbPort];

// set up .z.pg/.z.pp on rdb/hdb?

// define query funcs on rdb/hdb?
// todo: add defaults?
rdbQuery:{[tab;t1;t2;s]
    // "select from tab where time within (t1;t2), sym=s"
    rdbH (?;tab;((within;`time;(t1;t2));(=;`sym;enlist s));0b;())
 };