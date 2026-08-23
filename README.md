# 68kBBS

A bulletin board system for 68k Macintosh (System 6/7), written in
[Clarus](https://github.com/vaelen/clarus), serving callers over the
Mac's modem serial port. The goal is a period-authentic BBS that runs
on real hardware and supports a wide range of retro terminals (ASCII,
ANSI, VT100) as clients.

## Status

Early development. Working today:

- Log window with timestamped diagnostics; File > Quit
- Hayes modem handling: detects `CONNECT`/`NO CARRIER` result codes
  in-band (filtered out of the input stream), hangs up with `+++`/`ATH`
- Accounts in a [vDB](https://github.com/vaelen/libvdb)-format user
  database (pure-Clarus engine: `btree.cla`/`vdb.cla`, journaled with
  crash recovery and secondary indexes): signup (`NEW`),
  case-insensitive login, last-seen tracking; the first account
  created becomes the sysop
- Bulletin boards: board picker, paged post lists (newest first),
  framed post reader with paged bodies and next/previous-post
  navigation, and a classic line editor for new posts and replies
  (`/S /A /L /D /E /I /R` commands); flat threading in the message
  base, per-board header databases plus an append-only body heap
  (`docs/boards.md`)
- Sysop area: paged user/board lists, detail cards, lettered-field
  editors, deletion with confirmation, board creation, post deletion;
  safety rails so the system always keeps a sysop
- Terminal-aware rendering at 40 or 80 columns for ASCII, ANSI
  (cp437), and VT100 (DEC Special Graphics) callers: box-drawn
  tables, paged views, color helpers (`docs/tables.md`)

Planned: Fidonet-style echomail (the message base is laid out for it),
message search, and full-screen ANSI niceties.

## Building

Requirements: the pinned Clarus compiler at `bin/clarusc` (a copy of a
known-good `clarusc` build) with matching runtime/toolbox sources in
`vendor/` — both in this repo — plus `cc` for the host-lane tests.

```sh
scripts/build.sh    # 68k Mac app -> build/68kBBS.bin (MacBinary)
scripts/test.sh     # host-lane test suites (tests/*.cla)
```

## Running under emulation

The `snow/` directory holds a [Snow](https://snowemu.com) Mac II setup
whose modem port is bridged to TCP port 1234, and `snow/BBSHD.hda` is a
persistent disk image the app is deployed to (requires `hfsutils`):

```sh
scripts/deploy.sh   # build + refresh the disk image + restart Snow
```

To call the BBS like a real caller, run the bundled
[simple-modem-emulator](simple-modem-emulator/) (a TCP bridge that
plays the part of a Hayes modem) and connect with telnet:

```sh
cd simple-modem-emulator && make && ./modem &   # listens on 2323
telnet localhost 2323
```

## License

MIT — see [LICENSE](LICENSE).

Copyright 2026, Andrew C. Young <andrew@vaelen.org>
