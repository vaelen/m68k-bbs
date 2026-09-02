# Configuration file

`Config.txt` (TEXT/ttxt, next to the app) holds BBS settings the sysop
can change without a rebuild. Format: one `key=value` per CR line,
`#` comments, blank lines ignored, LF line ends tolerated (a host
editor), spaces around `=` trimmed, unknown keys ignored. Every setting
has a compiled-in default in `config.cla`'s `Config` record; a missing
file or a missing/unparsable key means the default. A missing file is
written out at launch so the keys are there to edit.

| key | default | meaning |
|---|---|---|
| `newUserAccess` | 367 (`accessDefault`) | Access flag bits given to a new signup (`docs/access.md`); the first account always gets every flag |
| `maintenanceHour` | 4 | Hour (0–23, Mac local time) at which the daily maintenance window opens (`docs/maintenance.md`) |
| `systemName` | `68kBBS` | The board's name, up to 50 chars: FTN Origin lines and the EMSI IDENT system field (`docs/fidonet.md`); the software name on tearlines/PID stays `68kBBS` |
| `modemInit` | `AT&FE1Q0V1X4&C1&D2S0=0` | Modem init string, sent (after a paced hang-up) at startup and from `Maintenance > Initialize Modem`; explicitly empty = send none |
| `modemSpeed` | 57600 | Serial port bps (300/1200/2400/4800/9600/19200/57600); the Modem menu edits it |
| `modemPort` | `modem` | `modem` or `printer` — which serial port the BBS answers; the Modem menu edits it |
| `idleSeconds` | 300 | Hang up a caller idle (no bytes received) this many seconds; 0 = never. A one-minute warning is sent when the timeout is over 60 s; transfers and FTN polls are exempt |

`configLoad()` runs at launch (before the databases open); `configSave()`
rewrites the whole file. The live values are `config.<field>`.

Sysop menu `C) Configuration` lists the settings; `A) New User Access`
opens the flag toggle table (the same one the user edit card uses) and
Enter saves at once; `H) Maintenance hour` prompts for 0–23 and saves at
once; `I) Idle timeout` prompts for seconds (0 = off); `M) Modem init
string` and `N) System name` prompt for the new value (empty keeps the
current one) and save at once. `modemSpeed`/`modemPort` are edited from
the Mac-side Modem menu instead.

To add a setting: a field on `Config` with its default, a `case` in
`configApply`, a line in `configSave`, a row in the menu if the sysop
should edit it, and a row in the table above.
