#!/usr/bin/env python3
"""把 documenteditor 的 less 树预编译为 css/app.css（写入 rawfile）。

dev 模式 index.html 用 less.js 运行时编译 app.less，但源码树缺少
构建时生成的 sprites/*.less 与 vendor/bootstrap（bower 依赖），运行时编译必然失败。
本脚本替代官方 grunt 产物：
  1) 生成空的 sprites/*.less 占位（图标 sprite 类先缺失，后续可补 spritesmith 构建）
  2) 把 bootstrap less 拷入 rawfile/webapps/vendor/bootstrap（less 编译 import 需要）
  3) 用 node less（官方 documenteditor.json 的 modifyVars）编译 app.less -> css/app.css
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
RAW = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice')
WEB_APPS = os.path.join(RAW, 'webapps')
LESS_DIR = os.path.join(WEB_APPS, 'apps', 'documenteditor', 'main', 'resources', 'less')

SPRITES = [
    'iconssmall@1x', 'iconsbig@1x', 'iconshuge@1x',
    'iconssmall@1x.mod2', 'iconsbig@1x.mod2', 'iconshuge@1x.mod2',
    'iconssmall@2x', 'iconsbig@2x',
    'iconssmall@2x.mod2', 'iconsbig@2x.mod2',
    'iconssmall@1.25x', 'iconsbig@1.25x', 'iconshuge@1.25x',
    'iconssmall@1.25x.mod2', 'iconsbig@1.25x.mod2', 'iconshuge@1.25x.mod2',
    'iconssmall@1.5x', 'iconsbig@1.5x', 'iconshuge@1.5x',
    'iconssmall@1.5x.mod2', 'iconsbig@1.5x.mod2', 'iconshuge@1.5x.mod2',
    'iconssmall@1.75x', 'iconsbig@1.75x', 'iconshuge@1.75x',
    'iconssmall@1.75x.mod2', 'iconsbig@1.75x.mod2', 'iconshuge@1.75x.mod2',
    'iconshuge@2x', 'iconshuge@2x.mod2',
]

# 官方 documenteditor.json main.less.vars
MODIFY_VARS = {
    'app-image-const-path': "'../img'",
    'common-image-const-path': "'../../../../common/main/resources/img'",
    'app-image-path': "'../../../../../deploy/web-apps/apps/documenteditor/main/resources/img'",
    'common-image-path': "'../../../../../deploy/web-apps/apps/documenteditor/main/resources/img'",
}

BOOTSTRAP_SRC = '/tmp/onlyoffice_less/node_modules/bootstrap'

LESS_RUNNER = r"""
const fs = require('fs');
const less = require('/tmp/onlyoffice_less/node_modules/less');
const src = fs.readFileSync(process.argv[1], 'utf8');
const modifyVars = JSON.parse(process.argv[2]);
less.render(src, { filename: process.argv[1], modifyVars: modifyVars, compress: true, ieCompat: false })
  .then(out => fs.writeFileSync(process.argv[3], out.css))
  .catch(e => { console.error(e.message); process.exit(1); });
"""


def make_sprites():
    d = os.path.join(LESS_DIR, 'sprites')
    os.makedirs(d, exist_ok=True)
    for name in SPRITES:
        p = os.path.join(d, name + '.less')
        if not os.path.exists(p):
            with open(p, 'w', encoding='utf-8') as f:
                f.write('// sprites placeholder\n')
    print('sprites placeholders: %d' % len(SPRITES))


def copy_bootstrap():
    dst = os.path.join(WEB_APPS, 'vendor', 'bootstrap')
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(os.path.join(BOOTSTRAP_SRC, 'less'), os.path.join(dst, 'less'))
    print('bootstrap copied')


def compile_css():
    src = os.path.join(LESS_DIR, 'app.less')
    dest_dir = os.path.join(WEB_APPS, 'apps', 'documenteditor', 'main', 'resources', 'css')
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, 'app.css')

    node = subprocess.run(
        ['node', '-e', LESS_RUNNER, src, json.dumps(MODIFY_VARS), dest],
        cwd=ROOT, capture_output=True, text=True)
    if node.returncode != 0:
        print('less FAILED: %s' % (node.stderr + node.stdout)[-2000:])
        return False
    print('css compiled: %.0f KB' % (os.path.getsize(dest) / 1024))
    return True


def main():
    make_sprites()
    copy_bootstrap()
    return 0 if compile_css() else 1


if __name__ == '__main__':
    sys.exit(main())
