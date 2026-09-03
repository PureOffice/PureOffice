#!/usr/bin/env python3
"""POC-2: ONLYOFFICE qmake(.pro/.pri) -> CMake 源列表转换器（最小解析器）。

只处理我们需要的子集：SOURCES/HEADERS/INCLUDEPATH/DEFINES/LIBS/TARGET/CONFIG/包含的 .pri。
平台：跳过 core_windows/core_mac/core_ios/win32/mac/ios 块；保留 linux/无块（linux 分支用 CLANG 版统一）。
用法: qmake2cmake.py <module.pro> [-o out.txt]
"""
import re
import sys
import os
import glob
import fnmatch


class Parser:
    def __init__(self):
        self.sources = []   # (abspath, base)
        self.headers = []
        self.includes = []  # include dirs (abspath)
        self.defines = []
        self.libs = []
        self.target = None
        self.template = None
        self.configs = []
        self.vars = {}      # qmake KEY = value 赋值表（$$KEY 展开用）
        # `!xxx {` 否定条件块：本移植预定义 xxx 为空（= 整块不参与）
        self.disabled_neg_blocks = set()
        # `xxx { } else { }` 的 else 分支剥离名单（官方 else 条件树中本移植走 then 分支）：
        # name ∈ skip_else_keys → 剥 else、留 then（条件为真）
        self.skip_else_keys = set()
        # 反向：then 分支剥离名单（官方默认无该 CONFIG → 走 else）：
        # name ∈ skip_then_keys → 剥 then、留 else
        self.skip_then_keys = set()

    def parse(self, path):
        self.main_base = os.path.dirname(os.path.abspath(path))
        self._parse_file(path, path)

    def _parse_file(self, path, first_path):
        try:
            text = open(path, encoding='utf-8', errors='ignore').read()
        except OSError:
            print(f'   [unreadable] {path}', file=sys.stderr)
            return
        base = os.path.dirname(os.path.abspath(path))
        # 去除注释（qmake 行注释 #，但保留行尾? https://... 有双斜线注释）
        lines = text.split('\n')
        # 平台块预处理：把 core_windows/core_mac/core_ios/win32/mac/ios 块剥离
        lines = self._strip_platform_blocks(lines)
        i = 0
        while i < len(lines):
            ln = lines[i]
            # 续行：以 "\" 结尾
            while ln.rstrip().endswith('\\') and i + 1 < len(lines):
                i += 1
                ln = ln.rstrip()[:-1] + ' ' + lines[i]
            i += 1
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            # qmake 变量赋值：KEY = value（供后续 $$KEY 展开；+= 不在此列）。
            # qmake 语义是“赋值即时展开”——$$PWD 意指当前 .pri 所在目录，赋值时必须
            # 立即按当前文件 base 解算（否则 vars 存原文，跨文件引用时会被错误 base 展开）
            m = re.match(r'^([A-Za-z_]\w*)\s*=\s*(.*?)\s*$', ln)
            if m and '=' not in m.group(2).split('#')[0]:
                self.vars[m.group(1)] = self._expand(m.group(2), base)
                continue
            # qmake 单行前缀条件：`scope:command`（等价块式 `scope { command }`），
            # 如 filetransporter.pri:55 `core_linux:CONFIG += use_external_transport`
            # 与 :58 `use_external_transport:DEFINES += USE_EXTERNAL_TRANSPORT`
            # （61 行 `!use_external_transport:include(curl.pri)` 同理）。
            # CONFIG 项形 scope（use_external_transport）按已累积 configs 判定——
            # 前置 `CONFIG +=`（55 行）先于使用处（58 行），顺序正确。
            m = re.match(r'^(!?[A-Za-z_]\w*):(.*)$', ln)
            if m:
                neg = m.group(1).startswith('!')
                name = m.group(1).lstrip('!')
                if self._scope_is_true(name) != neg:
                    ln = m.group(2).strip()
                else:
                    continue
            m = re.match(r'^(SOURCES|HEADERS|INCLUDEPATH|DEFINES|LIBS)\s*\+?=\s*(.*)$', ln)
            if m:
                key, rest = m.group(1), m.group(2)
                for item in self._tokens(rest):
                    item = item.strip()
                    if not item or item.startswith('#'):
                        continue
                    if key == 'SOURCES':
                        self._add_file(item, base, self.sources)
                    elif key == 'HEADERS':
                        self._add_file(item, base, self.headers)
                    elif key == 'INCLUDEPATH':
                        self.includes.append(self._resolve(item, base))
                    elif key == 'DEFINES':
                        d = item.strip().strip('\\')
                        if d.startswith('#'):
                            continue
                        if d:
                            self.defines.append(d)
                    elif key == 'LIBS':
                        self.libs.append(item)
                continue
            # qmake `-=`（从累积列表移除，openjpeg.pri 的 `SOURCES -= $$files(.../bench_*, false)`
            # 排除官方测试/工具 .c；qmake 通配可匹配路径任意段，近似实现 basename+相对路径 fnmatch）
            m = re.match(r'^(SOURCES|HEADERS|INCLUDEPATH|DEFINES|LIBS)\s*-=\s*(.*)$', ln)
            if m:
                key, rest = m.group(1), m.group(2)
                for item in self._tokens(rest):
                    self._remove_glob(key, self._expand(item.strip(), base))
                continue
            m = re.match(r'^include\((.*)\)$', ln)
            if m:
                inc_path = self._resolve(m.group(1).strip().strip('"'), base)
                # 跳过平台框架 pri（base.pri 自建、opengl/win_defs 不适用）；
                # 注意：apple.pri 不是平台框架——它是 iwork 依赖（librevenge/libodfgen/
                # libetonyek）的源码清单入口，必须参与解析（IWorkFile 需要其 SOURCES）
                bn = os.path.basename(inc_path)
                if bn in ('base.pri', 'opengl.pri', 'win_defs.pri'):
                    continue
                if os.path.exists(inc_path):
                    self._parse_file(inc_path, '')
                continue
            m = re.match(r'^TARGET\s*=\s*(.*)$', ln)
            if m:
                self.target = m.group(1).strip()
            m = re.match(r'^TEMPLATE\s*=\s*(.*)$', ln)
            if m:
                self.template = m.group(1).strip()
            m = re.match(r'^CONFIG\s*\+?=\s*(.*)$', ln)
            if m:
                self.configs.extend(m.group(1).split())

    def _strip_platform_blocks(self, lines):
        """剥离平台/调试块（支持 `core_windows {` 同行 与 `core_windows` 换行 `{` 两种形式）。
        剥：core_windows/core_mac/core_ios/win32/mac/ios/core_android/core_debug/debug + 内容；
        保：core_release/release 块内容（仅去装饰行）。
        条件块语义：`XXX { ... } else { ... }` —— XXX 未识别为 keep 时 then 分支无条件采纳
        （qmake scope 近似）；else 分支仅当 XXX 属于 skip_else_keys 才剥离（取反条件为假）。"""
        out = []
        skip_depth = 0
        skip_keys = r'\b(core_windows|core_mac|core_ios|win32|mac|ios|core_android|apple_silicon|bundle_dylibs|support_bundle_dylibs|core_debug|debug|support_heif|build_xp|use_openssl_hash)\b'
        # use_openssl_hash：官方默认关闭（PdfFile.pro 中 `#CONFIG += use_openssl_hash` 注释留着，
        # 3dParty/openssl 源码须另行下载构建）；xpdf 自带 SHA-512 实现，剥离后行为不变
        keep_keys = r'\b(core_release|release)\b'
        cond_stack = []  # [(name, in_else_skip)] 已识别条件块（跳过平台/keep 块之外的）
        # skip 锚栈：decode 被跳过块作用域——平台/裁剪块入口压 '__platform'/'__neg'，
        # 跳过中的普通内层块压 '__inner'。职责：
        #   `} else {` 净深度为零，必须判断它属于谁——内层块 else（继续跳过）vs
        #   平台块自身 else（恢复，如 freetype.pri 的 builds/unix/ftsystem.c）vs
        #   neg 裁剪块自身 else（整块吞掉，如 js_base.pri 的 v8 面）。
        # 修正(openssl.pri)：平台块内的嵌套普通块后跟 `} else {` 属内层（继续跳过），
        # 若仅按“栈顶是平台”触发恢复会错误改写 OPENSSL_LIBS_DIRECTORY 等赋值。
        skip_anchor = []  # ['__platform' | '__neg' | '__inner']
        for ln in lines:
            s = ln.strip()
            m_else = re.match(r'^}\s*else\s*\{\s*$', s)
            if skip_depth:
                if m_else:
                    # `} else {`：净深度零，归属由锚栈顶判定
                    if skip_anchor and skip_anchor[-1] == '__platform':
                        skip_anchor.pop()
                        skip_depth = 0
                        continue
                    if skip_anchor and skip_anchor[-1] == '__inner':
                        continue
                    # '__neg' 或无需恢复的兜底：else 继续跳过
                    continue
                # 普通行（纯 `{`/`}` 增减深度；普通内容行零）
                d = s.count('{') - s.count('}')
                if d > 0:
                    for _ in range(d):
                        skip_anchor.append('__inner')
                elif d < 0:
                    for _ in range(-d):
                        if skip_anchor:
                            skip_anchor.pop()
                skip_depth += d
                if skip_depth <= 0:
                    skip_depth = 0
                continue
            # else 分支切换：`} else {`
            if m_else:
                if cond_stack:
                    name, _ = cond_stack[-1]
                    cond_stack[-1] = (name, name in self.skip_else_keys)
                    if cond_stack[-1][1]:
                        skip_depth = 1
                continue
            # 普通条件块入口行：`xxx {`（非平台/keep/neg 已在上层处理）
            m = re.match(r'^([A-Za-z_]\w*)\s*\{\s*$', s)
            if m:
                name = m.group(1)
                # neg 条件（跳过名单）与平台块走 skip_depth：由上层逻辑先处理不了——
                # 平台块是 skip_keys 正则，这里只接收“条件按真处理”的分支
                if re.search(skip_keys, name) or name in keep_keys:
                    pass
                else:
                    in_then_skip = name in self.skip_then_keys
                    cond_stack.append((name, in_then_skip))
                    if in_then_skip:
                        skip_depth = 1
                        skip_anchor.append('__platform')  # else 分支恢复锚点
                        continue
                    continue
            # 闭合 `}`（对应之前压栈的普通条件块；平台块由 skip_depth 消化）
            if s == '}' and cond_stack:
                cond_stack.pop()
                continue
            # 否定条件块：`!use_all_in_one { ... } else { ... }`。
            # disabled_neg_blocks（裁剪面）→ 整块跳过；否则压 cond_stack（qmake scope 近似：
            # !KEY 未定义 → then 分支为真采纳；else 分支是否剥离交给 skip_else_keys 名册，
            # 以 '!'+KEY 记录（openjpeg.pri 的 else=unity 入口 opj_engine.cpp，官方默认不走））
            m = re.match(r'^!(\w+)\s*\{$', s)
            if m:
                if m.group(1) in self.disabled_neg_blocks:
                    skip_depth = 1
                    skip_anchor.append('__neg')  # 整块（含其 else）跳过
                    continue
                cond_stack.append(('!' + m.group(1), False))
                continue
            # 同行块声明：`xxx {`
            if re.search(skip_keys, s) and s.endswith('{'):
                skip_depth = 1
                skip_anchor.append('__platform')  # else 分支恢复锚点
                continue
            if re.search(keep_keys, s) and s.endswith('{') and not s.startswith('else'):
                continue  # release 块：去装饰，内容留下
            # 换行块声明：上一行是声明、本行 `{`
            if s == '{':
                if out and re.match(r'^!(\w+)$', out[-1].strip()) \
                        and re.match(r'^!(\w+)$', out[-1].strip()).group(1) in self.disabled_neg_blocks:
                    skip_depth = 1
                    out.pop()
                    skip_anchor.append('__neg')
                    continue
                if out and re.search(skip_keys, out[-1]):
                    skip_depth = 1
                    out.pop()
                    skip_anchor.append('__platform')  # else 分支恢复锚点
                    continue
                if out and re.search(keep_keys, out[-1]):
                    out.pop()
                    continue
            out.append(ln)
        return out

    def _remove_glob(self, key, pat):
        """qmake `-= filter`：从已累积列表移除匹配项（通配可在路径任意段）。"""
        def fit(p):
            if '*' not in pat:
                pn = os.path.normpath(p)
                return pn == os.path.normpath(pat) or pn == os.path.normpath(os.path.join(self.main_base, pat))
            b = os.path.basename(p).replace(os.sep, '/')
            r = os.path.relpath(p, self.main_base).replace(os.sep, '/')
            return (fnmatch.fnmatch(b, pat) or fnmatch.fnmatch(r, pat)
                    or fnmatch.fnmatch(p.replace(os.sep, '/'), pat))
        if key in ('SOURCES', 'HEADERS'):
            lst = self.sources if key == 'SOURCES' else self.headers
            lst[:] = [t for t in lst if not fit(t[0])]
        elif key == 'INCLUDEPATH':
            self.includes = [i for i in self.includes if not fit(i)]

    def _expand(self, item, base):
        # 递归展开：$$PWD / $$CORE_ROOT_DIR 优先（未知 $$KEY -> 空，同 qmake 语义），
        # 再依次 $$files(p,true) / $${KEY} / $$KEY（vars 值可再含 $$，循环展开）
        for _ in range(6):
            old = item
            # \b 防止 $$PWD_CUR 之类被 $$PWD 前缀吃掉
            item = re.sub(r'\$\$PWD\b', base, item)
            item = re.sub(r'\$\$CORE_ROOT_DIR\b', self._core_root(), item)
            m = re.search(r'\$\$files\((.*?)\)', item)
            if m:
                parts = m.group(1).split(',')
                pattern = parts[0].strip()
                if len(parts) > 1 and 'true' in parts[1]:
                    # 递归：首个含 * 的目录段改为 **/（配合 recursive=True）
                    segs = pattern.split('/')
                    for i, s in enumerate(segs):
                        if '*' in s:
                            segs[i] = '**/' + s
                            break
                    pattern = '/'.join(segs)
                item = item[:m.start()] + pattern + item[m.end():]
            else:
                m = re.search(r'\$\$\{(\w+)\}', item)
                if m:
                    item = item[:m.start()] + self.vars.get(m.group(1), '') + item[m.end():]
                else:
                    m = re.search(r'\$\$(\w+)', item)
                    if m:
                        item = item[:m.start()] + self.vars.get(m.group(1), '') + item[m.end():]
            if item == old:
                break
        return os.path.normpath(item)

    def _scope_is_true(self, name):
        """qmake scope 真值判定（本移植 = OHOS/Linux 语义）。
        平台 scope：linux/core_linux/unix 真；win/mac/ios/android 假。
        CONFIG 项 scope（use_external_transport 等）：查已累积 CONFIG 列表。"""
        if name in ('linux', 'core_linux', 'unix'):
            return True
        if name in ('win32', 'core_windows', 'mac', 'core_mac', 'core_ios', 'ios',
                    'core_android', 'android'):
            return False
        return name in self.configs

    @staticmethod
    def _tokens(s):
        """按空白切分，但跳过括号内的空白（如 $$files(lib/*.h, true)）。"""
        toks, cur, depth = [], '', 0
        for ch in s:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch.isspace() and depth == 0:
                if cur:
                    toks.append(cur)
                    cur = ''
                continue
            cur += ch
        if cur:
            toks.append(cur)
        return toks

    def _core_root(self):
        cur = os.path.normpath(self.main_base)
        while cur != os.path.dirname(cur):
            if os.path.basename(cur) == 'core':
                return cur
            cur = os.path.dirname(cur)
        return os.path.dirname(os.path.dirname(self.main_base))

    def _resolve(self, item, base):
        """qmake 路径裁决：先相对主 pro 目录，再相对当前文件目录（存在者取先）。"""
        p = self._expand(item, base)
        if os.path.isabs(p):
            return p
        cands = [os.path.join(self.main_base, p), os.path.join(base, p)]
        for c in cands:
            if os.path.exists(c):
                return os.path.normpath(c)
        return os.path.normpath(cands[0])

    def _add_file(self, item, base, lst):
        p = self._resolve(item, base)
        if '*' in p:
            # qmake 通配符：展开为实际文件（含 ** 时递归）
            hits = sorted(glob.glob(p, recursive=True))
            non_dir = [h for h in hits if not os.path.isdir(h)]
            if non_dir:
                for h in non_dir:
                    lst.append((h, os.path.relpath(h, core_root_of(h))))
                return
            print(f'   [missing*] {p}', file=sys.stderr)
            return
        if os.path.exists(p):
            lst.append((p, os.path.relpath(p, core_root_of(p))))
        elif p.endswith(('.c', '.cpp', '.cc', '.h')):
            # 大小写不敏感重试：本仓库有 Windows 大小写文件名与 Linux 磁盘不一致的
            # 少数文件（如 metafile.pri 的 CWmfInterpretator.cpp → 磁盘 cwmfinterpretator.cpp），
            # 官方 qmake 在 Win 编译通过，Linux 需修正大小写
            dirn, base = os.path.split(p)
            if os.path.isdir(dirn):
                for cand in sorted(os.listdir(dirn)):
                    if cand.lower() == base.lower() and cand != base:
                        real = os.path.join(dirn, cand)
                        lst.append((real, os.path.relpath(real, core_root_of(real))))
                        print(f'   [casefix] {p} -> {real}', file=sys.stderr)
                        return
            print(f'   [missing] {p}', file=sys.stderr)


def core_root_of(p):
    cur = os.path.normpath(p)
    while cur != cur.split(os.sep)[0] + os.sep and os.path.basename(cur) != 'core':
        cur = os.path.dirname(cur)
        if not cur or os.path.basename(cur) == 'core':
            return cur
    return cur


def main():
    if len(sys.argv) < 2:
        print('usage: qmake2cmake.py <pro-file>', file=sys.stderr)
        return 1
    p = Parser()
    p.parse(sys.argv[1])
    out = sys.stdout
    if '-o' in sys.argv:
        out = open(sys.argv[sys.argv.index('-o') + 1], 'w')
    core = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1])))) or 'core'
    if os.path.basename(core) != 'core':
        core = os.path.abspath(sys.argv[1])
        while os.path.basename(core) != 'core' and core != '/':
            core = os.path.dirname(core)
    print('TARGET:', p.target, '| TEMPLATE:', p.template, '| CONFIG:', ' '.join(p.configs[:8]), file=out)
    print(f'SOURCES({len(p.sources)}) HEADERS({len(p.headers)}) INCLUDES({len(p.includes)}) DEFINES({len(p.defines)}) LIBS({len(p.libs)})', file=out)
    def rel(src):
        try:
            return os.path.relpath(src, core)
        except ValueError:
            return src
    print('--- sources ---', file=out)
    for s, _ in p.sources:
        print(rel(s), file=out)
    print('--- includes ---', file=out)
    for inc in sorted(set(p.includes)):
        # 已存在的目录才输出
        if os.path.isdir(inc):
            print(rel(inc), file=out)
    print('--- defines ---', file=out)
    for d in sorted(set(p.defines)):
        print(d, file=out)
    print('--- libs ---', file=out)
    for l in sorted(set(p.libs)):
        print(l, file=out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
