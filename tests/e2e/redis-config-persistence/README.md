# Redis Config Persistence E2E Tests

This directory contains minimal end-to-end tests for the Redis/Sentinel config persistence mechanism described in `docs/research/redis-config-persistence-analysis.md`.

## Scope

The tests verify that, with Redis 7.2.14:

- `CONFIG REWRITE` only modifies the writable runtime config file and does not pollute the read-only static template included via `include`.
- `replicaof` and `masterauth` are persisted in the runtime config file and survive a replica restart.
- Sentinel writes `known-replica` and `config-epoch` to `sentinel.conf` and recovers topology after restart.

ACL file persistence and the "template-as-main-file" anti-pattern are out of scope.

## Requirements

- Redis 7.2.14 (`redis-server`, `redis-cli`, `redis-sentinel` in `$PATH`).
- Bash.
- `vm.overcommit_memory` set to `1` is recommended so Redis background saves/replication do not fail in containerized environments.

## Directory Layout

```text
.
├── lib/
│   ├── common.sh          # shared helpers: process management, config generation, wait loops
│   └── assert.sh          # assertion helpers
├── task-01-maxmemory-config-rewrite.sh
├── task-02-redis-replica-config-persistence.sh
├── task-03-sentinel-persistence.sh
├── run-all.sh             # full suite with regression
└── README.md
```

## Running Individual Tasks

Each task is an independent Bash script and cleans up after itself on success or failure:

```bash
./task-01-maxmemory-config-rewrite.sh
./task-02-redis-replica-config-persistence.sh
./task-03-sentinel-persistence.sh
```

## Running the Full Suite

```bash
./run-all.sh
```

`run-all.sh` performs:

1. Runs `task-01`, `task-02`, and `task-03` individually (each self-cleans).
2. Performs an explicit full cleanup.
3. Runs all three tasks again as a regression test, this time without cleanup.
4. Prompts you before the final cleanup so you can inspect processes and `/tmp/redis-cfg-e2e-*/` files.

## Configuration

Default ports:

- master: `6379`
- replica: `6380`
- sentinel: `26379`

Override via environment variables:

```bash
TEST_MASTER_PORT=7379 TEST_REPLICA_PORT=7380 TEST_SENTINEL_PORT=27379 ./run-all.sh
```

## Cleanup Policy

- Each task script respects `E2E_NO_CLEANUP=1` and skips cleanup.
- `run-all.sh` uses `E2E_NO_CLEANUP=1` during the regression phase and performs explicit cleanup between phases.
- After regression, `run-all.sh` asks for confirmation before the final cleanup in interactive mode.
