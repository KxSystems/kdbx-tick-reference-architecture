# Tick-X Reference Architecture

## Introduction

The Tick-X Reference Architecture contains basic and scalable reference architectures and deployment instructions using KDB-X. The aim is to allow users to quickly deploy a full tickerplant system configuration to ingest & persist data into the database processes with the ability to query from both simultaneously. We also leverage the use of KDB-X modules where relevant for a slightly enhanced experience of typical Tick architecture.

Each reference architecture contains a detailed README on how to deploy the architecture and basic usage instructions. Please visit and register to the [KX Developer Center](https://developer.kx.com) for further information on KDB-X with documentation on usage, modules, walk through examples, and tutorials.

## Repository

You can find 2 different architecture configurations within this repository:

### [tick](./tick/README.md)

- basic Tick architecture with some additional customization beyond the barebones [KDB-X System Architecure](https://code.kx.com/kdb-x/how_to/manage_streaming_data/architecture.html) outlined in the KDB-X documentation
- Docker Compose project: [tick/docker](./tick/docker/README.md)
- Helm chart (single-node Kubernetes): [tick/helm](./tick/helm/README.md)

### [tick-x](./tick-x/README.md)

- An extension of base Tick that introduces an intraday database and writedown only RDB process. The main RDB is dedicated to receiving TP data and periodically flushing int-partitions to disk; a chained RDB subscribes to the TP in parallel and serves all `rdb` queries (so the writedown RDB never blocks); an IDB process loads the flushed int-partitions and serves them as the `idb` tier through the gateway
- Docker Compose project: [tick-x/docker](./tick-x/docker/README.md)
- Helm chart (single-node Kubernetes): [tick-x/helm](./tick-x/helm/README.md)

## Repository Structure

<details>
<summary>Initial Directory Tree</summary>

```
kdbx-tick-reference-architecture/
├── app/
│   ├── hdb/
│   ├── idb/
│   ├── proclogs/
│   └── tplogs/
├── arch/
│   ├── tick-x.drawio.png
│   └── tick.drawio.png
├── samples/
│   ├── analytics/
│   ├── data/
│   ├── enrichments/
│   ├── schemas/
│   └── sample_env
├── tick/
│   ├── README.md
│   ├── docker/
│   │   ├── Dockerfile
│   │   ├── README.md
│   │   ├── compose.yaml
│   │   ├── example.env
│   │   ├── fh-timer.sh
│   │   └── healthcheck.q
│   ├── scripts/
│   │   ├── fh-timer.sh
│   │   ├── restart.sh
│   │   ├── shutdown.sh
│   │   └── startup.sh
│   ├── src/
│   │   ├── client.q
│   │   ├── fh.q
│   │   ├── gw.q
│   │   ├── hdb.q
│   │   ├── rdb.q
│   │   ├── rte.q
│   │   ├── tick.q
│   │   └── u.q
│   ├── tests/
│   │   ├── api-test.q
│   │   ├── e2e-test.q
│   │   └── rest-test.q
│   └── utils/
│       ├── logging.q
│       ├── main.q
│       └── timer.q
└── tick-x/
    ├── README.md
    ├── docker/
    │   ├── Dockerfile
    │   ├── README.md
    │   ├── compose.yaml
    │   ├── example.env
    │   ├── fh-timer.sh
    │   └── healthcheck.q
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


Copyright 2026 KX Systems, Inc