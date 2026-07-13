# Redis Sentinel Restart Recovery E2E Test

This directory contains a self-contained end-to-end test for the Sentinel failover restart-recovery logic implemented in `scripts/init.sh`.

## Scope

The test verifies that after Sentinel promotes a replica to master, running `scripts/init.sh server` in the old master's directory:

- Updates `redis-announce.conf` from the current Pod identity.
- Queries Sentinel for the current master address.
- Updates `redis-runtime.conf` so the old master rejoins the topology as a replica of the new master.

## Requirements

- Redis 7.2.14 (`redis-server`, `redis-cli`, `redis-sentinel` in `$PATH`).
- Bash.
- `vm.overcommit_memory` set to `1` is recommended so Redis background saves/replication do not fail in containerized environments.

## Directory Layout

```text
.
├── lib/
│   ├── common.sh          # shared helpers: process management, config generation, init.sh wrappers
│   └── assert.sh          # assertion helpers
├── task-01-sentinel-restart-recovery.sh
└── run.sh                 # full suite with regression
```

## Running the Test

Run the full suite (individual task + regression):

```bash
./run.sh
```

Run the task independently:

```bash
./task-01-sentinel-restart-recovery.sh
```

## Configuration

Default ports:

- master: `6390`
- replica: `6391`
- sentinel: `26390`

Override via environment variables:

```bash
TEST_MASTER_PORT=7390 TEST_REPLICA_PORT=7391 TEST_SENTINEL_PORT=27390 ./run.sh
```

## Cleanup Policy

- The task script respects `E2E_NO_CLEANUP=1` and skips cleanup.
- `run.sh` uses `E2E_NO_CLEANUP=1` during the regression phase and performs explicit cleanup between phases.
- After regression, `run.sh` asks for confirmation before the final cleanup in interactive mode.

## Notes

Because this test runs outside a Kubernetes cluster, `init.sh` is invoked with:

- `REDIS_HOST_NETWORK_PORT` and `CURRENT_POD_HOST_IP=127.0.0.1` so that
  `replica-announce-ip` / `replica-announce-port` resolve to the local Redis
  processes. This avoids depending on Kubernetes DNS while still exercising the
  real `resolve_announce_addr()` logic.
- A mocked `hostname` command in `$PATH` so `hostname -f` returns the
  deterministic Pod FQDN during the simulated old-master restart.
- A mocked `redis-cli` command in `$PATH` so Sentinel queries issued by
  `init.sh` are redirected to the local Sentinel process.

These mocks and environment overrides are scoped to the `init.sh` invocation
and do not affect the real Redis/Sentinel processes used elsewhere in the test.
