#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract&save the official AscDesktopEditor method list.

Source of truth: ONLYOFFICE desktopeditors desktop-sdk
  ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp
  (EXTEND_METHODS_COUNT / methods[] V8 registration table, OnContextCreated)

Output: scripts/onlyoffice/desktop/asc_methods.txt  (one per line)
"""
import re, os, sys

SRC = None
for cand in [
    '/data/share/office/.temp/desktop-sdk/ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp',
]:
    if os.path.exists(cand):
        SRC = cand
        break

if not SRC:
    print('source not found', file=sys.stderr)
    sys.exit(1)

src = open(SRC, encoding='utf-8', errors='replace').read()
m = re.search(r'EXTEND_METHODS_COUNT\s+\d+\s*\n\s*const char\* methods\[\w*\]?\s*=\s*\{(.*?)\s*NULL\s*\};', src, re.S)
assert m, 'methods[] table not found'
names = re.findall(r'"([^"]+)"', m.group(1))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'asc_methods.txt')
open(out, 'w').write('\n'.join(names) + '\n')
print(f'{len(names)} methods -> {out}')
