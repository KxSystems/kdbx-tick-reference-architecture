# Tick++ Reference Architecture

## Introduction

The KDB-X Tick++ Reference Architecture contains basic and scalable reference architectures and deployment instructions. The aim is to allow users to quickly deploy a full tickerplant system configuration to ingest & persist data into the database processes with the ability to query from both simultaneously. We also leverage the use of KDB-X modules where relevant for a slightly enhanced experience of typical Tick architecture.

Each reference architecture contains a detailed README on how to deploy the architecture and basic usage instructions. Please visit and register to the [KX Developer Center](https://developer.kx.com) for further information on KDB-X with documentation on usage, modules, walk through examples, and tutorials.

## Repository

You can find 2 different architecture configurations within this repository:

### [tick](./tick/README.md)

- basic Tick architecture with some additional customization beyond the barebones [KDB-X System Architecure](https://code.kx.com/kdb-x/how_to/manage_streaming_data/architecture.html) outlined in the KDB-X documentation

### [tick++](./tick++/README.md) 

- A scalable version of Tick++ that integrates realtime + batch ingestion, asynchronous query gateway, query routing, and dynamic scaling. This is an extension of the [Scalable KDB-X Architecture](https://code.kx.com/kdb-x/how_to/manage_streaming_data/kdb-tick.html) illustrated in the KDB-X docs

## Repository Structure

<details>
<summary>Initial Directory Tree</summary>

```
kdbx-tick-reference-architecture/
├── app/
│   ├── hdb/
│   ├── proclogs/
│   └── tplogs/
├── samples/
│   ├── analytics/
│   ├── data/
│   ├── enrichments/
│   ├── schemas/
│   └── sample_env
├── tick/
│   ├── README.md
│   ├── scripts/
│   │   ├── fh-timer.sh
│   │   ├── monitor.sh
│   │   ├── restart.sh
│   │   ├── shutdown.sh
│   │   └── startup.sh
│   ├── tests/
│   │   ├── api-test.q
│   │   ├── e2e-test.q
│   │   └── rest-test.q
│   ├── tick/
│   │   ├── client.q
│   │   ├── fh.q
│   │   ├── gw.q
│   │   ├── hdb.q
│   │   ├── rdb.q
│   │   ├── rte.q
│   │   ├── tick.q
│   │   └── u.q
│   └── utils/
│       ├── logging.q
│       ├── main.q
│       └── timer.q
└── tick++/
    ├── README.md
    ├── scripts/
    │   ├── fh-timer.sh
    │   ├── monitor.sh
    │   ├── restart.sh
    │   ├── shutdown.sh
    │   └── startup.sh
    ├── tests/
    │   ├── api-test.q
    │   ├── e2e-test.q
    │   └── rest-test.q
    ├── tick/
    │   ├── client.q
    │   ├── fh.q
    │   ├── gw.q
    │   ├── hdb.q
    │   ├── rdb.q
    │   ├── rte.q
    │   ├── tick.q
    │   └── u.q
    └── utils/
        ├── logging.q
        ├── main.q
        ├── rotate-logs.sh
        └── timer.q
```

</details>


Copyright 2026 KX Systems, Inc