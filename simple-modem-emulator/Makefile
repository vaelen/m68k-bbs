# Copyright 2026, Andrew C. Young <andrew@vaelen.org>
# SPDX-License-Identifier: MIT

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

modem: modem.c
	$(CC) $(CFLAGS) -o $@ $<

test: modem
	./test.sh

clean:
	rm -f modem

.PHONY: test clean
