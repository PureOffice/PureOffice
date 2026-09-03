#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract the official AscDesktopEditor InitJSContext JS shim from desktop-sdk C++.

Source: ONLYOFFICE ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp
  block: from `std::string sCodeInitJS =`  →  `_frame->ExecuteJavaScript(sCodeInitJS`

Output: scripts/onlyoffice/desktop/ascdesktop_shim_raw.js

Line pattern (C++ source verbatim):
  \t\t\t\t\tstd::string sCodeInitJS = "\
  window.AscDesktopEditor.CreateEditorApi = function(api) {\n\
  ...content...\n\
  sCodeInitJS += "…"\n\    (append section, optional)
  sCodeInitJS += "\
  …content…\n\
  "
Each content line:  [prefix] + content + "  + \  (C++ line continuation),
where content uses C escapes: \n  \"  \\ .

Decoder: for every quoted literal between the block boundaries, take the
  text after = "  (or += "  or a bare continuation line) up to the trailing  ",
  and decode C escapes.  Continuation lines are exactly `"` (or `"\`).
"""
import os, sys

SRC = '/data/share/office/.temp/desktop-sdk/ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ascdesktop_shim_raw.js')

src = open(SRC, encoding='utf-8', errors='replace').read()
i = src.index('std::string sCodeInitJS = "')
j = src.index('_frame->ExecuteJavaScript(sCodeInitJS', i)
block = src[i:j]

# Split at C++ line ends (\n) — each physical line:
#   a) "std::string sCodeInitJS = "\            → literal start, content follows
#   b) "...content...\n\"  or "...content..."    → content
#   c) sCodeInitJS += "...content..." " or "\    → append section
#   d) bare " or "\                              → empty continuation
literals = []
for ln in block.split('\n'):
    t = ln.rstrip()
    # Remove leading whitespace (keep the quotes marked)
    t = t.lstrip()
    if not t:
        continue
    # For a) and c): take substring after the first double-quote char
    # For b): the whole line is the literal content BUT it ends with "  or "\
    if t.startswith('std::string sCodeInitJS = "'):
        t = t[len('std::string sCodeInitJS = "'):]
    elif t.startswith('sCodeInitJS += "'):
        t = t[len('sCodeInitJS += "'):]
    # Now t is either:  window...\n\   (with trailing quote+backslash at end)
    # or our content already, but might end with the literal-ending "  "\
    while True:
        # Content lines end with:  "\            → drop quotes+backslash
        # Empty literal is:  "                    → drop
        # A chunk from a)  ends with "  plus backslash → drop
        if t.endswith('"\\'):
            t = t[:-2]
        elif t.endswith('"'):
            t = t[:-1]
        else:
            break
    if t:
        literals.append(t)

def decode(lit):
    """Decode C escape sequences: \n→LF, \"→", \\→\, \t→TAB."""
    out = []
    i = 0
    while i < len(lit):
        c = lit[i]
        if c == '\\' and i + 1 < len(lit):
            nxt = lit[i+1]
            m = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}
            out.append(m.get(nxt, '\\' + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)

shim = ''.join(decode(l) for l in literals)
open(OUT, 'w', encoding='utf-8').write(shim + '\n')
print(f'{len(shim)} chars -> {OUT}')
