// Copyright 2026, Andrew C. Young <andrew@vaelen.org>
// SPDX-License-Identifier: MIT

// Simple modem emulator: sits on a local TCP "serial port" (e.g. an
// emulator's modem-port bridge) and behaves like a Hayes modem: answers
// incoming TCP "callers" (telnet), and later dials out for the computer.

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define GUARD_MS 500            // Hayes S12 guard time, 25 x 20ms = 0.5s
#define LQ_MAX 65536            // serial-side backlog that pauses the remote
#define RECONNECT_MS 10000      // serial port reconnect interval
#define DIAL_MS 60000           // dial ceiling (Hayes S7 is 50 s)
#define CONNECT_MSG "\r\nCONNECT 57600\r\n"
#define NO_CARRIER_MSG "\r\nNO CARRIER\r\n"
#define BUSY_MSG "BUSY, PLEASE TRY AGAIN LATER\r\n"
#define NO_ANSWER_MSG "NO ANSWER, PLEASE TRY AGAIN LATER\r\n"
#define OK_MSG "\r\nOK\r\n"
#define ERROR_MSG "\r\nERROR\r\n"

enum { IDLE, DIALING, ONLINE, ONLINE_CMD };   // on-hook, dial in progress, data mode, after +++
static int state = IDLE;
static int local = -1;                  // the "serial port"
static int cport;                       // its TCP port
static long local_retry_ms = 0;         // when to try connecting it again
static int rin = -1, rout = -1;         // the remote: one socket for now
static pid_t child = 0;                 // an exec: target's pid, 0 for a socket
static long dial_ms = 0;                // when the current dial started
static const char *dialconf = NULL;     // address book, or NULL
static char held[3];                    // '+' bytes held back pending guard time
static int nheld = 0;
static long last_local_ms = 0;          // time of last byte from local
static char cmd[256];                   // command line being typed in command mode
static int ncmd = 0;
static char *lq = NULL;                 // bytes waiting for the serial port
static int lqlen = 0, lqcap = 0;

// IP bans (AT+BAN strikes the current inbound caller): 5 min, then 1 h,
// then 24 h; a caller whose last strike is over a day old starts over.
#define BAN_MAX 8192
struct ban {
    in_addr_t ip;
    int count;                          // strikes so far
    long last_ms;                       // time of the last strike
};
static struct ban bans[BAN_MAX];
static int nbans = 0;
static in_addr_t caller_ip = 0;         // current inbound caller, 0 = none
static char caller_ip_str[INET_ADDRSTRLEN];

static long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000;
}

// Timestamped log line to stderr.
static void logts(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    va_list ap;
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s ", ts);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static long ban_dur_ms(int count) {
    if (count >= 3) return 24L * 3600 * 1000;
    if (count == 2) return 3600L * 1000;
    return 5L * 60 * 1000;
}

static struct ban *ban_find(in_addr_t ip) {
    int i;
    for (i = 0; i < nbans; i++) if (bans[i].ip == ip) return &bans[i];
    return NULL;
}

// AT+BAN: strike the current inbound caller. 0 if nobody is on the line.
static int ban_caller(void) {
    struct ban *b;
    if (caller_ip == 0) return 0;
    b = ban_find(caller_ip);
    if (b == NULL) {
        if (nbans < BAN_MAX) {
            b = &bans[nbans++];
        } else {                        // full: reuse the stalest entry
            int i;
            b = &bans[0];
            for (i = 1; i < nbans; i++) if (bans[i].last_ms < b->last_ms) b = &bans[i];
        }
        b->ip = caller_ip;
        b->count = 0;
    }
    b->count++;
    b->last_ms = now_ms();
    logts("banned %s for %ld minutes (strike %d)", caller_ip_str,
          ban_dur_ms(b->count) / 60000L, b->count);
    return 1;
}

static void send_all(int fd, const char *buf, int len) {
    if (fd < 0) return;
    while (len > 0) {
        int n = (int)write(fd, buf, (size_t)len);
        if (n <= 0) return;             // peer gone; the read side will notice
        buf += n;
        len -= n;
    }
}

// Serial-side output never blocks: the port drains at its baud rate
// while a TCP remote streams at LAN speed, and a write() that waited
// for it stalled the loop -- the computer's "+++" then arrived in the
// same late batch as its earlier bytes and the guard time was lost.
// Bytes queue here and drain as select() finds the port writable; past
// LQ_MAX the remote is not read (backpressure, like RTS/CTS).
static void local_flush(void) {
    while (lqlen > 0 && local >= 0) {
        int n = (int)write(local, lq, (size_t)lqlen);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
        if (n <= 0) { lqlen = 0; return; }   // port gone; the read side will notice
        memmove(lq, lq + n, (size_t)(lqlen - n));
        lqlen -= n;
    }
}

static void local_send(const char *buf, int len) {
    if (local < 0 || len <= 0) return;
    if (lqlen + len > lqcap) {
        lqcap = (lqlen + len) * 2;
        lq = realloc(lq, (size_t)lqcap);
        if (lq == NULL) { perror("realloc"); exit(1); }
    }
    memcpy(lq + lqlen, buf, (size_t)len);
    lqlen += len;
    local_flush();
}

static void closefd(int *fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}

static int connect_local(int port) {
    struct sockaddr_in a;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    return fd;
}

static int listen_on(int port) {
    struct sockaddr_in a;
    int one = 1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 4) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// Keep the serial port connected: try (again) once the retry clock allows.
static void serial_try(void) {
    long t = now_ms();
    if (local >= 0 || t < local_retry_ms) return;
    local = connect_local(cport);
    if (local >= 0) logts("serial port connected");
    else local_retry_ms = t + RECONNECT_MS;   // quiet: logged once, on loss
}

static void remote_close(void) {
    if (rout >= 0 && rout != rin) close(rout);
    closefd(&rin);
    rout = -1;
    caller_ip = 0;
    if (child > 0) {                    // reaped by itself: SIGCHLD is ignored
        kill(child, SIGTERM);
        child = 0;
    }
}

// The call is over (remote gone, ATH, or a dial that failed): NO CARRIER, on-hook.
static void hangup(const char *why) {
    remote_close();
    lqlen = 0;                          // buffered remote data dies with the carrier
    local_send(NO_CARRIER_MSG, sizeof NO_CARRIER_MSG - 1);
    state = IDLE;
    logts("%s", why);
}

// The serial port went away: drop any call, start the retry clock.
static void serial_lost(void) {
    closefd(&local);
    lqlen = 0;
    local_retry_ms = now_ms() + RECONNECT_MS;
    if (state != IDLE) {
        remote_close();
        state = IDLE;
        logts("serial port lost; call dropped");
    } else {
        logts("serial port lost");
    }
}

static void go_online(void) {
    state = ONLINE;
    nheld = ncmd = 0;
    last_local_ms = 0;
    local_send(CONNECT_MSG, sizeof CONNECT_MSG - 1);
}

// Start a non-blocking TCP connect to host:port; the loop finishes it.
static void dial_tcp(const char *host, const char *port) {
    struct addrinfo hints, *ai;
    int fd;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;          // ponytail: v4 only; "host:port" can't carry a v6 literal
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &ai) != 0) { hangup("no such host"); return; }
    fd = socket(ai->ai_family, ai->ai_socktype, 0);
    if (fd >= 0) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) < 0 && errno != EINPROGRESS) {
            close(fd);
            fd = -1;
        }
    }
    freeaddrinfo(ai);
    if (fd < 0) { hangup("connect failed"); return; }
    rin = rout = fd;
    state = DIALING;
    dial_ms = now_ms();
}

// dial.conf: "name = target" per line, '#' comments. Names compare
// case-insensitively with spaces/dashes stripped, like dial strings.
static int lookup(const char *name, char *out, int outlen) {
    FILE *f;
    char line[512], key[512];
    if (dialconf == NULL || (f = fopen(dialconf, "r")) == NULL) return 0;
    while (fgets(line, sizeof line, f)) {
        char *eq = strchr(line, '='), *p;
        int n = 0;
        if (line[0] == '#' || eq == NULL) continue;
        *eq = 0;
        for (p = line; *p; p++) if (*p != ' ' && *p != '\t' && *p != '-') key[n++] = *p;
        key[n] = 0;
        if (strcasecmp(key, name) != 0) continue;
        p = eq + 1;
        while (*p == ' ' || *p == '\t') p++;
        p[strcspn(p, "\r\n")] = 0;
        snprintf(out, (size_t)outlen, "%s", p);
        fclose(f);
        return 1;
    }
    fclose(f);
    return 0;
}

// Spawn "sh -c command" with its stdin/stdout on the line; CONNECT waits
// for its first byte (the loop), EOF before that is NO CARRIER.
static void dial_exec(const char *command) {
    int to_child[2], from_child[2];
    if (pipe(to_child) < 0 || pipe(from_child) < 0) { hangup("pipe failed"); return; }
    child = fork();
    if (child < 0) { child = 0; hangup("fork failed"); return; }
    if (child == 0) {
        dup2(to_child[0], 0);
        dup2(from_child[1], 1);
        close(to_child[0]); close(to_child[1]); close(from_child[0]); close(from_child[1]);
        execl("/bin/sh", "sh", "-c", command, (char *)0);
        _exit(127);
    }
    close(to_child[0]);
    close(from_child[1]);
    rin = from_child[0];
    rout = to_child[1];
    state = DIALING;
    dial_ms = now_ms();
}

// Place a call for the dial string s: an address-book name, else
// "host[:port]" (port 23 by default), else no such number.
static void dial(const char *s) {
    char num[256], target[512], *host, *port;
    int i, n = 0;
    for (i = 0; s[i]; i++) if (s[i] != ' ' && s[i] != '-') num[n++] = s[i];
    num[n] = 0;
    if (lookup(num, target, sizeof target)) {
        logts("dialing %s -> %s", num, target);
        if (strncmp(target, "exec:", 5) == 0) { dial_exec(target + 5); return; }
        if (strncmp(target, "tcp:", 4) != 0) { hangup("bad target"); return; }
        host = target + 4;
    } else if (strchr(num, '.') || strchr(num, ':')) {
        logts("dialing %s", num);
        host = num;
    } else {
        hangup("no such number");
        return;
    }
    port = strrchr(host, ':');
    if (port) *port++ = 0; else port = "23";
    dial_tcp(host, port);
}

static void accept_caller(int lsock) {
    struct sockaddr_in a;
    socklen_t al = sizeof a;
    char ip[INET_ADDRSTRLEN];
    struct ban *b;
    long t = now_ms();
    int fd = accept(lsock, (struct sockaddr *)&a, &al);
    if (fd < 0) return;
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    b = ban_find(a.sin_addr.s_addr);
    if (b && t - b->last_ms > ban_dur_ms(3)) b->count = 0;  // a quiet day clears the record
    if (b && b->count > 0 && t - b->last_ms < ban_dur_ms(b->count)) {
        logts("rejecting banned caller %s (%ld min left)", ip,
              (b->last_ms + ban_dur_ms(b->count) - t) / 60000L + 1);
        close(fd);
        return;
    }
    if (state != IDLE) {                // ponytail: one call at a time; busy
        send_all(fd, BUSY_MSG, sizeof BUSY_MSG - 1);
        close(fd);
        return;
    }
    if (local < 0) {
        logts("serial port down; rejecting caller %s", ip);
        send_all(fd, NO_ANSWER_MSG, sizeof NO_ANSWER_MSG - 1);
        close(fd);
        return;
    }
    rin = rout = fd;
    caller_ip = a.sin_addr.s_addr;
    snprintf(caller_ip_str, sizeof caller_ip_str, "%s", ip);
    go_online();
    logts("call connected from %s", ip);
}

// Handle one complete command line typed in command mode: a Hayes
// tokenizer over the whole line — basic commands (letter + digits),
// S registers (Sn=v / Sn?), prefixed sets (&X / %X / \X), extended
// commands (+NAME[=value][?]), optional semicolon separators. Only
// D, H, O and +BAN act; everything else parses and is ignored.
static void do_command(void) {
    int i, err = 0;
    for (i = 0; i < ncmd; i++) cmd[i] = (char)toupper((unsigned char)cmd[i]);
    cmd[ncmd] = 0;
    if (ncmd < 2 || cmd[0] != 'A' || cmd[1] != 'T') return; // not a command; ignore
    i = 2;
    while (i < ncmd) {
        char c = cmd[i];
        if (c == ' ' || c == ';') { i++; continue; }
        if (c == 'D') {                 // dial: consumes the rest of the line
            if (state != IDLE) { local_send(ERROR_MSG, sizeof ERROR_MSG - 1); return; }
            i++;
            if (i < ncmd && (cmd[i] == 'T' || cmd[i] == 'P')) i++;
            dial(cmd + i);              // sends its own result
            return;
        }
        if (c == '+' || c == '#' || c == '$') {   // extended: +NAME[=value][?]
            int start = i, namelen, vstart = 0, vlen = 0;
            i++;
            while (i < ncmd && (isalnum((unsigned char)cmd[i]) || cmd[i] == '-' || cmd[i] == '_')) i++;
            namelen = i - start;
            if (i < ncmd && cmd[i] == '?') {
                i++;
            } else if (i < ncmd && cmd[i] == '=') {
                vstart = ++i;
                while (i < ncmd && cmd[i] != ';') i++;
                vlen = i - vstart;
            }
            if (namelen == 4 && memcmp(cmd + start, "+BAN", 4) == 0) {
                if (vstart == 0) {
                    if (!ban_caller()) err = 1;
                } else if (vlen == 1 && cmd[vstart] == '0') {
                    nbans = 0;          // AT+BAN=0: clear the ban list
                    logts("ban list cleared");
                } else {
                    err = 1;
                }
            }
            continue;                   // other extended commands: ignored
        }
        if (c == '&' || c == '%' || c == '\\') {  // &Xn etc.: ignored
            i++;
            if (i < ncmd && isalpha((unsigned char)cmd[i])) i++;
            while (i < ncmd && isdigit((unsigned char)cmd[i])) i++;
            continue;
        }
        if (c == 'S') {                 // Sn=v / Sn?: ignored
            i++;
            while (i < ncmd && isdigit((unsigned char)cmd[i])) i++;
            if (i < ncmd && cmd[i] == '?') i++;
            else if (i < ncmd && cmd[i] == '=') {
                i++;
                while (i < ncmd && isdigit((unsigned char)cmd[i])) i++;
            }
            continue;
        }
        if (isalpha((unsigned char)c)) {          // basic: letter + digits
            i++;
            while (i < ncmd && isdigit((unsigned char)cmd[i])) i++;
            if (c == 'H' && state == ONLINE_CMD) { hangup("call ended"); return; }
            if (c == 'O' && state == ONLINE_CMD) { go_online(); return; }
            continue;
        }
        i++;                            // junk: skip a byte, keep parsing
    }
    if (err) local_send(ERROR_MSG, sizeof ERROR_MSG - 1);
    else local_send(OK_MSG, sizeof OK_MSG - 1);
}

// Bytes arrived from the local side (the "computer"): collect a command
// line, or forward while watching for the +++ escape.
static void from_local(const char *buf, int len) {
    long t = now_ms();
    int i;
    if (state == DIALING) { hangup("dial aborted"); return; }   // any key aborts a dial
    if (state != ONLINE) {              // command mode: IDLE or ONLINE_CMD
        for (i = 0; i < len; i++) {
            if (buf[i] == '\r') {
                do_command();
                ncmd = 0;
            } else if (buf[i] != '\n' && ncmd < (int)sizeof cmd - 1) {
                cmd[ncmd++] = buf[i];
            }
        }
        return;
    }
    // Data mode. A burst starting after >= GUARD_MS of silence that is only
    // '+' (up to 3) is held back until we know whether it is the escape.
    if (nheld == 0 && t - last_local_ms < GUARD_MS) {
        send_all(rout, buf, len);       // mid-stream: not an escape
    } else {
        for (i = 0; i < len; i++) {
            if (buf[i] == '+' && nheld < 3) {
                held[nheld++] = '+';
            } else {
                break;
            }
        }
        if (i < len) {                  // something other than "+++": flush
            send_all(rout, held, nheld);
            nheld = 0;
            send_all(rout, buf + i, len - i);
        }
    }
    last_local_ms = t;
}

// Called on every loop pass: decide whether held +++ was an escape.
static void check_guard(void) {
    if (nheld == 0 || now_ms() - last_local_ms < GUARD_MS) return;
    if (nheld == 3) {
        state = ONLINE_CMD;
        ncmd = 0;
        local_send(OK_MSG, sizeof OK_MSG - 1);
    } else {
        send_all(rout, held, nheld);    // lone '+' or '++': just data
    }
    nheld = 0;
}

int main(int argc, char **argv) {
    int lport = argc > 1 ? atoi(argv[1]) : 2323;
    int lsock;
    char buf[4096];

    cport = argc > 2 ? atoi(argv[2]) : 1234;
    dialconf = argc > 3 ? argv[3] : NULL;
    if (lport <= 0 || cport <= 0) {
        fprintf(stderr, "usage: %s [listen_port [connect_port [dial.conf]]]\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    lsock = listen_on(lport);
    if (lsock < 0) {
        perror("listen");
        return 1;
    }
    logts("listening on %d, serial port at localhost:%d", lport, cport);

    for (;;) {
        fd_set r, w;
        struct timeval tv = { 0, GUARD_MS * 1000 };   // wakes for guard, retry and dial clocks
        int maxfd = lsock, n;
        serial_try();
        FD_ZERO(&r);
        FD_ZERO(&w);
        FD_SET(lsock, &r);
        if (local >= 0) {
            FD_SET(local, &r);
            if (lqlen > 0) FD_SET(local, &w);
            if (local > maxfd) maxfd = local;
        }
        if (rin >= 0) {
            if (state == DIALING && child == 0) FD_SET(rin, &w);   // connect in flight
            else if (lqlen < LQ_MAX) FD_SET(rin, &r);              // else: let the port catch up
            if (rin > maxfd) maxfd = rin;
        }
        if (select(maxfd + 1, &r, &w, NULL, &tv) < 0) {
            if (errno == EINTR) continue;
            perror("select");
            return 1;
        }
        check_guard();
        if (local >= 0 && FD_ISSET(local, &w)) local_flush();
        if (state == DIALING && now_ms() - dial_ms >= DIAL_MS) hangup("dial timed out");

        if (FD_ISSET(lsock, &r)) accept_caller(lsock);
        if (rin >= 0 && FD_ISSET(rin, &w)) {            // connect finished
            int err = 0;
            socklen_t el = sizeof err;
            getsockopt(rin, SOL_SOCKET, SO_ERROR, &err, &el);
            if (err) {
                hangup("connect failed");
            } else {
                fcntl(rin, F_SETFL, fcntl(rin, F_GETFL) & ~O_NONBLOCK);
                go_online();
                logts("call connected");
            }
        }
        if (rin >= 0 && FD_ISSET(rin, &r)) {
            n = (int)read(rin, buf, sizeof buf);
            if (n <= 0) {
                hangup(state == DIALING ? "no answer" : "call ended");
            } else {
                if (state == DIALING) {         // exec: target's first byte
                    go_online();
                    logts("call connected");
                }
                if (state == ONLINE) local_send(buf, n);
            }
            // ponytail: in command mode remote data is dropped, like a real
            // modem with no buffer; it would be forwarded after ATO anyway.
        }
        if (local >= 0 && FD_ISSET(local, &r)) {
            n = (int)read(local, buf, sizeof buf);
            if (n <= 0) serial_lost();
            else from_local(buf, n);
        }
    }
}
