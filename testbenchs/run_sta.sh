#!/bin/bash
ssh tycho "cd Projects/z80fp/MrZ80 && docker run --rm -v .:/build -w /build ghcr.io/raetro/quartus:17.0 quartus_sta -t $1" > /tmp/opencode/sta.log 2>&1
grep -E "Error|Critical Warning" /tmp/opencode/sta.log | head -20
