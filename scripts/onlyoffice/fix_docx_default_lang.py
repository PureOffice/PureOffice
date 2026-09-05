#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""规范化 docx 样本/模板的默认语言（docDefaults w:lang）为 zh-CN。

背景（2026-09-05 用户反馈「文档打开后被识别为俄文」）：
  rawfile 样本 sample.docx / demo-cn.docx 的 styles.xml docDefaults 为
  <w:lang w:val="ru-RU" w:eastAsia="en-US" w:bidi="ar-SA"/>——引擎「文档默认语言」
  取此值（Styles.js CLang / GetDefaultLanguage），UI「文档语言」「校验语言」随之
  显示俄语；编辑插入 run（asc_AddText 无 Pr）的 Lang.Val 亦取默认 → 1049。
  修复点 = 样本资产本身（正规化 docDefaults），非引擎适配。
    - 仅 docDefaults 段内 w:lang 替换（run 级 w:lang=1033 保留——正文自身语言声明）；
    - 兼容任意源语言（只认「含 eastAsia 属性的 style docDefaults lang」——docx 共性）；
    - 幂等：已 zh-CN 无变化即成功（exit 0）；无 styles.xml / 无 docDefaults 的文档属
      合法状态（引擎缺省非俄），报告跳过。

范围：rawfile/onlyoffice 下 sample*.docx / demo*.docx / templates/*.docx（自动发现，
新资产并入无需改列表）。templates/empty.docx 仅 3 部件无 styles.xml（跳过——
引擎缺省 1033 非俄）。

复现/用法：python3 scripts/onlyoffice/fix_docx_default_lang.py

另注（历史 origin，勿回退）：ru-RU docDefaults 来自官方样本 sdkjs 测试资产系列
（web-apps 时代样例自带），当时旧脚本全量拷贝未做语言规范化——此前多轮 M7 验证
跑在「俄语默认」下（M7AUTO-EDIT-OK 文本为 ASCII 未暴露差异）。
"""
import os
import re
import sys
import zipfile
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'onlyoffice')

# zh-CN | eastAsia zh-CN（bidi 保持 ar-SA：右向左语言与中文无关）
NEW_LANG = b'<w:lang w:val="zh-CN" w:eastAsia="zh-CN" w:bidi="ar-SA"/>'
DOC_DEFAULTS_RE = re.compile(rb'<w:docDefaults>.*?</w:docDefaults>', re.S)
LANG_INSIDE_DD_RE = re.compile(rb'<w:lang[^>/]*/>')


def fix_one(path: str) -> str:
    """就地规范化单个 docx；返回结果描述（'ok:1 处替换'/'已为中文'/'跳过：无 styles'）"""
    with zipfile.ZipFile(path, 'r') as z:
        names = z.namelist()
        if 'word/styles.xml' not in names:
            return 'skip: no word/styles.xml'
        styles = z.read('word/styles.xml')

    def fix(m: re.Match) -> bytes:
        # 只重写 docDefaults 内的 w:lang（run/section 级语言声明不受影响）
        return LANG_INSIDE_DD_RE.sub(NEW_LANG, m.group(0))

    new_styles = DOC_DEFAULTS_RE.sub(fix, styles)
    if new_styles == styles:
        return 'ok: 已预设中文（无变化）'

    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        with zipfile.ZipFile(path, 'r') as src:
            for item in src.infolist():
                z.writestr(item, src.read(item.filename)
                           if item.filename != 'word/styles.xml' else new_styles)

    shutil.move(tmp, path)

    n = len(LANG_INSIDE_DD_RE.findall(new_styles))
    if b'zh-CN' not in new_styles:
        raise SystemExit('规范化后样式流不含 zh-CN：%s' % path)
    return 'ok: %d 处 w:lang → zh-CN' % n


def main() -> int:
    # 样本集中 at rawfile/onlyoffice/smoke/（2026-09-06 用户：smoke 文件单独目录；
    # 原 RAW 根扫描 sample*/demo* 已随移动失效）
    docs = []
    smk = os.path.join(RAW, 'smoke')
    if os.path.isdir(smk):
        docs += [os.path.join(smk, f) for f in sorted(os.listdir(smk))
                 if f.endswith('.docx') and (f.startswith('sample') or f.startswith('demo'))]
    tpl = os.path.join(RAW, 'templates')
    if os.path.isdir(tpl):
        docs += [os.path.join(tpl, f) for f in sorted(os.listdir(tpl)) if f.endswith('.docx')]

    n_ok = n_skip = 0
    for p in docs:
        r = fix_one(p)
        print('%-40s %s' % (os.path.basename(p), r))
        if r.startswith('ok'):
            n_ok += 1
        else:
            n_skip += 1
    if n_ok == 0 and n_skip < len(docs):
        raise SystemExit('无文档被规范化——异常（报告上游）')
    print('done: %d 规范化 / %d 跳过' % (n_ok, n_skip))
    return 0


if __name__ == '__main__':
    sys.exit(main())
