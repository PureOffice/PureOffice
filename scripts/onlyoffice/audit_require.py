#!/usr/bin/env python3
"""静态审计：扫描 rawfile/webapps 下已拷入的 .js 文件中 require('x')/requirejs 依赖线，
    检查每个 require 片段对应的文件是否存在于 rawfile 树中（POC 调试用，一次抓全 404）。"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
RAW_WEB = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice', 'webapps')

# require('x') / require("x") / require(['a','b']) / require([...], cb)
SINGLE_RE = re.compile(r"require\(\s*[\"']([^\"']+)[\"']\s*[,)]", re.S)
LIST_RE = re.compile(r"require\(\s*\[([^\]]*?)\]", re.S)


def find_requires(text: str):
    out = set()
    for m in LIST_RE.finditer(text):
        for a in re.findall(r"[\"']([^\"']+)[\"']", m.group(1)):
            out.add(a)
    for m in SINGLE_RE.finditer(text):
        out.add(m.group(1))
    return out


def resolve(mod, base_dir):
    """按 baseUrl=webapps/apps + paths 约定把模块名解析到相对 webapps 的路径（不带扩展名）"""
    if mod.startswith('text!'):
        mod = mod[5:]
    if mod.startswith('../'):
        mod = '../' + mod  # 罕见
    return mod


def main():
    missing = {}
    # 1) app_dev.js 的 require.config paths + require 列表
    appdev = os.path.join(RAW_WEB, 'apps', 'documenteditor', 'main', 'app_dev.js')
    with open(appdev, 'r', encoding='utf-8') as f:
        cfg = f.read()

    # 简单解析 paths 映射（key : 'value'，相对 baseUrl=apps/）
    paths = dict(re.findall(r"(\w+)\s*:\s*'([^']+)'", cfg))

    mods = find_requires(cfg)

    # 2) 扫描所有已拷 js 文件里的 require(...)
    for root, _, files in os.walk(RAW_WEB):
        for fn in files:
            if not fn.endswith('.js'):
                continue
            p = os.path.join(root, fn)
            with open(p, 'r', encoding='utf-8', errors='ignore') as f:
                t = f.read()
            for m in find_requires(t):
                if m.startswith(('common/', 'documenteditor/', 'api/', 'core', 'notification',
                                 'irregularstack', 'gateway', 'analytics', 'locale', 'perfectscrollbar',
                                 'und', 'backbone', 'jquery', 'xregexp', 'socketio', 'text', 'tip',
                                 'keymaster', 'localstorage')):
                    mods.add(m)

    # 3) 解析：paths 覆盖前缀
    for mod in sorted(mods):
        seg = mod.split('/')[0]
        # base 相对 webapps 目录
        if seg in paths:
            rel = paths[seg] + '/' + mod.split('/', 1)[1] if '/' in mod else paths[seg]
        else:
            rel = mod
        # rel 形如 'common/main/lib/util/Tip'（相对 apps/）或 '../vendor/socketio/socket.io.min'（相对 webapps/）
        base = RAW_WEB if rel.startswith('../') else os.path.join(RAW_WEB, 'apps')
        rel = rel.replace('../', '')
        cand = os.path.join(base, rel + '.js')
        # 若为目录 index 形式也检查
        cand2 = os.path.join(base, rel, 'index.js')
        if not os.path.exists(cand) and not os.path.exists(cand2):
            missing.setdefault(mod, []).append(rel)

    if missing:
        print('!! MISSING modules:')
        for mod, rels in missing.items():
            print('  %-50s -> %s.js' % (mod, rels[0]))
        sys.exit(1)
    print('OK: no missing module files (path-mapped)')


if __name__ == '__main__':
    main()
