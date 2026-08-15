# Confirmed hardware facts

From `probe.lua` on a GT:NH Tier 3 computer case, 2026-08-15.
Everything here is measured, not assumed. The simulator is calibrated
against it — see the `sim :: sandbox fidelity` tests.

## Machine

```
architecture   Lua 5.3          (Lua 5.2 also available)
mem total      1572864 bytes    1.50 MB  — T3 case, 2 RAM sticks
mem free       1176353 bytes    1.12 MB  at an idle OpenOS prompt
CPU            FlexiArch 3 Processor, clock 1500
thread api     present
```

**Only 1.12 MB of the 1.5 MB is actually available** — OpenOS itself costs
roughly 400 KB. Budget against free memory, never total.

## Sandbox

Lua 5.3 with one removal that matters:

| Global | State | Consequence |
|---|---|---|
| `collectgarbage` | **absent** | No forced GC. Memory readings include uncollected garbage and read high — treat every measurement as an upper bound. |
| `loadstring`, `unpack` | absent | Lua 5.3 removals. Use `load` and `table.unpack`. |
| `coroutine.close` | absent | Lua 5.4 addition. |
| `load`, `pcall`, `xpcall`, `error` | present | Pod sandboxing via `load(src, name, "t", env)` is viable. |
| `dofile`, `loadfile`, `require` | present | |
| `debug.traceback`, `debug.getinfo` | present | Real stack traces in error reporting. |
| `utf8`, `string.pack`, `table.move` | present | `string.pack` is worth remembering for compact wire encoding. |

## Component proxies are callable tables, not functions

`component.proxy()` returns methods as **tables with `__call`**, plus a
`__tostring` yielding the docstring — that is how
`print(component.gpu.setResolution)` prints documentation in OpenOS.

```lua
type(modem.maxPacketSize)              --> "table"   NOT "function"
getmetatable(modem.maxPacketSize).__call --> function
modem.maxPacketSize()                  --> 8192      calling works fine
```

Any guard written as `type(x) == "function"` silently skips every component
method. This cost the first probe run its entire transport section, which
reported a nil `maxPacketSize` on a modem that plainly had one. `pcall` on a
callable table works normally, so only explicit type checks are affected.

## Network

```
card           wireless ethernet, 39i110 (LPPW-01)
maxPacketSize  8192 bytes
```

Direct vs indirect matters more than the size limit:

| Method | Direct | Cost |
|---|---|---|
| `maxPacketSize`, `isOpen`, `isWireless`, `getStrength` | yes | inline, against a per-tick budget |
| `send`, `broadcast`, `open`, `close` | **no** | machine yields, resumes a later tick |

Every packet sent is an indirect call. If that is one server tick, a message
split into 7 chunks costs ~350 ms in call overhead alone, and a machine can
sustain roughly 20 packets/second. **Packet count, not byte count, is the
binding constraint.**

Run `bench` to measure this on your hardware. It is the number that decides
how chatty the control plane can afford to be.

## Storage

```
tmpfs           65536 bytes    (64 KB)
filesystem    4194304 bytes    (4 MB)  — T3 HDD
filesystem    1048576 bytes    (1 MB)
```

## Fencing — better than expected

The `computer` component exposes:

```
start()      direct=false   Starts the computer. Returns true if state changed.
stop()       direct=false   Stops the computer. Returns true if state changed.
isRunning()  direct=true    Returns whether the computer is running.
```

Two OC machines connected by cable see each other as `computer` components.
The state change is applied by the mod, **not** by the target's Lua VM — so
`stop()` works on a machine wedged in a loop that will never yield again.

That is genuine out-of-band power control, and it replaces the
redstone-gated power feed originally planned for fencing. Redstone remains
the backstop for a machine unreachable on the network entirely.

**To verify once racks exist:** whether servers inside a rack expose
`computer` components to each other and to the control plane.

## Other components present

- `internet` — `request()` works, which is what makes the `kbi` deploy loop
  possible. `isHttpEnabled()` confirms availability.
- `chat_box` — `say(text, distance)`. A free alerting channel: cluster
  events can be announced in Minecraft chat with no display hardware.

## Not yet present

No `me_interface` or `me_controller` on this machine yet — inventory
controllers are not wired to the ME system. `probe_me.lua` is waiting.
