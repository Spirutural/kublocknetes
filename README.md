# kublocknetes

Kubernetes for OpenComputers. A real control plane — declarative objects,
level-triggered reconciliation, scheduling — running on Minecraft computers
in GregTech: New Horizons.

Not a job queue with a funny name. The point is that reconciliation loops are
genuinely the right architecture for a world where packets drop silently,
chunks unload, and creepers happen. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Status

Running on real hardware. Two nodes (`master`, `worker-1`) with working
remote shell, hostnames and broadcast discovery. The control plane is next.

```
$ lua run-tests.lua
58 passed, 0 failed
```

## Layout

```
lib/     cluster code — runs unmodified in-game and in the simulator,
         and may require only component/computer/serialization
openos/  code that depends on OpenOS, kept out of lib/ deliberately
bin/     programs that run in-game
sim/     OpenComputers simulator: many virtual machines in one Lua process
test/    the suite
tools/   host-side tooling that reaches into the game
probe/   scripts to run in-game to discover real hardware and API surface
docs/    measured hardware facts and architecture decisions
```

## The host-side channel

OpenComputers filesystems are directories in the Minecraft world save, and a
running server picks up files written from outside. So with SSH to the game
server, any machine's disk is reachable — no internet card, no listening
port, no config change, and nothing exposed to the network.

```sh
tools/ocmail 'ls /usr/lib'          # run a command in-game, get its output
tools/ocpush b64178fb               # install current code onto a machine
tools/ocprovision --list            # every disk, named or blank
tools/ocprovision 3f9a --name worker-2   # blank disk -> working node
tools/mkfloppy <uuid>               # for machines off this server
```

`ocmail` needs `dropbox` running in-game; the rest need nothing at all.

Provisioning a rack server is one command: it clones a known-good OpenOS
install, pushes the cluster code, sets the hostname, and enables the
services. Power it on and it joins.

## Developing

Requires Lua 5.3 — the same version OpenComputers uses, which is why code can
be developed and tested here before it ever touches the game.

```sh
lua run-tests.lua
```

The simulator lets you build a cluster, break the network, kill nodes, and
assert on what happens, all in virtual time:

```lua
local sim   = require("oc")
local world = sim.newWorld({ lossRate = 0.25, seed = 7 })

local server = world:addNode({ name = "server" })
local client = world:addNode({ name = "client" })

server:boot(server:loadstring(SERVER_SOURCE))
client:boot(client:loadstring(CLIENT_SOURCE))

world:run(60)     -- 60 seconds of virtual time, in milliseconds of real time
server:crash()    -- hard power cut
world:run(60)     -- assert the cluster healed
```

Node programs are compiled from strings into a per-node sandbox — which is
also how pod dispatch works for real, so tests exercise the actual mechanism.

## In-game

With an Internet Card, type this once and never type Lua into `edit` again:

```
wget -f https://raw.githubusercontent.com/Spirutural/kublocknetes/main/boot/install.lua /usr/bin/kbi.lua && kbi
```

`kbi` syncs every file in [MANIFEST](MANIFEST) — including itself — so from
then on a push here is one command away from every machine in the cluster.

```
kbi              install or update everything
kbi --branch dev pull from another branch
kbi --list       show what would change, change nothing
```

Then, on any machine:

```
probe            # capabilities, memory, API surface -> /home/probe.txt
pastebin put /home/probe.txt
```

`probe/probe_me.lua` sizes an ME network without materializing it. It refuses
the dangerous unfiltered call unless you pass `--force`, and writes its report
to disk *before* making it, so the findings survive the OOM.
