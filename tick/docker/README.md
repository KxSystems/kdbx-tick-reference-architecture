# Tick on Docker Compose

Runs the [base tick reference architecture](../README.md) as a Docker Compose project built on the official KDB-X `kdbx-q` image. It starts the same six processes as `tick/scripts/startup.sh` (TP, RDB, HDB, FH, RTE, GW) with the same wiring, one container each.

## Prerequisites

- Docker with Compose v2
- A KDB-X licence (`kc.lic` or `k4.lic`) in a directory. The default is `$QLIC` if you have it set, otherwise `~/.kx`; set `QLIC` to use another directory. The directory is mounted read-only at `/run/secrets/kx` (the image's `QLIC`), so q does its normal licence search there and every file in it is visible to the containers. Point `QLIC` at a directory holding only licence files if `~/.kx` contains anything else.
- Access to the `kdbx-q` image (default `portal.dl.kx.com/kdbx-q:5.0.20260723-rocky9-r1`). Set `BASE_IMAGE` to use another variant or registry.
- Tested with `kdbx-q:5.0.20260723-rocky9-r1` (2026-10-14): all services healthy and the gateway returns data. The `kdbx-docker` project publishes Rocky Linux 9 images only, so there is no Debian variant to select.
- Network access at build time: the image build fetches the `kx.log` and `printf` modules from their [GitHub repos](https://github.com/KxSystems), since the base image only ships `kx.rest`.

## Quick start

```sh
cd tick/docker
docker compose up -d --build     # build the image and start the stack
docker compose ps                # wait for TP / HDB / RDB / GW to report healthy
curl localhost:5013/energy/rdb   # query through the gateway
docker compose down              # stop; data is kept in named volumes
```

From the repo root, add `-f tick/docker/compose.yaml` to each command instead.

## Configuration

Every setting is optional. Defaults match [`samples/sample_env`](../../samples/sample_env). To change them, copy [`example.env`](example.env) to `.env` (gitignored; Compose reads it automatically) or export the variable.

| Variable | Default | Equivalent script option |
| --- | --- | --- |
| `QLIC` | `~/.kx` | `QLIC` |
| `BASE_IMAGE` | `portal.dl.kx.com/kdbx-q:5.0.20260723-rocky9-r1` | the installed `q` |
| `SECONDARIES` | `0` | `startup.sh -s` |
| `LOG_LEVEL` | `info` | `LOG_LEVEL` |
| `TICK_PORT` `RDB_PORT` `HDB_PORT` `GW_PORT` `FH_PORT` `RTE_PORT` | `5010` `5011` `5012` `5013` `5014` `5016` | same names in `sample_env` |
| `FH_TIMER` | `60000` | same name in `sample_env` |

Every process port is published on `127.0.0.1` only (q-IPC is unauthenticated), so `tick/src/client.q` and other q clients work from the host exactly as they do with the run scripts. The GW serves q-IPC and REST on the same port. The tick and tick-x stacks use the same ports, so run one at a time (or remap ports).

## How it maps to the run scripts

| Run script | Compose |
| --- | --- |
| `startup.sh` | `docker compose up -d`. Start order is `depends_on` plus [health checks](#health-and-readiness): TP and HDB first, then RDB, FH and RTE, GW last. |
| `shutdown.sh` | `docker compose down` (add `-v` to also delete TP logs, HDB and process logs) |
| `restart.sh GW` | `docker compose restart gw` (lower-case service names: `tp rdb hdb fh rte gw`) |
| `fh-timer.sh` | `source tick/docker/fh-timer.sh`, then `start_fh_timer [ms]` / `stop_fh_timer` |
| `app/proclogs/*.log` | Process logs also go to stdout: `docker compose logs -f [service]`. The per-process files are still written to the `proclogs` volume. |
| `app/tplogs`, `app/hdb` | Named volumes `tplogs` and `hdb` |

### Volumes

| Volume | Mounted at | Why it's shared |
| --- | --- | --- |
| `tplogs` | `/opt/app/app/tplogs` in TP, RDB | The RDB replays the TP log by the path the TP reports, so the mount point is identical in both. |
| `hdb` | `/opt/app/app/hdb` in RDB, HDB | The RDB writes end-of-day partitions; the HDB serves them. |
| `proclogs` | `/opt/app/app/proclogs` everywhere | Per-process log files. |

The sample schemas and analytics are baked into the image. After editing q code or samples, run `docker compose up -d --build`.

## Health and readiness

Each service has a Compose health check that runs [`healthcheck.q`](healthcheck.q) (baked into the image) against the process's own port. It exits 0 only if the process accepts an IPC connection and, where one is given, a q expression returns `1b`. The expressions read variables the processes already keep, so no reference-architecture code is involved. `docker compose ps` shows the result, and `depends_on: condition: service_healthy` uses it to order startup.

| Service | Check | Meaning |
| --- | --- | --- |
| `tp`, `hdb` | port accepts IPC | liveness |
| `rdb`, `rte`, `fh` | `not null TP_H` | connected to the TP |
| `gw` | a live handle for each of `RDB_*`, `HDB_*` in `CONNECTIONS` | can route to every tier |

Timing: a check runs every 5s; a service is unhealthy after 3 consecutive failures (about 15s) and failures in the first 30s are ignored. Compose does not restart a container because it is unhealthy: crashes are covered by `restart: on-failure`, and the health state is for you, for `depends_on` and for any orchestrator you attach.

Recovery follows each process's own reconnect logic, so unhealthy states can last a while after a dependency returns: the GW retries its tiers every 60s, and the RDB and RTE retry the TP every 60s. `fh` never clears its TP handle, so it reports healthy after a TP outage while its publishes go nowhere.

`kdbx-healthcheck` from the base image is not used: in `kdbx-q:5.0.20260723-rocky9-r1` it exits 0 even against a closed port. Its wrapper runs `q -q -T N healthcheck.q ...`, and q only loads the script when it is the first argument, so with options in front the probe never runs. `healthcheck.q` here is invoked script-first.

## Notes

- **Endpoints use `host:port`.** The q code used to hard-code `localhost` (`::port`). `utils/main.q` now has `.main.addr`, which accepts either a bare port (localhost, as before) or `host:port`. Compose passes service names, e.g. `-tpPort tp:5010`. The run scripts are unaffected.
- **`LOG_STDOUT`** (set in `compose.yaml`) keeps the stdout/stderr log sinks so `docker compose logs` has content. Unset, behaviour is unchanged.
- **Gateway recovery.** After restarting the RDB or HDB, the GW reports "No available RDB" for up to 60s until its reconnect timer fires, same as with the run scripts.
- **Manual end of day** works as in the README: `docker compose exec tp q` then `h:hopen \`::5010; h(".u.end";.z.d)`.
- **Tests.** `tick/tests/` assume the stack shares a host with the test (they use `pgrep`, `kill` and `restart.sh`) and are not run against the containers.
- **RTE enrichment.** As with the scripts, the RTE starts with no enrichments registered.
