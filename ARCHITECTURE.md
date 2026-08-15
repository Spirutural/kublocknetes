# kublocknetes — architecture

A Kubernetes-shaped control plane for OpenComputers, targeting GT:NH.

## Why Kubernetes, specifically

Not for compute pooling. OpenComputers cannot pool RAM — every machine is an
isolated Lua VM with a hard ceiling, and no upgrade changes that. Anything
promising a shared heap across nodes is lying.

The reason to copy Kubernetes is **level-triggered reconciliation**.
Controllers do not react to events. They observe actual state, diff it
against desired state, and act — repeatedly, forever.

In a datacenter that is good hygiene. In Minecraft it is the only thing that
works, because every failure mode here is a *lost edge* that leaves a
*perfectly readable level*:

| Failure | Edge-triggered result | Level-triggered result |
|---|---|---|
| Modem queue overflows, packet vanishes | Work never happens | Next sweep sees the gap, redoes it |
| Chunk unloads mid-operation | Half-finished state, no error | Next sweep finishes it |
| Player breaks a block | Silent divergence forever | Next sweep reports or repairs |
| Power browns out | Job lost | Job rescheduled |
| Node halts | Its workloads are gone | Workloads reschedule elsewhere |

Every one of those is free if you reconcile, and a bespoke error-handling
path if you do not. That is the entire argument.

The corollary shapes all the code: **no operation may assume it ran, and
every operation must be safe to run again.** Retries are normal. Duplicates
are normal. Doing nothing this pass is normal.

## Object model

State lives in the API server as versioned objects. Controllers watch and
reconcile. Nothing else holds authoritative state.

| Object | Purpose |
|---|---|
| `Node` | A machine: capacity, advertised components, conditions, lease |
| `Pod` | Unit of work: code ref, args, resource requests, node selector |
| `Deployment` | N replicas of a pod template, anywhere that fits |
| `DaemonSet` | One pod per node matching a selector |
| `CronJob` | Periodic pod (harvest, sweep, restock) |
| `ConfigMap` | Configuration, decoupled from code |
| `Service` | Stable name resolving to a node address and port |
| `Lease` | Liveness heartbeat, separate from the Node object |
| `Event` | Observability ring buffer |

`DaemonSet` and `CronJob` are the ones that earn their keep here. "Run the
hive tender on every node with a transposer" and "harvest every 8 minutes"
describe most base automation directly.

The endgame is custom resources — `Crop`, `Hive`, `Multiblock` — with
controllers reconciling them. `kubectl apply -f farm.lua` and a controller
keeps your IC2 crops watered is the actual product. Compute distribution is
plumbing underneath it.

## Components

```
                   ┌──────────────────────────────┐
                   │        control plane         │
                   │  apiserver  (:6443)          │
                   │  scheduler                   │
                   │  controllers                 │
                   │  store  → RAID (WAL + state) │
                   └──────────────┬───────────────┘
                                  │ wired, in-rack
              ┌───────────────────┼───────────────────┐
              │                   │                   │
        ┌─────┴─────┐       ┌─────┴─────┐       ┌─────┴─────┐
        │  kubelet  │       │  kubelet  │       │  kubelet  │
        │  (:10250) │       │           │       │           │
        └───────────┘       └───────────┘       └─────┬─────┘
          worker              worker                  │ wireless
                                                ┌─────┴─────┐
                                                │  kubelet  │
                                                │ edge node │
                                                │ transposer│
                                                │ redstone  │
                                                └───────────┘
```

Ports are the real Kubernetes ones (`6443` apiserver, `10250` kubelet)
because they are self-documenting and the joke costs nothing.

## Scheduling

The scheduling currency is **bytes of free memory**, because that is what
actually runs out.

- A pod declares `requests.memory`.
- A kubelet admits it only if
  `freeMemory - reserved - Σ(admitted requests) ≥ request`.
- The scheduler bin-packs, filtered by `nodeSelector` against the
  components a node advertises.

Isolation is soft. One Lua VM per node means a greedy pod can OOM its
neighbours — there is no cgroup. Mitigations, in order of usefulness:

1. **Ballast.** The kubelet holds a pre-allocated block it can release on
   memory pressure, giving it enough headroom to report the failure and
   restart cleanly instead of dying silently.
2. **Single-tenant nodes for heavy work.** Cheaper than the failure.
3. **Hard fencing.** See below.

## Fencing

A pod that allocates without yielding takes its node down, and no software
watchdog on that node survives to fix it. So fencing must be *out of band*:
run each node's power through a redstone-controlled feed the control plane
can toggle. That is an IPMI power cycle, and it is the difference between a
cluster that self-heals and one you walk to.

## Transport

`lib/wire.lua` — framing. `lib/transport.lua` — RPC.

Three OC facts drive the design:

1. **Packets are size-capped** (typically 8192 bytes) with a cap on values
   per send. Messages are chunked and reassembled.
2. **Signal queues are bounded** (typically 256) and overflow **silently**.
   There is no error anywhere. Reassembly therefore assumes chunks arrive
   out of order, duplicated, or never, and never grows unboundedly waiting.
3. **Indirect component calls cost a tick each.** Any loop touching a
   component per iteration is far more expensive than it looks.

Retry is whole-message rather than per-chunk: a chunk lost to queue overflow
almost certainly took its siblings with it, so chunk-level acknowledgement
buys little for a round trip per 8KB. Servers cache their last N responses by
request id, so retrying a request that already ran replays the answer instead
of executing the handler twice — this is what makes non-idempotent handlers
safe. And `call` pumps the event loop while waiting, so two nodes calling
each other simultaneously do not deadlock.

## Simulator

`sim/oc.lua` runs many virtual OC machines in one host Lua process. Each is a
coroutine with its own sandbox, its own `component`/`computer`/`event`, and
its own bounded queue. Time is virtual, so a ten-minute cluster test runs in
milliseconds.

It reproduces the failure modes that matter: oversized packets rejected at
send, full queues dropping silently, and configurable in-flight loss — all
seeded and deterministic, because a flaky-network test you cannot replay is
worse than no test.

**It does not simulate real Lua memory.** Per-node memory is a number the
test sets, not a measurement. Good enough to exercise scheduler logic; it
will never catch a genuine OOM. Only the game can tell you that.

## Roadmap

- [x] **0 — Probe.** Inventory real hardware and real API signatures.
- [x] **1 — Transport.** Chunked, retried, deduplicated RPC. Simulator.
- [ ] **2 — Store + apiserver.** Versioned objects, WAL, list/watch.
- [ ] **3 — kubelet.** Registration, leases, capacity, pod admission.
- [ ] **4 — Scheduler + Deployment/DaemonSet controllers.**
- [ ] **5 — kubectl.** get / describe / apply / logs.
- [ ] **6 — Workload controllers.** CronJob, custom resources.
- [ ] **7 — Fencing + observability.**

## Open questions

Answered by running `probe/probe.lua` in-game:

- OpenComputers version, and whether OpenOS ships the `thread` API — decides
  whether pods can be coroutines or need a hand-rolled loop over `pullSignal`.
- Real `maxPacketSize` and values-per-send cap.
- T3 server rack capacity: RAM slots, CPU tier, component buses.
- Which component calls are direct vs indirect.
