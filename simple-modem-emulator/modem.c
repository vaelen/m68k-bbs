// Copyright 2026, Andrew C. Young <andrew@vaelen.org>
// SPDX-License-Identifier: MIT

// Simple modem emulator: sits on a local TCP "serial port" (e.g. an
// emulator's modem-port bridge) and behaves like a Hayes modem: answers
// incoming TCP "callers" (telnet), and later dials out for the computer.

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define GUARD_MS 500            // Hayes S12 guard time, 25 x 20ms = 0.5s
#define RECONNECT_MS 10000      // serial port reconnect interval
#define CONNECT_MSG "\r\nCONNECT 57600\r\n"
#define NO_CARRIER_MSG "\r\nNO CARRIER\r\n"
#define BUSY_MSG "BUSY, PLEASE TRY AGAIN LATER\r\n"
#define NO_ANSWER_MSG "NO ANSWER, PLEASE TRY AGAIN LATER\r\n"
#define OK_MSG "\r\nOK\r\n"

enum { IDLE, ONLINE, ONLINE_CMD };     // the line: on-hook, data mode, after +++
static int state = IDLE;
static int local = -1;                  // the "serial port"
static int cport;                       // its TCP port
static long local_retry_ms = 0;         // when to try connecting it again
static int rin = -1, rout = -1;         // the remote: one socket for now
static pid_t child = 0;                 // an exec: target's pid, 0 for a socket
static char held[3];                    // '+' bytes held back pending guard time
static int nheld = 0;
static long last_local_ms = 0;          // time of last byte from local
static char cmd[256];                   // command line being typed in command mode
static int ncmd = 0;

static long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000;
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

static void closefd(int *fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}

static int connect_local(int port) {
    struct sockaddr_in a;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int listen_on(int port) {
    struct sockaddr_in a;
    int one = 1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
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
    if (local >= 0) fprintf(stderr, "serial port connected\n");
    else local_retry_ms = t + RECONNECT_MS;   // quiet: logged once, on loss
}

static void remote_close(void) {
    if (rout >= 0 && rout != rin) close(rout);
    closefd(&rin);
    rout = -1;
    if (child > 0) {                    // reaped by itself: SIGCHLD is ignored
        kill(child, SIGTERM);
        child = 0;
    }
}

// The call is over (remote gone, ATH, or a dial that failed): NO CARRIER, on-hook.
static void hangup(const char *why) {
    remote_close();
    send_all(local, NO_CARRIER_MSG, sizeof NO_CARRIER_MSG - 1);
    state = IDLE;
    fprintf(stderr, "%s\n", why);
}

// The serial port went away: drop any call, start the retry clock.
static void serial_lost(void) {
    closefd(&local);
    local_retry_ms = now_ms() + RECONNECT_MS;
    if (state != IDLE) {
        remote_close();
        state = IDLE;
        fprintf(stderr, "serial port lost; call dropped\n");
    } else {
        fprintf(stderr, "serial port lost\n");
    }
}

static void go_online(void) {
    state = ONLINE;
    nheld = ncmd = 0;
    last_local_ms = 0;
    send_all(local, CONNECT_MSG, sizeof CONNECT_MSG - 1);
}

static void accept_caller(int lsock) {
    int fd = accept(lsock, NULL, NULL);
    if (fd < 0) return;
    if (state != IDLE) {                // ponytail: one call at a time; busy
        send_all(fd, BUSY_MSG, sizeof BUSY_MSG - 1);
        close(fd);
        return;
    }
    if (local < 0) {
        fprintf(stderr, "serial port down; rejecting caller\n");
        send_all(fd, NO_ANSWER_MSG, sizeof NO_ANSWER_MSG - 1);
        close(fd);
        return;
    }
    rin = rout = fd;
    go_online();
    fprintf(stderr, "call connected\n");
}

// Handle one complete command line typed in command mode.
static void do_command(void) {
    int i;
    for (i = 0; i < ncmd; i++) cmd[i] = (char)toupper((unsigned char)cmd[i]);
    if (ncmd < 2 || cmd[0] != 'A' || cmd[1] != 'T') return; // not a command; ignore
    // ponytail: only H (hang up) and O (online) matter; anything else is OK.
    for (i = 2; i < ncmd; i++) {
        if (cmd[i] == 'H' && state == ONLINE_CMD) { hangup("call ended"); return; }
        if (cmd[i] == 'O' && state == ONLINE_CMD) { go_online(); return; }
    }
    send_all(local, OK_MSG, sizeof OK_MSG - 1);
}

// Bytes arrived from the local side (the "computer"): collect a command
// line, or forward while watching for the +++ escape.
static void from_local(const char *buf, int len) {
    long t = now_ms();
    int i;
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
        send_all(local, OK_MSG, sizeof OK_MSG - 1);
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
    if (lport <= 0 || cport <= 0) {
        fprintf(stderr, "usage: %s [listen_port [connect_port]]\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    lsock = listen_on(lport);
    if (lsock < 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr, "listening on %d, serial port at localhost:%d\n", lport, cport);

    for (;;) {
        fd_set r;
        struct timeval tv = { 0, GUARD_MS * 1000 };   // wakes for guard and retry clocks
        int maxfd = lsock, n;
        serial_try();
        FD_ZERO(&r);
        FD_SET(lsock, &r);
        if (local >= 0) { FD_SET(local, &r); if (local > maxfd) maxfd = local; }
        if (rin >= 0) { FD_SET(rin, &r); if (rin > maxfd) maxfd = rin; }
        if (select(maxfd + 1, &r, NULL, NULL, &tv) < 0) {
            if (errno == EINTR) continue;
            perror("select");
            return 1;
        }
        check_guard();

        if (FD_ISSET(lsock, &r)) accept_caller(lsock);
        if (rin >= 0 && FD_ISSET(rin, &r)) {
            n = (int)read(rin, buf, sizeof buf);
            if (n <= 0) hangup("call ended");
            else if (state == ONLINE) send_all(local, buf, n);
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
