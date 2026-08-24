# Telnet Negotiation & Subnegotiation Reference

All telnet commands are preceded by `IAC` (255, `0xFF`).

## Commands (RFC 854)

| Dec | Hex | Name | Meaning |
|-----|-----|------|---------|
| 240 | F0 | SE | End of subnegotiation |
| 241 | F1 | NOP | No operation |
| 242 | F2 | DM | Data Mark — Synch point (sent with TCP urgent) |
| 243 | F3 | BRK | Break |
| 244 | F4 | IP | Interrupt Process |
| 245 | F5 | AO | Abort Output |
| 246 | F6 | AYT | Are You There |
| 247 | F7 | EC | Erase Character |
| 248 | F8 | EL | Erase Line |
| 249 | F9 | GA | Go Ahead |
| 250 | FA | SB | Begin subnegotiation |
| 251 | FB | WILL | I want to enable this option |
| 252 | FC | WONT | I refuse / am disabling it |
| 253 | FD | DO | Please enable this option |
| 254 | FE | DONT | Please disable / don't enable it |
| 255 | FF | IAC | Escape; doubled (`FF FF`) for a literal 0xFF byte |

## Options (used after WILL/WONT/DO/DONT and SB)

| Dec | Hex | Name | RFC | Notes |
|-----|-----|------|-----|-------|
| 0 | 00 | BINARY | 856 | 8-bit clean transmission |
| 1 | 01 | ECHO | 857 | Server echoes; `WONT ECHO` is the password-prompt trick |
| 3 | 03 | SUPPRESS-GO-AHEAD | 858 | Character-at-a-time mode; near-universal |
| 5 | 05 | STATUS | 859 | Query peer's view of option state |
| 6 | 06 | TIMING-MARK | 860 | Round-trip sync probe |
| 24 | 18 | TERMINAL-TYPE | 1091 | Has subnegotiation |
| 31 | 1F | NAWS | 1073 | Window size; has subnegotiation |
| 32 | 20 | TERMINAL-SPEED | 1079 | Has subnegotiation |
| 33 | 21 | TOGGLE-FLOW-CONTROL | 1372 | Remote XON/XOFF control |
| 34 | 22 | LINEMODE | 1184 | Line editing on client side |
| 35 | 23 | X-DISPLAY-LOCATION | 1096 | |
| 36 | 24 | ENVIRON | 1408 | Deprecated, byte-order ambiguity |
| 37 | 25 | AUTHENTICATION | 2941 | |
| 38 | 26 | ENCRYPTION | 2946 | |
| 39 | 27 | NEW-ENVIRON | 1572 | Replaces option 36 |
| 44 | 2C | COM-PORT-OPTION | 2217 | Serial console servers |
| 255 | FF | EXOPL | 861 | Extended options list |

## Subnegotiation payloads

Format is `IAC SB <option> <payload> IAC SE`. Any literal 255 inside the payload must be doubled.

| Byte | Name | Used by |
|------|------|---------|
| 0 | IS | TERMINAL-TYPE, TERMINAL-SPEED, NEW-ENVIRON, X-DISPLAY-LOCATION |
| 1 | SEND | same — the requester's side |
| 2 | INFO | NEW-ENVIRON (unsolicited update) |

Common concrete forms:

| Purpose | Bytes |
|---------|-------|
| Ask for terminal type | `FF FA 18 01 FF F0` |
| Reply with terminal type | `FF FA 18 00 "xterm-256color" FF F0` |
| Window size (80×24) | `FF FA 1F 00 50 00 18 FF F0` (16-bit big-endian width, height) |
| Ask for environment vars | `FF FA 27 01 FF F0` |
| Terminal speed reply | `FF FA 20 00 "38400,38400" FF F0` |

NEW-ENVIRON payloads additionally use `VAR`=0, `VALUE`=1, `ESC`=2, `USERVAR`=3 as separators.

## MUD/game extensions (non-IETF, but widely deployed)

| Dec | Hex | Name | Purpose |
|-----|-----|------|---------|
| 85 | 55 | MCCP1 | Compression (broken; uses SB oddly) |
| 86 | 56 | MCCP2 | zlib compression — stream is deflate after `IAC SE` |
| 90 | 5A | MSSP | Server status/metadata |
| 91 | 5B | MSP | Sound protocol |
| 93 | 5D | MSDP | Structured data |
| 200 | C8 | ATCP | Legacy out-of-band channel |
| 201 | C9 | GMCP | JSON out-of-band messaging; the modern choice |

GMCP payload is `FF FA C9 "Package.Message {json}" FF F0`.

---

# Negotiation in Practice

Only a handful of options get negotiated by real clients and servers, and each side
has a conventional "direction" it drives.

## What each side typically sends

**Server → client (on connect):**

| Command | Option | Why |
|---------|--------|-----|
| `DO` | TERMINAL-TYPE (24) | Ask what terminal the client emulates |
| `DO` | NAWS (31) | Ask for window dimensions |
| `DO` | NEW-ENVIRON (39) | Ask for env vars (often just `USER`) |
| `DO` | TERMINAL-SPEED (32) | Rarely useful now; still sent by BSD telnetd |
| `WILL` | SUPPRESS-GO-AHEAD (3) | Turn off GA in the server→client stream |
| `DO` | SUPPRESS-GO-AHEAD (3) | …and in the client→server stream |
| `WILL` | ECHO (1) | Server takes over echoing (char-at-a-time mode) |
| `DO`/`WILL` | BINARY (0) | Only when 8-bit/UTF-8 transparency is wanted |
| `DO` | LINEMODE (34) | BSD telnetd tries this before falling back to ECHO+SGA |

**Client → server:**

| Command | Option |
|---------|--------|
| `WILL` | TERMINAL-TYPE, NAWS, NEW-ENVIRON, TERMINAL-SPEED |
| `WILL`/`DO` | SUPPRESS-GO-AHEAD |
| `DO` | ECHO (accepting server echo) |
| `WONT` | anything it doesn't implement |

## The two combinations that actually matter

- **SGA both ways + server `WILL ECHO`** → character-at-a-time mode. This is what you
  get from a Unix telnetd running a shell, and what any interactive server wants.
- **Neither** → line-at-a-time, local echo, client buffers until Enter. This is the
  RFC 854 default (NVT mode) and what you fall back to if the client refuses.

The password trick is the same mechanism inverted: server sends `IAC WONT ECHO` before
the prompt, client stops displaying typed characters, then `IAC WILL ECHO` afterward.

## Handshake shape

```
S: IAC DO TERMINAL-TYPE          FF FD 18
S: IAC DO NAWS                   FF FD 1F
S: IAC WILL SUPPRESS-GO-AHEAD    FF FB 03
S: IAC DO SUPPRESS-GO-AHEAD      FF FD 03
S: IAC WILL ECHO                 FF FB 01

C: IAC WILL TERMINAL-TYPE        FF FB 18
C: IAC WILL NAWS                 FF FB 1F
C: IAC WILL SUPPRESS-GO-AHEAD    FF FB 03
C: IAC DO SUPPRESS-GO-AHEAD      FF FD 03
C: IAC DO ECHO                   FF FD 01
C: IAC SB NAWS 0 80 0 24 IAC SE  FF FA 1F 00 50 00 18 FF F0

S: IAC SB TERMINAL-TYPE SEND IAC SE
C: IAC SB TERMINAL-TYPE IS "xterm-256color" IAC SE
```

Only after the option is agreed does subnegotiation happen — the SB for TERMINAL-TYPE
is illegal until the `WILL`/`DO` pair completes.

## State rules worth implementing correctly

Track four independent booleans per option: local-enabled, remote-enabled, plus a
pending flag for each. The Q-Method (RFC 1143) is the canonical version, and it exists
to prevent two failure modes:

1. **Loops.** Never respond to a request that merely confirms the state you're already
   in. If you're already echoing and receive `DO ECHO`, stay silent. Only send
   `WILL`/`WONT` when the state actually changes or when you're answering a fresh request.
2. **Refusal is final.** `WONT`/`DONT` must always be honored — you cannot decline to
   disable an option. `WILL` may be answered with `DONT`, but `WONT` may only be
   answered with silence.

The other implementation detail that bites: unknown options. Answer `WONT` to any `DO`
you don't recognize and `DONT` to any `WILL` you don't recognize — never silence, or the
peer will wait. And unrecognized subnegotiations should be consumed up to `IAC SE` and
discarded rather than treated as data.

## What's effectively dead

TERMINAL-SPEED, X-DISPLAY-LOCATION, TIMING-MARK, STATUS, EXOPL, and the old ENVIRON (36)
are still in the tables but nothing depends on them. LINEMODE is specified in detail but
implemented inconsistently enough that most servers skip it and use ECHO+SGA instead.
AUTHENTICATION and ENCRYPTION exist but essentially nobody deploys them — that use case
moved to SSH.
