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
   (the "serial port"). If that is refused, the caller is sent
   `NO ANSWER, PLEASE TRY AGAIN LATER\r\n` and dropped.
3. Otherwise it writes `\r\nCONNECT 57600\r\n` to the serial port and bridges
   all traffic between the two, unchanged, in both directions.
4. If the caller disconnects, it writes `\r\nNO CARRIER\r\n` to the serial port
   and closes that connection. If the serial port side closes, the caller
   is dropped.
5. One call at a time; further callers during a call are sent
   `BUSY, PLEASE TRY AGAIN LATER\r\n` and dropped.

## Hayes subset

Only what is needed to hang up on a caller from the computer side:

| Input (from serial port)              | Effect                                         |
|---------------------------------------|------------------------------------------------|
| `+++` (0.5 s of silence before/after) | Enter command mode, reply `\r\nOK\r\n`. Not forwarded.|
| `ATH` / `ATH0`                        | Hang up: `\r\nNO CARRIER\r\n`, close both connections.|
| `ATO`                                 | Back to data mode, reply `\r\nCONNECT 57600\r\n`.     |
| any other `AT…`                       | `\r\nOK\r\n`                                          |

Result codes use the Hayes verbose (`ATV1`) framing, `<CR><LF>text<CR><LF>`.
Everything else about a real modem — `RING`, `ATA`, dialing, echo, S
registers, numeric result codes — is deliberately absent. The guard time
is 0.5 s, half the Hayes default (`GUARD_MS` in `modem.c`). Data from the
caller that arrives while in command mode is discarded.

## Test

```sh
make test     # needs python3; exercises all of the above end to end
```

## License

MIT — see [LICENSE](LICENSE).
