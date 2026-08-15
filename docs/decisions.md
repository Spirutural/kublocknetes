# Decisions

Architectural decisions and why, so they don't get relitigated from memory.

---

## ADR-0001 — Node runtime: OpenOS now, thin nodes after observability

**Status:** accepted, 2026-08-15
**Supersedes:** the informal "keep OpenOS, memory isn't the constraint" position

### Context

Should nodes run OpenOS, or a custom minimal runtime booted from EEPROM?

OpenOS costs roughly 400 KB of a 1.5 MB machine — measured on a workstation
with GPU, screen, keyboard and an interactive shell, so the headless figure
is unknown and likely lower. See [hardware.md](hardware.md).

An early objection — that a custom runtime would cost us the `kbi` deploy
loop and force hand-typing Lua — **was wrong**. A single OpenOS workstation
flashes EEPROMs via `eeprom.set()` and writes disks through a disk drive
component. Code distribution is solved regardless of what nodes run.

Two further objections were weaker than first stated:

- **`thread`** — the hard parts of OpenOS's implementation (process
  hierarchy, kill semantics, shell interaction) are ones we don't need. A
  kubelet's cooperative scheduler is on the order of 80 lines.
- **`filesystem`** — mostly buys mount points and path canonicalization. A
  node with one disk, or none, is fine on raw `component.filesystem`.

### Arguments for a custom runtime

1. **Recovery latency.** The cluster reboots constantly — chunk unloads,
   brownouts, fencing. A fleet netbooting a small EEPROM payload returns in a
   tick; a fleet booting OpenOS does not. For a system whose premise is
   self-healing, recovery time is a first-class metric.

2. **A stable memory floor.** This is correctness, not preference. OpenOS
   lazy-loads through `require`, so a node's baseline drifts as it runs. A pod
   can pass admission against measured free memory and then OOM because a
   library loaded afterwards. **Admission control against a moving floor is
   admission control that lies.**

   Mitigable under OpenOS by warming every library at kubelet start and
   treating the post-warm figure as capacity — but that is a workaround. A
   minimal runtime has a fixed floor by construction.

3. **Materials.** An edge node that reads a transposer and sends a packet
   needs a T1 case, a modem and an EEPROM — not a T3 case, an HDD and an
   OpenOS floppy. In GT:NH that is the difference between 3 edge nodes and 20.

### Arguments against, right now

1. **The shell is currently load-bearing.** There is no `kubectl logs`, no
   event stream, no node conditions. Removing the shell before building its
   replacement leaves the first mysterious failure with no diagnostic path.

2. **Opportunity cost.** Hours spent on a bootloader are hours not spent on
   the apiserver, and we cannot yet demonstrate we need one.

3. **Memory is not the motivation.** Stripping OpenOS is a one-time ~30% gain.
   Sharding and streaming are N×. Any workload that needs the 30% will break
   again as the base grows. This was and remains the strongest reason not to
   treat a rewrite as a memory optimization.

### Precedent

This is **Talos Linux**: no shell, no SSH, immutable, API-only nodes. The
industry converged here for these exact reasons.

Talos works because the Kubernetes API is trustworthy enough to be the only
debugger. That is the load-bearing precondition, and we have not met it yet.

### Decision

- **Control plane: OpenOS, permanently.** One machine; needs filesystem and
  internet; 400 KB is irrelevant there and debuggability is most valuable
  exactly there.
- **Workers and edge: custom runtime, revisited after phase 5** (`kubectl`,
  logs, events). Once the API can serve as the debugger, the shell stops
  being load-bearing and thin nodes become safe.
- **Until then, mitigate under OpenOS:** warm libraries at kubelet start and
  measure the floor after warming, so admission control has a number that
  does not move.
- **Preserve optionality** via the locked base-OS surface — see
  `test/runtime_surface_test.lua`. `lib/` depends on `component`, `computer`
  and `serialization` only, so the port stays cheap.

### Conditions that would change this

- Headless `freeMemory` on a real rack server comes back far worse than
  1.12 MB.
- Reboot storms after chunk unloads prove to dominate recovery time.
- Edge node count grows past a handful, making materials dominate.

### Non-negotiable when we do build it

An **out-of-band debug channel from day one** — a panic beacon broadcasting
on a fixed port, or `chat_box.say()`. Something that reports a dying node
without depending on the control plane it may have just lost contact with.
Talos has this too. It is not optional.
