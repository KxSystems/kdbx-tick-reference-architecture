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


// ------------- REST testing ------------- //
n:10;
customers:([] id:n?10;c1:n?100f;c2:n?`1);

.db.getAllCustomers:{.dbg.x1:x;x[`arg;`cnt]#select from customers where i>=x[`arg;`i]};

.db.getCustomersById:{.dbg.x2:x;select from customers where id in x[`arg;`id]};

// Register endpoints
.rest.register[`get;
    // endpoint
    "/customers";
    // description
    "Returns all customers";
    // q function
    .db.getAllCustomers;
    // parameter register
    //  - name, type, required flag, default, description
    .rest.reg.data[`i;-6h;0b;0;"Offset to first row"],
    .rest.reg.data[`cnt;-6h;0b;10;"Number of rows to return"] 
 ];

.rest.register[`get;
    "/customers/{id}";
    "Returns one or more customers by their IDs";
    .db.getCustomersById;
    .rest.reg.data[`id;6h;1b;0;"One or more customer IDs"]
 ];

// $ curl 'localhost:8080/customers'
// $ curl 'localhost:8080/customers?i=2&cnt=2'