// Copyright 2026, Andrew C. Young <andrew@vaelen.org>
// SPDX-License-Identifier: MIT

// Simple modem emulator: bridges an incoming TCP "caller" (telnet) to a
// local TCP "serial port" (e.g. an emulator's modem-port bridge), speaking
// just enough Hayes to hang up (+++ / ATH0) and go back online (ATO).

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
#define CONNECT_MSG "\r\nCONNECT 57600\r\n"
#define NO_CARRIER_MSG "\r\nNO CARRIER\r\n"
#define OK_MSG "\r\nOK\r\n"

static int local = -1, remote = -1;     // local = "serial port", remote = caller
static int cmd_mode = 0;                // 0 = data (online), 1 = command
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

// Remote went away (or we hung up): tell the local side and drop it.
static void hangup(void) {
    closefd(&remote);
    if (local >= 0) {
        send_all(local, NO_CARRIER_MSG, sizeof NO_CARRIER_MSG - 1);
        closefd(&local);
    }
    fprintf(stderr, "call ended\n");
}

// Handle one complete command line typed in command mode.
static void do_command(void) {
    int i;
    for (i = 0; i < ncmd; i++) cmd[i] = (char)toupper((unsigned char)cmd[i]);
    if (ncmd < 2 || cmd[0] != 'A' || cmd[1] != 'T') return; // not a command; ignore
    // ponytail: only H (hang up) and O (online) matter; anything else is OK.
    for (i = 2; i < ncmd; i++) {
        if (cmd[i] == 'H') { hangup(); return; }
        if (cmd[i] == 'O') {
            cmd_mode = 0;
            send_all(local, CONNECT_MSG, sizeof CONNECT_MSG - 1);
            return;
        }
    }
    send_all(local, OK_MSG, sizeof OK_MSG - 1);
}

// Bytes arrived from the local side (the "computer"): forward, or watch for
// the +++ escape, or collect a command line.
static void from_local(const char *buf, int len) {
    long t = now_ms();
    int i;
    if (cmd_mode) {
        for (i = 0; i < len; i++) {
            if (buf[i] == '\r') {
                do_command();
                ncmd = 0;
                if (local < 0) return;  // hung up
            } else if (buf[i] != '\n' && ncmd < (int)sizeof cmd) {
                cmd[ncmd++] = buf[i];
            }
        }
        return;
    }
    // Data mode. A burst starting after >= GUARD_MS of silence that is only
    // '+' (up to 3) is held back until we know whether it is the escape.
    if (nheld == 0 && t - last_local_ms < GUARD_MS) {
        send_all(remote, buf, len);     // mid-stream: not an escape
    } else {
        for (i = 0; i < len; i++) {
            if (buf[i] == '+' && nheld < 3) {
                held[nheld++] = '+';
            } else {
                break;
            }
        }
        if (i < len) {                  // something other than "+++": flush
            send_all(remote, held, nheld);
            nheld = 0;
            send_all(remote, buf + i, len - i);
        }
    }
    last_local_ms = t;
}

// Called when the select timeout fires: decide whether held +++ was an escape.
static void check_guard(void) {
    if (nheld == 0 || now_ms() - last_local_ms < GUARD_MS) return;
    if (nheld == 3) {
        cmd_mode = 1;
        ncmd = 0;
        send_all(local, OK_MSG, sizeof OK_MSG - 1);
    } else {
        send_all(remote, held, nheld);  // lone '+' or '++': just data
    }
    nheld = 0;
}

int main(int argc, char **argv) {
    int lport = argc > 1 ? atoi(argv[1]) : 2323;
    int cport = argc > 2 ? atoi(argv[2]) : 1234;
    int lsock;
    char buf[4096];

    if (lport <= 0 || cport <= 0) {
        fprintf(stderr, "usage: %s [listen_port [connect_port]]\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    lsock = listen_on(lport);
    if (lsock < 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr, "listening on %d, serial port at localhost:%d\n", lport, cport);

    for (;;) {
        fd_set r;
        struct timeval tv = { GUARD_MS / 1000, (GUARD_MS % 1000) * 1000 };
        int maxfd = lsock, n;
        FD_ZERO(&r);
        FD_SET(lsock, &r);
        if (local >= 0) { FD_SET(local, &r); if (local > maxfd) maxfd = local; }
        if (remote >= 0) { FD_SET(remote, &r); if (remote > maxfd) maxfd = remote; }
        if (select(maxfd + 1, &r, NULL, NULL, nheld ? &tv : NULL) < 0) {
            if (errno == EINTR) continue;
            perror("select");
            return 1;
        }
        check_guard();

        if (FD_ISSET(lsock, &r)) {
            int fd = accept(lsock, NULL, NULL);
            if (fd < 0) continue;
            if (remote >= 0) {          // ponytail: one call at a time; busy
                close(fd);
            } else if ((local = connect_local(cport)) < 0) {
                fprintf(stderr, "serial port refused; rejecting caller\n");
                close(fd);              // reject the caller
            } else {
                remote = fd;
                cmd_mode = 0;
                nheld = ncmd = 0;
                last_local_ms = 0;
                send_all(local, CONNECT_MSG, sizeof CONNECT_MSG - 1);
                fprintf(stderr, "call connected\n");
            }
        }
        if (remote >= 0 && FD_ISSET(remote, &r)) {
            n = (int)read(remote, buf, sizeof buf);
            if (n <= 0) hangup();
            else if (!cmd_mode) send_all(local, buf, n);
            // ponytail: in command mode remote data is dropped, like a real
            // modem with no buffer; it would be forwarded after ATO anyway.
        }
        if (local >= 0 && FD_ISSET(local, &r)) {
            n = (int)read(local, buf, sizeof buf);
            if (n <= 0) {               // local closed: drop the caller too
                closefd(&local);
                closefd(&remote);
                fprintf(stderr, "serial port closed; call dropped\n");
            } else {
                from_local(buf, n);
            }
        }
    }
}
