// Query Router
// Manages worker (QP) registration, FIFO queuing, and load-balanced query dispatch
// CLI args: -p <port> -procName QR

system"l utils/main.q";

.log.info["Initialising QR"];

// Worker registry - keyed by IPC handle
// port/rdbPort/hdbPort: the worker's own listen port and its paired RDB/HDB
// ports (used by .qr.pickFreeWorker to tell REST handlers which DB to hopen).
WORKERS:([handle:`int$()] port:`int$(); procName:`$(); rdbPort:`int$(); hdbPort:`int$(); alive:`boolean$(); inflight:`int$());

// FIFO request queue - holds requests when all workers are busy
QUEUE:([] reqID:`guid$(); gwHandle:`int$(); query:(); target:`$(); ts:`timestamp$());

// Max concurrent requests per worker. 1 = strict FIFO (no TCP buffer queuing)
MAX_PER_WORKER:1;

// Max queue depth before rejecting new requests (backpressure). Default 100, override via MAX_QUEUE_DEPTH env var
MAX_QUEUE_DEPTH:100^"J"$getenv`MAX_QUEUE_DEPTH;
.log.info[("Max queue depth set to [%s]";string MAX_QUEUE_DEPTH)];

// Round-robin counter
.qr.rrIdx:0;

// Registration - called async by QP on connect
.qr.register:{[cfg]
    .log.info[("QP registered: %r";cfg)];
    `WORKERS upsert (.z.w; cfg`port; cfg`procName; cfg`rdbPort; cfg`hdbPort; 1b; 0);
 };

// Select an idle worker (inflight < MAX_PER_WORKER) via round-robin
// Returns (::) if no alive workers exist, 0N if all alive workers are busy
.qr.selectWorker:{
    aliveH:exec handle from WORKERS where alive;
    if[0=count aliveH; :(::)];
    // Try round-robin starting from rrIdx, wrapping around
    n:count aliveH;
    idx:.qr.rrIdx mod n;
    i:0;
    while[i < n;
        h:aliveH (idx + i) mod n;
        if[MAX_PER_WORKER > WORKERS[h;`inflight];
            .qr.rrIdx:((idx + i) mod n) + 1;
            :h
        ];
        i+:1;
    ];
    // All workers busy
    0N
 };

// Dispatch query to next available worker, or queue if all busy
// Called async by GW - .z.w is the GW handle on this side
//  reqID  - guid assigned by GW
//  query  - projection (func;arg1;arg2;...) to execute on DB
//  target - `rdb or `hdb
.qr.dispatch:{[reqID;query;target]
    w:.qr.selectWorker[];
    // No alive workers at all
    if[w~(::);
        .log.warn["No available workers for request ",string reqID];
        neg[.z.w] (`.kxgw.callback; reqID; `error`msg!("No available QP workers";""));
        :()
    ];
    // All alive workers busy — check backpressure then queue
    if[null w;
        if[MAX_QUEUE_DEPTH <= count QUEUE;
            .log.warn[("Queue full (%d), rejecting reqID [%s]";count QUEUE;string reqID)];
            neg[.z.w] (`.kxgw.callback; reqID; `error`msg!("Server busy, queue full";""));
            :()
        ];
        `QUEUE insert (reqID; .z.w; query; target; .z.P);
        .log.info[("Queued reqID [%s], queue depth: %d";string reqID;count QUEUE)];
        :()
    ];
    // Worker available — dispatch immediately
    WORKERS[w;`inflight]:WORKERS[w;`inflight]+1;
    .log.info[("Dispatching reqID [%s] to worker [%r]";string reqID;WORKERS[w;`procName])];
    neg[w] (`.qp.execute; reqID; query; target);
 };

// Completion handler - called async by QP after finishing a request
// Decrements inflight and dispatches next queued request if any
.qr.complete:{[reqID]
    .log.debug[("Complete received for reqID [%s] from handle [%s], WORKERS handles: [%s]";string reqID;string .z.w;" " sv string exec handle from WORKERS)];
    if[not .z.w in exec handle from WORKERS;
        .log.warn[("Complete from unknown handle [%s] — not in WORKERS";string .z.w)];
        :()
    ];
    WORKERS[.z.w;`inflight]:WORKERS[.z.w;`inflight]-1;
    // Dispatch next queued request to this now-free worker
    if[count QUEUE;
        nxt:first QUEUE;
        delete from `QUEUE where i=0;
        WORKERS[.z.w;`inflight]:WORKERS[.z.w;`inflight]+1;
        .log.info[("Dequeuing reqID [%s] to worker [%r], remaining queue: %d";string nxt`reqID;WORKERS[.z.w;`procName];count QUEUE)];
        neg[.z.w] (`.qp.execute; nxt`reqID; nxt`query; nxt`target);
    ];
 };

// Safety: periodically reset inflight for workers that appear stuck
// If queue is empty and no requests are actively in-flight on the GW, workers should be idle
.timer.funcs[`qrInflightReset]:{[]
    stuck:select from WORKERS where alive, inflight > 0;
    if[(count stuck) and 0=count QUEUE;
        .log.warn[("Resetting %d stuck worker(s) with stale inflight counts";count stuck)];
        update inflight:0 from `WORKERS where alive, inflight > 0;
    ];
 };

// Remove timed-out or cancelled requests from the queue
// Called async by GW with a list of reqIDs to purge
.qr.dequeue:{[reqIDs]
    n:count QUEUE;
    QUEUE::delete from QUEUE where reqID in reqIDs;
    removed:n - count QUEUE;
    if[removed > 0;
        .log.info[("Dequeued %d timed-out/cancelled request(s), remaining queue: %d";removed;count QUEUE)];
    ];
 };

// Liveness - mark dead workers on disconnect
.z.pc:{[h]
    if[h in exec handle from WORKERS;
        .log.warn[("Lost connection to QP: %r";WORKERS[h])];
        WORKERS[h;`alive]:0b;
    ];
 };

// Async message handler - evaluate incoming messages with error trapping
.z.ps:{[x] @[value; x; {[e;m] .log.error[("Async error: [%s] on message: %r";e;m)]}[;x]]};

// Periodic GC to return memory to heap
.timer.funcs[`gc]:{[] .Q.gc[]};

// Set timer for logging checks
system"t 60000";

.log.info[("QR successfully initialised on port [%s]";`long$first system"p")];
