// Helper script called by reload-hdb.sh
// Usage: q utils/reload-hdb-helper.q -port 5012
// Connects to the HDB, calls .hdb.reload[], exits

port:first .Q.opt[.z.x][`port];
h:@[hopen; `$"::",port; {-2 "FAIL: ",x; exit 1}];
@[h; (`.hdb.reload;`); {-2 "FAIL: ",x; exit 1}];
hclose h;
-1 "OK";
exit 0;
