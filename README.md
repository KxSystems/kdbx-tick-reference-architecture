# x-starter
Repository for a template for KDB-X tick architecture.

## Usage
### Config
The following configuration steps are required before being able to run the tick processes:
* Create a `.env` file within the repo with the following variables defined:

    | Variable        | Example Value                    | Description                                                                                                    |
    |-----------------|----------------------------------|----------------------------------------------------------------------------------------------------------------|
    | SCHEMA_DIR      | /path/to/data/directory/schemas  | A path to a directory which contains one or more .q files containg schemas of tables to be used by the system. |
    | TPLOG_DIR       | /path/to/data/directory/tplogs   | A path to a directory to store the tickerplant log files in.                                                   |
    | HDB_DIR         | /path/to/data/directory/hdb      | A path to a directory to store the data to on disk.                                                            |
    | PROCESS_LOG_DIR | /path/to/data/directory/proclogs | A path to a directory to store process logs in.                                                                |
    | TICK_PORT       | 5010                             | An available port to run the tickerplant process on.                                                           |
    | RDB_PORT        | 5011                             | An available port to run the realtime database process on.                                                     |
    | HDB_PORT        | 5012                             | An available port to run the historical database process on.                                                   |
    | GW_PORT         | 5013                             | An available port to run the gateway process on.                                                               |
* Create a `.q` file in `SCHEMA_DIR` containing schemas of tables to be used by the system. Multiple schema files can be used.
* Create the `TPLOG_DIR`, `HDB_DIR`, and `PROCESS_LOG_DIR` directories.
* Ensure the `startup.sh` and `shutdown.sh` scripts are executable.

### Start
To run the system simply run the startup script:
```
$ cd x-starter
$ ./startup.sh
```

### Stop
To stop the system run the shutdown script:
```
$ cd x-starter
$ ./shutdown.sh
```

### Monitoring
When running the expected behaviour is that 4 separate q processes are running in the background. These can be identified by the `-procName` flag used when starting the individual q sessions. For example:
<pre>
$ ps aux | grep  "q*-procName TP\|RDB\|HDB\|GW" | grep -v "grep"

user      72685  0.0  0.0  86300  6144 pts/4    Sl+  15:55   0:00 q kdb-tick/tick.q -p 5010 -schemaDir /path/to/data/directory/schemas -tplogDir /path/to/data/directory/tplogs <mark>-procName TP</mark>
user      72686  0.0  0.0  86164  6144 pts/4    Sl+  15:55   0:00 q kdb-tick/r.q -p 5011 -tplogDir /path/to/data/directory/tplogs -hdbDir /path/to/data/directory/hdb -tpPort :5010 -hdbPort :5012 <mark>-procName RDB</mark>
user      72687  0.0  0.0  86300  6016 pts/4    Sl+  15:55   0:00 q /path/to/data/directory/hdb -p 5012 <mark>-procName HDB</mark>
user      72688  0.0  0.0 226456  9728 pts/4    Sl+  15:55   0:00 q gw.q -p 5013 -rdbPort 5011 -hdbPort 5012 <mark>-procName GW</mark>
</pre>