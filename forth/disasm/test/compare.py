#!/usr/bin/env python3
"""Compare two harness results case by case (mnemonic text AND consumed
length).  The shared core must print byte-identical text in every
environment; any difference means a port leaked into the core (cell size,
case, a missing mask).  Usage: compare.py a.json b.json   (exit 1 on diff)
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse import parse

a, b = (json.load(open(p)) for p in sys.argv[1:3])
(ta, la), (tb, lb) = parse(a['chunks']), parse(b['chunks'])
diff = [k for k in sorted(set(ta) | set(tb))
        if (ta.get(k), la.get(k)) != (tb.get(k), lb.get(k))]
print("%s vs %s: %d cases, %d differ" % (a['env'], b['env'], len(ta), len(diff)))
for k in diff[:20]:
    print("  %04X  %s|%s   vs   %s|%s" % (k, ta.get(k), la.get(k), tb.get(k), lb.get(k)))
sys.exit(1 if diff or not ta else 0)
