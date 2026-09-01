# simple-modem-emulator

A tiny program that sits on an emulated computer's serial port (a TCP
socket) and behaves like a Hayes modem: telnet callers ring in, and the
computer can dial out to TCP hosts or to programs.

```
telnet client ──▶ :2323 ─┐
                         ├─ modem ──▶ localhost:1234 (emulated serial port,
ATDT host:port ◀─────────┤           e.g. Snow's --serial-bridge-a tcp:1234)
ATDT name ──▶ dial.conf ─┘  (tcp:host:port or exec:command)
```

Written so [68kBBS](..) running inside an emulator can take calls from
`telnet` and poll its FidoNet uplink, but generic: anything that expects
a modem on a TCP "serial port" will do.

## Build

Plain C, no dependencies beyond POSIX:

```sh
make
```

## Run

```sh
./modem [listen_port [connect_port [dial.conf]]]     # defaults: 2323 1234 (none)
```

The modem connects to `localhost:connect_port` at start and stays
connected. If that fails or the connection drops (the emulator quit), it
retries every 10 s, silently; a call in progress at the time is dropped.
It logs to stderr, one timestamped line each: serial port connected/lost,
calls placed, answered (with the caller's IP) and ended, and bans.

## Inbound calls

A telnet client connecting to `listen_port` is answered at once: the
serial side gets `\r\nCONNECT 57600\r\n` and traffic is bridged unchanged
both ways. When the caller disconnects the serial side gets
`\r\nNO CARRIER\r\n`. One call at a time: further callers get
`BUSY, PLEASE TRY AGAIN LATER\r\n`; callers while the serial port is down
get `NO ANSWER, PLEASE TRY AGAIN LATER\r\n`. No `RING`, no auto-answer
register — the line just answers.

## Dialing out

`ATD`, `ATDT` or `ATDP` followed by a dial string, spaces and dashes
ignored:

1. A name listed in `dial.conf` → its target.
2. Otherwise `host[:port]` (anything containing a `.` or `:`), port 23 by
   default — no `dial.conf` needed.
3. Otherwise `NO CARRIER`.

`dial.conf` is `name = target` per line, `#` comments; names match
case-insensitively. Targets:

| Target | Effect |
|---|---|
| `tcp:host:port` | connect; `CONNECT 57600` when connected, `NO CARRIER` if refused |
| `exec:command` | run `sh -c command` with stdin/stdout on the line (stderr inherited, so `2>>log` works); `CONNECT 57600` on its first byte, `NO CARRIER` if it exits first; hanging up sends it `SIGTERM` |

See `dial.conf.example`. While a dial is in progress any byte from the
computer aborts it (`NO CARRIER`), as does a 60 s ceiling.

## Hayes subset

| Input (from serial port) | On-hook | Online after `+++` |
|---|---|---|
| `+++` (0.5 s of silence before/after) | — | enters command mode, `OK`; not forwarded |
| `ATD…` | dials (above) | `ERROR` |
| `ATH` / `ATH0` | `OK` | hang up: `NO CARRIER`, remote closed |
| `ATO` | `OK` | back to data mode, `CONNECT 57600` |
| `AT+BAN` | `ERROR` | ban the caller's IP (below), `OK` |
| `AT+BAN=0` | clear the ban list, `OK` | same |
| any other `AT…` | `OK` | `OK` |

The command line is parsed as real Hayes syntax — basic commands
(`E0V1X4`), S registers (`S0=0`, `S11?`), `&`/`%`/`\` sets, extended
`+NAME[=value][?]` commands, optional spaces and semicolons — so chains
like `AT+BAN;H` work; everything unrecognized parses cleanly and is
ignored (`OK`).

Result codes use the Hayes verbose (`ATV1`) framing, `<CR><LF>text<CR><LF>`.
No command echo, numeric result codes or `RING`. The guard
time is 0.5 s, half the Hayes default (`GUARD_MS` in `modem.c`). Data from
the remote side that arrives in command mode is discarded. Output to the
serial side is queued and never blocks the modem: a remote streaming
faster than the port drains is paused past a 64 KB backlog (`LQ_MAX`),
and the backlog is dropped when the call ends, so `+++` timing stays
honest and `NO CARRIER` arrives promptly.

## IP bans

`AT+BAN` while an inbound caller is on the line (i.e. between `+++` and
`ATH`, or chained: `AT+BAN;H`) records a strike against that caller's IP.
Strike 1 blocks the IP for 5 minutes, strike 2 for an hour, strike 3 and
up for a day; a caller whose last strike is over a day old starts over at
zero. Banned callers are dropped without a word (the serial side never
sees them). The list lives in memory (gone on restart, capped at 8192
IPs, stalest reused) and every ban and rejection is logged with the IP
and duration. `AT+BAN=0` clears the whole list.

## Test

```sh
make test     # needs python3; ~20 s, exercises all of the above end to end
```

## License

MIT — see [LICENSE](LICENSE).
