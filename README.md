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

Further examples can be found within the Appendix.

### Start
To run the system simply run the startup script:
```
$ cd x-starter
$ ./startup.sh
```
This assumes the `.env` file is in the same directory as the `startup.sh` script. For a file stored in a different location use the `-e` flag:
```
$ cd x-starter
$ ./startup.sh -e /path/to/.env
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

user      72685  0.0  0.0  86300  6144 pts/4    Sl+  15:55   0:00 q kdb-tick/tick.q -p 5010 -schemaDir /path/to/data/directory/schemas -tplogDir /path/to/data/directory/tplogs <b>-procName TP</b>
user      72686  0.0  0.0  86164  6144 pts/4    Sl+  15:55   0:00 q kdb-tick/r.q -p 5011 -tplogDir /path/to/data/directory/tplogs -hdbDir /path/to/data/directory/hdb -tpPort :5010 -hdbPort :5012 <b>-procName RDB</b>
user      72687  0.0  0.0  86300  6016 pts/4    Sl+  15:55   0:00 q /path/to/data/directory/hdb -p 5012 <b>-procName HDB</b>
user      72688  0.0  0.0 226456  9728 pts/4    Sl+  15:55   0:00 q gw.q -p 5013 -rdbPort 5011 -hdbPort 5012 <b>-procName GW</b>
</pre>

## Logging
### Prerequisites
The following modules are required to enable logging:
* https://github.com/KxSystems/logging/tree/main
* https://github.com/KxSystems/printf

### Usage
Logging is enabled on scripts by loading the `utils/logging.q` script. This script initialises the logging module and contains additional custom logging logic.

Default usage documentation can be found at https://github.com/KxSystems/logging/blob/main/docs/reference.md

<details>
<summary>Custom API Reference</summary>

### .log.procStarted

Used to show the q command that was run to start the current process, prepending the input string to the log line.
```
q) .log.procStarted["Tickerplant"];

2026.02.26D11:35:29.519047911 info PID[<pid>] HOST[<hostname>] Tickerplant started using command:     q kdb-tick/tick.q -p 5010 -schemaDir /path/to/data/directory/schemas -tplogDir /path/to/data/directory/tplogs -procName TP
```

</details>

## Appendix
### Directory Trees
<details>
<summary>Initial Directory Tree</summary>

```
$ tree /path/to/data/directory/
.
├── hdb
├── proclogs
├── schemas
│   ├── sample-schema-file.q
│   └── second-schema-file.q
└── tplogs

5 directories, 2 files
```
</details>

<details>
<summary>Directory Tree Containing Data</summary>

```
$ tree /path/to/data/directory/
.
├── hdb
│   ├── 2026.02.18
│   │   ├── genericTab
│   │   │   ├── c1
│   │   │   ├── c2
│   │   │   ├── sym
│   │   │   └── time
│   │   ├── quote
│   │   │   ├── asize
│   │   │   ├── ask
│   │   │   ├── bid
│   │   │   ├── bsize
│   │   │   ├── ex
│   │   │   ├── mode
│   │   │   ├── sym
│   │   │   └── time
│   │   └── trade
│   │       ├── price
│   │       ├── side
│   │       ├── size
│   │       ├── sym
│   │       └── time
│   └── sym
├── proclogs
│   ├── hdb
│   ├── rdb
│   └── tp
├── schemas
│   ├── sample-schema-file.q
│   └── second-schema-file.q
└── tplogs
    ├── testSchemaName2026.02.18
    └── testSchemaName2026.02.19

9 directories, 25 files
```
</details>

### Schema Files
Note that schemas must be created with the first two columns being `time` and `sym`.
<details>
<summary>Example contents of table schemas spread across multiple files</summary>

```
$ cat schemas/sample-schema-file.q 

quote:([]time:`timespan$(); sym:`symbol$(); bid:`float$(); ask:`float$(); bsize:`long$(); asize:`long$(); mode:`char$(); ex:`char$())
trade:([]time:`timespan$(); sym:`symbol$(); price:`float$(); size:`int$(); side:())

$ cat schemas/second-schema-file.q 

genericTab:([] time:`timespan$(); sym:`symbol$(); c1:(); c2:())
```
</details>