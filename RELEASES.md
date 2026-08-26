# Releases

## Unreleased — v0.2

FidoNet-technology networking as a leaf node (fsxNet first), over the
modem port:

- Networks database and sysop screens (address, uplink, passwords,
  dial string, UTC offset, poll schedule, AreaFix requests).
- Boards map to echomail areas (network + echo tag); posts carry
  MSGID/REPLY kludges with threading and duplicate detection.
- Netmail through the Mail system: send to any FTN address, replies to
  inbound netmail, unknown recipients delivered to the sysop.
- Type-2+ packet toss and scan (`ftnpkt.cla`, `ftntoss.cla`).
- The poll (`emsi.cla`): dial, EMSI handshake, ZMODEM send and
  receive, hang up, toss; scheduled by interval, from the Mac's
  FidoNet menu, or queued by the remote sysop.
- Requires a binkp bridge on the host (`docs/fidonet.md`, "Bridge
  contract") — in progress in libftn.

## v0.1 — 2026-08-26

The first fully working BBS. Runs on a 68k Macintosh (System 6/7),
answering callers on the modem serial port, with telnet clients
supported through a Hayes-modem bridge.

- Login and signup with a Users database; the first account is the sysop.
- Terminal support: ASCII, ANSI, and VT100, with telnet negotiation
  (terminal type, window size, speed, echo, binary).
- Message boards: board picker, paged post lists, threaded replies,
  a WWIV-style line editor.
- Private mail between users.
- File areas: browse, upload, and download via XMODEM, XMODEM-1K,
  YMODEM, and ZMODEM (with ZMODEM resume).
- Sysop menu: manage users, boards, and file areas; approve uploads.
- Login log with a recent-callers screen.
