// tp
h:hopen 5010;
neg[h](".u.upd";`trade;(.z.n;`APPL;35.65;100;`B));
neg[h](".u.upd";`trade;(10#.z.n;10?`MSFT`AMZN;10?10000f;10?100i;10?`B`S));
/.z.ts:{[] neg[h](".u.upd";`trade;(10#.z.n;10?`MSFT`AMZN;10?10000f;10?100i;10?`1))};
/system"t 1000";

// rdb
h2:hopen 5011;

// force end of day
h ".u.endofday[]";

// shutdown processes
h "exit 0";
h2 "exit 0";