/ q IPC health / readiness probe for the compose healthchecks.
/   q healthcheck.q PORT [HOST] [Q_EXPRESSION]
/ Exits 0 only if the process accepts a connection AND the expression returns 1b.
/ With no expression it is a plain liveness check (port is accepting IPC).
/ -
/ Used instead of the image's kdbx-healthcheck, which was observed to exit 0
/ even against a closed port, so it could never mark a container unhealthy.
/ NB: never write a bare `/` comment line in q; it starts a block comment.
a:.z.x;
if[1>count a;exit 2];
host:$[1<count a;a 1;"127.0.0.1"];
query:$[2<count a;a 2;"1b"];
h:@[hopen;(`$":",host,":",a 0;2000);{0N}];
if[null h;exit 1];
r:@[h;query;{0b}];
hclose h;
if[not 1b~r;exit 1];
exit 0
