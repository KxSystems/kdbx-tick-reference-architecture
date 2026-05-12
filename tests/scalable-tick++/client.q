// Single client test - sends a sync query to GW and exits
// Usage: q tests/client.q -gwPort 5013 -target rdb -query "select from energy" -clientId 0

args:.Q.opt .z.x;

gwPort:first args`gwPort;
target:`$first args`target;
query:first args`query;
clientId:first args`clientId;

// Connect to GW
h:@[hopen; `$"::",gwPort; {-2 "Failed to connect to GW: ",x; exit 1}];

// Time the sync request
t0:.z.P;
res:@[h; (`.kxgw.query; target; query); {`error`msg!("Client error";x)}];
t1:.z.P;

elapsed:`long$(t1-t0) % 1000000;  // microseconds to milliseconds
rows:$[98=type res; count res; 0];

-1 "client[",clientId,"] | ",string[elapsed],"ms | ",string[rows]," rows";

hclose h;
exit 0;
