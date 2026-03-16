# x-starter
Repository for a template for KDB-X tick architecture.

## Usage
### Config
The following configuration steps are required before being able to run the tick processes:
* Create a `.env` file within the repo with the following variables defined:

    | Variable        | Example Value                    | Description                                                                                                    |
    |-----------------|----------------------------------|----------------------------------------------------------------------------------------------------------------|
    | SCHEMA_DIR      | /path/to/data/directory/schemas  | A path to a directory which contains one or more .q files containg schemas of tables to be used by the system. |
    | SAMPLE_DATA      | /path/to/data/directory/data  | A path to a directory which contains the raw data to be ingested by the system. |
    | TPLOG_DIR       | /path/to/data/directory/tplogs   | A path to a directory to store the tickerplant log files in.                                                   |
    | TPLOG_NAME      | sampleSchema                     | String to prefix to the start of the TP log file.                                                 |
    | HDB_DIR         | /path/to/data/directory/hdb      | A path to a directory to store the data to on disk.                                                            |
    | PROCESS_LOG_DIR | /path/to/data/directory/proclogs | A path to a directory to store process logs in.                                                                |
    | TICK_PORT       | 5010                             | An available port to run the tickerplant process on.                                                           |
    | RDB_PORT        | 5011                             | An available port to run the realtime database process on.                                                     |
    | HDB_PORT        | 5012                             | An available port to run the historical database process on.                                                   |
    | GW_PORT         | 5013                             | An available port to run the gateway process on.                                                               |
    | FH_PORT         | 5014                             | An available port to run the feedhandler process on.  
    | ANALYTIC_DIR    | /path/to/repo/x-starter/samples/analytics                             | A path to a directory which contains one or more .q files containing to use on the gateway as REST endpoints.                                                               |
    | PARALLEL_PORT_RANGE_START    | 5020                             | The starting port value for creating additional parallel processes.
    | FH_TIMER         | Time value in miliseconds                             | A feedhandler timer variable to stimulate automatic data ingestion.                                                               |

* Create a `.q` file in `SCHEMA_DIR` containing schemas of tables to be used by the system. Multiple schema files can be used.
* Create the `TPLOG_DIR`, `HDB_DIR`, and `PROCESS_LOG_DIR` directories.
* Ensure the `startup.sh` and `shutdown.sh` scripts are executable.

Further examples can be found within the Appendix.

### Start
To run the system simply run the startup script:
```
$ cd x-starter
$ ./startup.sh 
Starting processes on ports...
  Started TP    [5010]
  Started RDB   [5011]
  Started HDB   [5012]
  Started GW    [5013]
```
This assumes the `.env` file is in the same directory as the `startup.sh` script. For a file stored in a different location use the `-e` flag:
```
$ cd x-starter
$ ./startup.sh -e /path/to/.env
```

<details>
<summary>Additional Optional Flags</summary>

* **-s**

    Number of secondary threads to make available for each process.

    Defaults to 0.

    Reference: https://code.kx.com/q/basics/cmdline/#-s-secondary-threads

    ```
    $ cd x-starter
    $ ./startup.sh -s 4
    ```

* **-m**

    Number of additional RDB and HDB processes to start in parallel. Additional RDBs are started as "chained" which do not carry out any end of day saves or HDB reloads. The gateway will not query the main RDB when `-m` is set.

    Defaults to 0.

    Reference: https://code.kx.com/q/kb/kdb-tick/#chained-rdbs

    ```
    $ cd x-starter
    $ ./startup.sh -m 2
    ```

</details>


### Stop
To stop the system run the shutdown script:
```
$ cd x-starter
$ ./shutdown.sh 
Killed processes:
  TP     [118666]
  RDB    [118667]
  HDB    [118668]
  GW     [118669]
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

### Failover
When running multiple RDBs, they will operate with the first RDB (`RDB_MAIN`) acting as a leader and any additional RDBs (`RDB_CHAIN_x`) will start as followers. In this set up only the leader carries out end of day writes and HDB reloads, so in the event that the `RDB_MAIN` fails, the first available `RDB_CHAIN` will be triggered to become the leader. The status of leadership is tracked in the `.u.RDB_CONNECTIONS` table on the tickerplant.

_Note: If `RDB_MAIN` fails it should NOT be restarted as main and instead a new chained RDB should be started to return back to the desired number of RDB._

The gateway will only query processes available on startup, therefore if additional DB processes are started while the gateway is running it will need to be restarted to query all new DB processes.


### Querying
The gateway process takes advantage of the [REST module in KDB-X](https://code.kx.com/kdb-x/modules/rest-server/overview.html) to act as a REST server. To access the data in the system there are some default REST API endpoints available, `localhost:GW_PORT/rdb` and `localhost:GW_PORT/HDB`.

<details>
<summary>REST API Reference</summary>

### /rdb
Query data within the RDB, filtering on the `time` and `sym` columns.

Input parameters:
| Parameter | Required | Data Type     | Default Value | Description                                                 |
|-----------|----------|---------------|---------------|-------------------------------------------------------------|
| tab       | Yes      | Symbol (-11h) | trade         | Table to query.                                             |
| t1        | No       | Minute (-17h) | 00:00         | Lower time bound.                                           |
| t2        | No       | Minute (-17h) | 23:59         | Upper time bound.                                           |
| s         | No       | Symbol (-11h) | `             | Sym to filter for. No value defaults to returning all syms. |

Example Usage
```
$ curl 'localhost:<GW_PORT>/rdb'
{"code":"400","text":"missing","details":"tab"}

$ curl 'localhost:<GW_PORT>/rdb?tab=trade'
<json object of all trade data in rdb>

$ curl 'localhost:<GW_PORT>/rdb?tab=trade&t1=15:34&t2=15:35'
<json object of trade data in rdb within 15:34 and 15:35>

$ curl 'localhost:<GW_PORT>/rdb?tab=trade&t1=15:34&t2=15:35&s=MSFT'
<json object of trade data in rdb within 15:34 and 15:35 matching sym=`MSFT>
```

### /hdb
Query data within the HDB, filtering on the `date`, `time`, and `sym` columns.

Input parameters:
| Parameter | Required | Data Type     | Default Value | Description                                                 |
|-----------|----------|---------------|---------------|-------------------------------------------------------------|
| tab       | Yes      | Symbol (-11h) | trade         | Table to query.                                             |
| d         | No       | Date (-14h)   | .z.d-1        | Date to query.                                              |
| t1        | No       | Minute (-17h) | 00:00         | Lower time bound.                                           |
| t2        | No       | Minute (-17h) | 23:59         | Upper time bound.                                           |
| s         | No       | Symbol (-11h) | `             | Sym to filter for. No value defaults to returning all syms. |

Example Usage
```
$ curl 'localhost:<GW_PORT>/hdb'
{"code":"400","text":"missing","details":"tab"}

$ curl 'localhost:<GW_PORT>/hdb?tab=trade'
<json object of all yesterdays trade data in hdb>

$ curl 'localhost:<GW_PORT>/hdb?tab=trade&d=2026.02.18&t1=15:34&t2=15:35'
<json object of trade data in hdb on 18th Feb 2026 within 15:34 and 15:35>

$ curl 'localhost:<GW_PORT>/hdb?tab=trade&d=2026.02.18&t1=15:34&t2=15:35&s=MSFT'
<json object of trade data in hdb on 18th Feb 2026 within 15:34 and 15:35 matching sym=`MSFT>
```
</details>

#### Adding Endpoints
Custom analytics can be added and exposed as REST endpoints by creating `.q` scripts in the directory set by the `ANALYTIC_DIR` environmental variable. This works through use of the [.rest.register](https://code.kx.com/kdb-x/modules/rest-server/reference.html#restregister) API, which will be applied to the contents of the `.endpoints` namespace, e.g., `.endpoints.rdb` and `.endpoints.hdb`.

Therefore to expose a new endpoint, simply add a new variable to the namespace which follows the formatting of the `.endpoints` namespace.

<details>
<summary>.endpoints Namespace Format</summary>

```
.endpoints.newEndpoint:(!). flip (
    (`request; `get);
    (`endpoint; "/endpointPath");
    (`description; "Description of endpoint");
    (`qFunc; qHandlerFunction);
    (
        `params; 
        .rest.reg.data[`paramName1;paramType;requiredFlag;defaultVal;"description"],
        ... ,
        .rest.reg.data[`paramNameN;paramType;requiredFlag;defaultVal;"description"]
    )
 );
```
where `qHandlerFunction` is the q function to run on the given input parameters:
```
qHandlerFunction:{[paramName1;...;paramNameN]
    q query logic
};
```
</details>

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

### .log.rollover

Used to roll the current processes log file to a new date.
```
q) .log.rollover["TP";.z.d+1];
```

</details>

### Default Behaviour
By default the logging module will act in the following manner:
* Process logs saved to the path defined by `PROCESS_LOG_DIR` in the `.env` file.
* Log file names are in the format of `<procName>_<date>T<time>.log` where `procName` corresponds to the `-procName` flag value used in `startup.sh`.
* A `startup.log` file is created to log events ran by `startup.sh`.
* Logs use the `basic` format.
* All log levels are redirected to the process log files (trace, debug, info, warn, error, fatal).

<details>
<summary>Example Process Log Directory</summary>

```
$ ll /path/to/data/directory/proclogs
total 28
drwxr-xr-x 2 gdanc gdanc 4096 Feb 26 18:36 ./
drwxr-xr-x 6 gdanc gdanc 4096 Feb 18 15:42 ../
-rw-r--r-- 1 gdanc gdanc  475 Feb 26 18:36 GW_20260226T183617776.log
-rw-r--r-- 1 gdanc gdanc  262 Feb 26 18:36 HDB_20260226T183617776.log
-rw-r--r-- 1 gdanc gdanc  268 Feb 26 18:36 RDB_20260226T183618778.log
-rw-r--r-- 1 gdanc gdanc  519 Feb 26 18:36 TP_20260226T183617776.log
-rw-r--r-- 1 gdanc gdanc  862 Feb 26 18:36 startup.log
```

</details>

## Timers
Additional logic is added to allow for multiple separately defined functions to be called on a timer on a process (using `.z.ts`). This is done by adding functions to the `.timer.funcs` dictionary, intialised by `timer.q`. Functions added this way are expected to have null input.

<details>
<summary>Example Timer Function</summary>

```
.timer.funcs[`newFunction]:{[]
    // custom logic
};
```
</details>

The frequency of the timer is controlled by the individual processes.

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