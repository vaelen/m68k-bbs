# Releases

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
