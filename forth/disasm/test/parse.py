"""Turn a harness transcript into {addr: (text, consumed_len)}."""
import re


def parse(chunks):
    out, lens = {}, {}
    for text in chunks:
        for l in text.replace('\r', '').split('\n'):
            m = re.search(r'([0-9A-F]{4}): (.*)\|(\d+) *$', l)
            if m:
                a = int(m.group(1), 16)
                out[a] = m.group(2).strip()
                lens[a] = int(m.group(3))
    return out, lens
