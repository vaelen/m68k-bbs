# simple-modem-emulator

A tiny TCP bridge that makes a modern telnet client look like a Hayes
modem to an emulated computer's serial port.

```
telnet client  ──TCP──▶  modem (port X)  ──TCP──▶  localhost:Y (emulated serial port)
   "caller"                                          e.g. Snow's --serial-bridge-a tcp:1234
```

It was written so [68kBBS](..) running inside an emulator can take calls
from `telnet`, but it is generic: anything that listens on a TCP port and
expects to be talking to a modem will do.

## Build

Plain C, no dependencies beyond a POSIX socket API:

```sh
make
```

## Run

```sh
./modem [listen_port [connect_port]]     # defaults: 2323 1234
```

Then point a telnet client at `listen_port`.

## What it does

1. Listens on `listen_port`.
2. When a caller connects, it connects to `localhost:connect_port`
   (the "serial port"). If that is refused, the caller is dropped.
3. Otherwise it writes `CONNECT 57600\r` to the serial port and bridges
   all traffic between the two, unchanged, in both directions.
4. If the caller disconnects, it writes `NO CARRIER\r` to the serial port
   and closes that connection. If the serial port side closes, the caller
   is dropped.
5. One call at a time; further callers during a call are dropped (busy).

## Hayes subset

Only what is needed to hang up on a caller from the computer side:

| Input (from serial port)            | Effect                                         |
|-------------------------------------|------------------------------------------------|
| `+++` (1 s of silence before/after) | Enter command mode, reply `OK\r`. Not forwarded.|
| `ATH` / `ATH0`                      | Hang up: `NO CARRIER\r`, close both connections.|
| `ATO`                               | Back to data mode, reply `CONNECT 57600\r`.     |
| any other `AT…`                     | `OK\r`                                          |

Everything else about a real modem — `RING`, `ATA`, dialing, echo, S
registers, result-code formats — is deliberately absent. The guard time
is the Hayes default (`GUARD_MS` in `modem.c`). Data from the caller that
arrives while in command mode is discarded.

## Test

```sh
make test     # needs python3; exercises all of the above end to end
```

## License

MIT — see [LICENSE](LICENSE).
