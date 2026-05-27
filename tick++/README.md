# Tick++ Reference Architecture

A template for KDB-X tick architecture extended with an **intraday writedown** path. Base Tick's single RDB does both ingest and EOD writedown; Tick++ splits those concerns across two RDB processes and introduces an IDB process that serves the flushed data.

## Description

The architecture contained within this repository consists of the following q processes:

- **Tickerplant (TP)** — receives updates from the feedhandler and distributes them to all subscribers
- **Feedhandler (FH)** — publishes synthetic rows to the tickerplant on a timer
- **Realtime Database (RDB)** — *writedown role*. Subscribes to the tickerplant, holds today's data in memory just long enough to flush periodically to disk as int-partitions, and at EOD merges those int-partitions into the HDB date partition. Does **not** serve queries
- **Chained Realtime Database (CHAINED_RDB)** — *query role*. Subscribes to the tickerplant in parallel with the main RDB and serves all `rdb`-tier queries via the gateway. Owns no disk I/O; on `.u.end` simply clears in-memory tables (the main RDB is responsible for durability)
- **Intraday Database (IDB)** — loads the int-partitions written by the main RDB and serves the `idb` query tier. Reloads on demand when the main RDB calls `.idb.reload[]` after each flush
- **Historical Database (HDB)** — stores partitioned on-disk data, reloaded after each end-of-day save
- **Real-Time Engine (RTE)** — subscribes to the tickerplant, runs enrichment functions, and publishes derived tables back to the tickerplant
- **Gateway (GW)** — routes queries to the chained RDB / IDB / HDB and serves REST endpoints for the analytics defined in `ANALYTIC_DIR`

### Intraday Writedown Flow

```
                                               ┌──> CHAINED_RDB ──> (serves `rdb` queries)
TP ──> (sub) ──┬──> RDB ── flush every N min ──┴──> <IDB_DIR>/today/<i>/<table>/
               │                              │
               │                              └─ async signal ──> IDB.reload[] ──> (serves `idb` queries)
               │
               └ EOD: RDB merges all int-partitions into <HDB_DIR>/<date>/, signals HDB.reload[]
```

Each `FLUSH_INTV_MIN` minutes the main RDB writes rows older than `now - FLUSH_INTV_MIN` to a fresh int-partition directory under `<IDB_DIR>/today/<i>/<table>/`, drops those rows from memory, and signals the IDB to reload. At EOD the main RDB flushes any remaining in-memory rows as the final int-partition, merges every int-partition under `<IDB_DIR>/today/` into a sorted `p#sym` date partition under `<HDB_DIR>/<date>/`, clears the staging dir, and signals both the IDB (which then reads an empty staging dir) and the HDB to reload.

### Architecture Diagram

![tick++ architecture](../arch/tick++.drawio.png)

## Trade-offs vs Base Tick

Tick++ trades operational simplicity for query/ingest isolation and intraday durability. The pieces that change relative to [base tick](../tick/README.md) — and what you give up to get them — are listed below.

### What's added

| | Base `tick/` | `tick++/` |
| --- | --- | --- |
| **Processes** | 6 (TP, RDB, HDB, FH, RTE, GW) | 8 (TP, RDB, **CHAINED_RDB**, **IDB**, HDB, FH, RTE, GW) |
| **RDB role** | Single — ingest, in-memory query, and EOD writedown all on one process | Split — main RDB ingests + writes; CHAINED_RDB serves queries |
| **Writedown cadence** | Once per day (`.u.end` does the full `.Q.hdpf` from memory) | Every `FLUSH_INTV_MIN` minutes (int-partitions to `<IDB_DIR>/today/`) + EOD merge |
| **Query tiers via GW** | 2: `rdb`, `hdb` (+ `both`) | 3: `rdb`, `idb`, `hdb` (+ `all`, fans across all three tiers) |
| **Today's older data** | Sits in RDB memory until EOD; queried via `rdb` | Flushed to disk after `FLUSH_INTV_MIN` min; queried via `idb` |
| **Runtime dirs** | `app/tplogs`, `app/hdb`, `app/proclogs` | adds `app/idb/` (staging for int-partitions) |
| **Config surface** | 14 variables | adds `IDB_DIR`, `IDB_PORT`, `CHAINED_RDB_PORT`, `FLUSH_INTV_MIN` |

### Benefits

- **Query path never blocks on writedown.** In base tick, every `rdb` query competes with the RDB's ingest loop and `.Q.hdpf` at EOD. In tick++ the CHAINED_RDB is dedicated to queries — it never touches disk and the writedown-role RDB never serves a query. Tail latency on either path stays predictable.
- **Smaller RDB memory footprint at any given time.** Base tick's RDB grows monotonically all day; tick++'s main RDB sheds anything older than `FLUSH_INTV_MIN` on every flush. The same hardware can absorb a higher message rate or a longer trading day.
- **Tighter data-loss window.** A base-tick RDB crash at 3pm loses the whole day's in-memory buffer (only the TP log saves you, and a corrupt TP log is fatal). A tick++ main RDB crash loses at most one flush interval — everything older is already durable under `app/idb/today/`.
- **Today's older data is queryable.** Base tick has no way to query intraday data that's "too old to be in RDB but not yet in HDB" — that data simply doesn't exist there. Tick++'s `idb` tier covers exactly that gap.
- **Cheaper EOD.** Tick's `.u.end` is a one-shot `.Q.hdpf` of the entire day's data from RAM to disk; tick++'s EOD is a sorted merge of int-partitions that are already on disk, which is faster and lower-memory.

### Costs

- **More processes, more resources.** Two extra q processes (CHAINED_RDB, IDB) doubling the realtime memory footprint (both subscribe to TP and hold the same data) and adding their own CPU + heap.
- **Duplicated TP fan-out.** Every `upd` from the TP is sent to both the main RDB and the CHAINED_RDB. At high publish rates the TP's outbound socket work roughly doubles.
- **Continuous disk I/O.** Base tick writes to disk once per day; tick++ writes every `FLUSH_INTV_MIN` minutes. On constrained or slow storage this is the dominant cost.
- **More complex failure modes.**
  - Main RDB dies mid-flush → a partially-written int-partition under `<IDB_DIR>/today/<i>/` (use a fresh `<i>` next time; the partial dir is benign but worth cleaning manually).
  - IDB is down when the main RDB signals a reload → the IDB just keeps the stale view; the next signal (or restart) corrects it. The signal is fire-and-forget by design.
  - CHAINED_RDB falls behind the main RDB → queries return slightly stale data. The two are independent TP subscribers, so they can desync briefly under load; both will catch up.
- **Three-tier query model.** Callers need to understand the cutover between `rdb` (most recent), `idb` (today's older), and `hdb` (post-EOD). Base tick's two-tier `rdb`/`hdb` split is mentally simpler. The `all` target fans across all three tiers when callers don't want to pick — but "all of today's data" is now `rdb` + `idb` rather than just `rdb`.
- **Schema must be loaded in one more place.** Base tick loads schemas in the TP and RDB. Tick++ and scaled-tick++ adds an IDB to that list (so it has table shapes + `g#sym` before the first reload).
- **More configuration to keep in sync across scripts.** `IDB_DIR`, `IDB_PORT`, `CHAINED_RDB_PORT`, `FLUSH_INTV_MIN` must match across `startup.sh` and `restart.sh`.

### When to pick which

| Need | Choice |
| --- | --- |
| Low-volume demo or single-tenant feed, query rate modest, EOD writedown comfortably finishes in the overnight window | `tick/` |
| High publish rate, query latency SLA, want intraday durability, willing to run 2 more processes | `tick++/` |
| Need multiple read replicas or fan-out beyond one chained RDB, or want chained-RDB failover into the leader role | `scaled-tick++/` (different trade-offs again — chained replicas + leader promotion, no separate IDB) |

## Usage

### Prerequisites

The following KDB-X modules are required for full deployment of the system as they are integrated throughout the code - however, these are supplementary and are not prerequisites to the architecture itself:

- [logging](https://github.com/KxSystems/logging)
- [printf](https://github.com/KxSystems/printf)
- [kx.rest](https://code.kx.com/kdb-x/modules/rest-server/overview.html)

### Configuration

Tick++ is designed to run out-of-the-box with no per-deployment setup. All configuration is hardcoded in the scripts under `tick++/scripts/`. `tick++/scripts/startup.sh` auto-creates the runtime directories on first run.

The defaults listed below are baked into the `Configuration` block at the top of `tick++/scripts/startup.sh`:

  | Variable        | Default Value                              | Description                                                                          |
  | --------------- | ------------------------------------------ | ------------------------------------------------------------------------------------ |
  | SCHEMA_DIR      | samples/schemas                            | Directory containing one or more `.q` files with table schemas used by the system.   |
  | TPLOG_DIR       | app/tplogs                                 | Directory to store tickerplant log files (auto-created).                             |
  | TPLOG_NAME      | tpLog                                      | Prefix for the tickerplant log file name.                                            |
  | HDB_DIR         | app/hdb                                    | Directory to store on-disk partitioned HDB data (auto-created).                      |
  | IDB_DIR         | app/idb                                    | Staging directory for intraday flushes: `<IDB_DIR>/today/<i>/<table>/` (auto-created). |
  | PROCESS_LOG_DIR | app/proclogs                               | Directory to store per-process log files (auto-created).                             |
  | LOG_LEVEL       | info                                       | Default log level. Accepted: `trace`, `debug`, `info`, `warn`, `error`, `fatal`.     |
  | TICK_PORT       | 5010                                       | Port for the tickerplant process.                                                    |
  | RDB_PORT        | 5011                                       | Port for the main RDB (writedown role).                                              |
  | HDB_PORT        | 5012                                       | Port for the historical database process.                                            |
  | GW_PORT         | 5013                                       | Port for the gateway process (q-IPC and REST).                                       |
  | FH_PORT         | 5014                                       | Port for the feedhandler process.                                                    |
  | IDB_PORT        | 5015                                       | Port for the intraday database process.                                              |
  | RTE_PORT        | 5016                                       | Port for the real-time engine process.                                               |
  | CHAINED_RDB_PORT  | 5017                                       | Port for the chained RDB (query role). The gateway uses this for the `rdb` tier.     |
  | FH_TIMER        | 60000                                      | Feedhandler publish interval in milliseconds.                                        |
  | FLUSH_INTV_MIN  | 5                                          | Main RDB intraday flush interval in minutes (also the gap between IDB reload signals). |
  | ANALYTIC_DIR    | samples/analytics                          | Directory containing REST endpoint analytics `.q` files loaded by the gateway.       |

### Start

To run the system, execute the startup script from the project root:

```bash
$ ./tick++/scripts/startup.sh
Starting Tick++ Reference Architecture...
  Secondaries:      [0]
  Flush interval:   [5 min]

  Started TP        [5010]
  Started IDB       [5015]
  Started RDB       [5011]
  Started CHAINED_RDB [5017]
  Started HDB       [5012]
  Started FH        [5014]
  Started RTE       [5016]
  Started GW        [5013]

Stack started. Logs: app/proclogs/startup.log
```

<details>
<summary>Additional Optional Flags</summary>

- **-s**

  Number of secondary threads to make available for each process.

  Defaults to 0.

  Reference: https://code.kx.com/q/basics/cmdline/#-s-secondary-threads

  ```bash
  $ ./tick++/scripts/startup.sh -s 4
  ```

</details>

### Stop

To stop the system run the shutdown script from the project root:

```bash
$ ./tick++/scripts/shutdown.sh
Killing processes:
  TP     [118666]
  RDB    [118667]
  HDB    [118668]
  FH     [118669]
  RTE    [118670]
  GW     [118671]
```

### Data Ingestion

The feedhandler publishes one synthetic row each to the `energy` and `weather` tables on every timer tick. The publishing logic is a pair of direct ``neg[TP_H] (`.u.upd; <table>; <row data>)`` calls inside ``.timer.funcs[`fhUpsert]`` in `tick++/src/fh.q` — there is no parser dispatcher or analytics directory to load from. Customise by replacing the row construction with your own data source / transformation.

The interval is set by `FH_TIMER` and can be overridden at runtime using the `scripts/fh-timer.sh` script.

### Real-Time Enrichment

The RTE process starts with **no enrichments registered**. It exposes a small registration API so users can plug in their own:

- ``.rte.addEnrichment[`func; `sourceTable]`` — register a global function `func` to run when `sourceTable` publishes.
- ``.rte.addSubscription[`sourceTable; `]`` — subscribe RTE to `sourceTable` on the TP (use `` ` `` for all syms).
- ``.rte.pub[`derivedTable; rows]`` — call from inside your enrichment function to publish derived rows back to the TP.

Two ways to insert custom enrichment:

1. **At startup via `-enrichFile`** — write a `.q` file that defines + registers your enrichment (see the example below), then add `-enrichFile path/to/your-file.q` to the `rte.q` launch in `tick++/scripts/startup.sh`.
2. **At runtime via IPC** — open a handle to RTE and call the registration helpers directly ``h(`.rte.addEnrichment; `myEnrich; `weather)``.

<details>
<summary>Example Enrichment File</summary>

```q
// Define the enrichment function (global — name is passed to .rte.addEnrichment)
myEnrichment:{[data]
    derived: update heatIndex:... from data;
    .rte.pub[`derivedTable; derived];
 };

// Register the enrichment function and subscribe to the source table
.rte.addEnrichment[`myEnrichment; `weather]
.rte.addSubscription[`weather; `]
```

</details>

### Restart Individual Processes

All processes write structured logs to `PROCESS_LOG_DIR` in the format `<procName>_<datetime>.log`.

To restart a single named process without taking down the whole stack:

```bash
$ ./tick++/scripts/restart.sh GW
$ ./tick++/scripts/restart.sh RTE
```

To identify running processes:

```bash
$ pgrep -af -- -procName
```

The gateway connects to the RDB, IDB, and HDB on startup. If a process is restarted while the gateway is running, the gateway will reconnect automatically on its next timer tick (every 60 seconds).

### Querying

#### q-IPC

The gateway exposes `.kxgw.query[target; query]` for synchronous queries from q clients:

```q
gwh: hopen 5013

// Query the chained RDB (most recent in-memory data, not yet flushed)
gwh (`.kxgw.query; `rdb; "select from energy")

// Query the IDB (today's flushed int-partitions, in memory from disk)
gwh (`.kxgw.query; `idb; "select from energy")

// Query the HDB (historical, post-EOD)
gwh (`.kxgw.query; `hdb; "select from energy where date=.z.d-1")

// Fan out across all three tiers (RDB + IDB + HDB); returns `rdb`idb`hdb!(...)
gwh (`.kxgw.query; `all; "select from energy")
```

Note: the `rdb` tier is served by the chained RDB (`chainedrdb.q`), **not** the writedown-role main RDB. The main RDB never serves queries.

See `samples/analytics/endpoints-examples.q` for further examples.

#### REST

The gateway also serves REST endpoints defined by the analytics files in `ANALYTIC_DIR`. The sample analytics expose the following endpoints:

<details>
<summary>REST API Reference</summary>

### /energy/rdb

Query the energy table on the RDB (realtime data).

| Parameter | Required | Type      | Default                    | Description                  |
|-----------|----------|-----------|----------------------------|------------------------------|
| t1        | No       | Timespan  | 0D00:00:00.000000000       | Lower time bound             |
| t2        | No       | Timespan  | 0D23:59:59.999999999       | Upper time bound             |
| s         | No       | Symbol    | (all)                      | Sym filter (e.g. BLOWER78_1) |

```bash
curl "localhost:${GW_PORT}/energy/rdb"
curl "localhost:${GW_PORT}/energy/rdb?s=BLOWER78_1"
```

### /energy/hdb

Query the energy table on the HDB (historical data).

| Parameter | Required | Type      | Default  | Description           |
|-----------|----------|-----------|----------|-----------------------|
| d         | Yes      | Date      | .z.d-1   | Partition date        |
| t1        | No       | Timespan  | 0D00:... | Lower time bound      |
| t2        | No       | Timespan  | 0D23:... | Upper time bound      |
| s         | No       | Symbol    | (all)    | Sym filter            |

```bash
curl "localhost:${GW_PORT}/energy/hdb?d=2026.05.06"
```

### /energy/meta

Returns the schema of the energy table.

```bash
curl "localhost:${GW_PORT}/energy/meta"
```

### /weather/rdb, /weather/hdb, /weather/meta

Same structure as the energy endpoints, applied to the weather table.

| Parameter | Required | Type      | Default  | Description                       |
|-----------|----------|-----------|----------|-----------------------------------|
| s         | No       | Symbol    | (all)    | Location sym (e.g. `San Diego`)   |

</details>

#### Adding Endpoints

Custom analytics can be added and exposed as REST endpoints by creating `.q` scripts in `ANALYTIC_DIR`. Each script defines handler functions and registers them in the `.endpoints` namespace using `.rest.reg.data`.

<details>
<summary>.endpoints Namespace Format</summary>

```q
.endpoints.newEndpoint:(!). flip (
    (`request; `get);
    (`endpoint; "/endpointPath");
    (`description; "Description of endpoint");
    (`qFunc; qHandlerFunction);
    (
        `params;
        .rest.reg.data[`paramName1; paramType; requiredFlag; defaultVal; "description"],
        .rest.reg.data[`paramNameN; paramType; requiredFlag; defaultVal; "description"]
    )
 );
```

The handler function receives the parameters as positional arguments:

```q
qHandlerFunction:{[paramName1; ...; paramNameN]
    .restgw.query[`rdb; (?; `myTable; ...; 0b; ())]
 };
```

Use `.restgw.query` within analytics handlers — it is aliased to `.kxgw.query` in the GW.

</details>

## Logging

### Usage

Logging is enabled on all processes by loading `utils/logging.q` (via `utils/main.q`). This initializes the `kx.log` module and redirects output to a per-process log file.

Default usage documentation can be found at https://github.com/KxSystems/logging/blob/main/docs/reference.md

<details>
<summary>Custom API Reference</summary>

### .log.procStarted

Logs the q command used to start the current process.

```q
q) .log.procStarted["Tickerplant"];
2026.05.06D09:07:36.465107038 info PID[71505] HOST[hostname] TP started using command: q tick++/src/tick.q ...
```

### .log.rollover

Rolls the current process log file to a new date.

```q
q) .log.rollover["TP"; .z.d+1];
```

</details>

### Default Behaviour

- Process logs are saved to `PROCESS_LOG_DIR` (default `app/proclogs/`).
- Log file names follow the format `<procName>_<datetime>.log`.
- A `startup.log` file is created by `scripts/startup.sh`.
- All log levels (trace, debug, info, warn, error, fatal) are written to the process log file.

<details>
<summary>Example Process Log Directory</summary>

```bash
$ ls app/proclogs/
FH_20260506T090736457.log
GW_20260506T090736411.log
HDB_20260506T090736461.log
RDB_20260506T090737390.log
RTE_20260506T090736460.log
TP_20260506T090736465.log
startup.log
```

</details>

### Log level

The default log level is `info` (set in the `Configuration` block of `tick++/scripts/startup.sh` as `LOG_LEVEL`, which is exported so q reads it via `getenv`). It can be overridden per-process in two ways:

| Method | Example | Scope |
|--------|---------|-------|
| Edit `LOG_LEVEL` in `tick++/scripts/startup.sh` | `LOG_LEVEL="debug"` | All processes launched by the script |
| CLI arg `-logLevel` | `q tick++/src/rte.q ... -logLevel debug ...` | One process (takes precedence over env) |

Accepted values: `trace`, `debug`, `info`, `warn`, `error`, `fatal`. Anything else logs a `warn` on startup and the level stays at `info`. When the effective level is not `info`, the process logs `Log level set to [<level>]` as its first info line.

## Timers

Additional logic allows multiple separately-defined functions to be called on a single timer (`.z.ts`) per process. Functions are added to the `.timer.funcs` dictionary, initialized by `utils/timer.q`.

<details>
<summary>Example Timer Function</summary>

```q
.timer.funcs[`newFunction]:{[]
    // custom logic
};
```

</details>

## FH Timer Script

`scripts/fh-timer.sh` must be sourced to expose two functions for dynamic timer control. Both functions open and close an IPC connection inline, allowing interval adjustments at runtime without restarting the FH process.

```bash
source ./tick++/scripts/fh-timer.sh
start_fh_timer   # enable ingest at $FH_TIMER ms intervals
stop_fh_timer    # pause ingest
```

## Testing

An end-to-end test suite is provided at `tests/e2e-test.q`. It covers data ingestion, q-IPC and REST queries, EOD, and operational scripts. Run it from the project root after starting the stack:

```bash
q tick++/tests/e2e-test.q -gwPort 5013 -tpPort 5010 -fhPort 5014 -procName e2e
```

Results are written to `app/proclogs/e2e_<datetime>.log` in the same structured format as all other process logs.

## Appendix

### Directory Trees

<details>
<summary>Initial Directory Tree</summary>

```
tick++/
├── README.md
├── scripts/
│   ├── fh-timer.sh
│   ├── restart.sh
│   ├── shutdown.sh
│   └── startup.sh
├── src/
│   ├── client.q
│   ├── fh.q
│   ├── gw.q
│   ├── hdb.q
│   ├── idb.q
│   ├── rdb.q
│   ├── chainedrdb.q
│   ├── rte.q
│   ├── tick.q
│   └── u.q
├── tests/
│   ├── api-test.q
│   ├── e2e-test.q
│   └── rest-test.q
└── utils/
    ├── logging.q
    ├── main.q
    └── timer.q
```

</details>

<details>
<summary>Directory Tree Containing Data</summary>

```
app/
├── hdb/
│   ├── 2026.05.06/
│   │   ├── energy/
│   │   │   ├── consumption
│   │   │   ├── date
│   │   │   ├── sym
│   │   │   ├── time
│   │   │   └── timeWindow
│   │   ├── weather/
│   │   │   ├── dateTime
│   │   │   ├── humidity
│   │   │   ├── precipitation
│   │   │   ├── sym
│   │   │   ├── temp
│   │   │   ├── time
│   │   │   └── windSpeed
│   │   └── weatherHeatIndex/
│   │       ├── dateTime
│   │       ├── heatIndex
│   │       ├── sym
│   │       └── time
│   └── sym
├── proclogs/
│   ├── GW_<datetime>.log
│   ├── RDB_<datetime>.log
│   └── ...
└── tplogs/
    └── tpLog<date>
```

</details>

### Schema Files

Schemas must have `time` and `sym` as the first two columns.

<details>
<summary>Example schema file</summary>

```q
energy:([] time:`timespan$(); sym:`symbol$(); date:`date$(); timeWindow:`time$(); consumption:`float$())
weather:([] time:`timespan$(); sym:`symbol$(); dateTime:`datetime$(); temp:`float$(); humidity:`float$(); precipitation:`float$(); windSpeed:`float$())
weatherHeatIndex:([] time:`timespan$(); sym:`symbol$(); dateTime:`datetime$(); heatIndex:`float$())
```

</details>

### Sample Data

The sample data used is a mixture of CSV and PDF files. Custom parsers normalise the sample data to match the TP schema.

<details>
<summary>Sample Data Directory Tree</summary>

```
samples/data/
├── fh-analytics/
│   └── parse-structured-data.q
├── structured/
│   └── *.csv
└── unstructured/
    └── *.pdf
```

</details>

<details>
<summary>Sample Files Reference</summary>

**Structured**

- https://www.kaggle.com/datasets/vitthalmadane/energy-consumption-time-series-dataset/data?select=KwhConsumptionBlower78_1.csv
- https://www.kaggle.com/datasets/prasad22/weather-data

**Unstructured**

- https://www.gov.uk/government/statistics/energy-chapter-1-digest-of-united-kingdom-energy-statistics-dukes

</details>
