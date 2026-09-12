#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成"新建"空模板：rawfile/onlyoffice/templates/empty.docx / empty.xlsx / empty.pptx

背景（2026-09-05 用户报修）：欢迎页新建电子表格显示"不像空白表格"——C 列很宽、
绿色形状、工作表名 "Other"。根因：旧版脚本仅清空 sheetData，**保留了样本视觉残留**
（cols 列宽定义/形状/drawing 关系/工作表名）。此版重写。

方案（骨架合法 + 部件重写，而非手工拼最小包）：
  - xlsx 骨架：third_party/core submodule 的官方测试素材
    OOXML/test/ExampleFiles/xlsx2xlsb/simple1.xlsx（10 部件标准最小结构，主题/样式
    经官方 core 解析保证合法）。已拷入 templates_src/simple1.xlsx（仓库跟踪），
    **不依赖 submodule 已克隆**——fresh env 可直接跑本脚本。
    重写 5 个部件为真空白：workbook.xml（单 sheet 名 Sheet1）、sheet1.xml（默认
    列宽、无 dimension 内容、A1 选中）、sharedStrings.xml（空 sst）、docProps/core.xml
    （无作者）、docProps/app.xml（Sheet1）。其余部件（theme/styles/rels/
    Content_Types）原样保留——它们与本产物部件声明一致（Content_Types 已声明这些
    Override，无需改动）。
  - pptx 骨架：sdkjs 幻灯片主题库的空白主题（web-apps/deploy/sdkjs/slide/themes/
    src/01_blank.pptx —— ONLYOFFICE 服务器端"新建演示"默认资源；已拷入
    templates_src/blank.pptx，仓库跟踪，不依赖 submodule/deploy 产物）。
    结构：标准 11 版式（Title Slide/Title and Content/Two Content/Comparison/
    Section Header/Title Only/Blank/Content with Caption/Picture with Caption/
    Vertical Title/Title and Vertical Text）+ 单张纯空白首滑（ctrTitle/subTitle
    占位，无文本无装饰）+ notesMaster/主题全集。仅清理 docProps/core.xml
    （作者/标题残留）与缩略图。
  - docx 骨架：templates_src/empty.docx（3 部件最小包——2026-09-04 手搓时
    "新建 word"模板，真机验证引擎可开、无视觉残留；本脚本在其基础上**追加
    word/styles.xml**（docDefaults 全段照抄 demo-cn.docx——文档默认中文的
    唯一机制：demo-cn 无 run 级声明、全文按 docDefaults 识别/渲染为中文，
    用户真机确认过）并补 [Content_Types].xml / _rels/.rels 声明）。
    **不要**在 word/document.xml 里写 rFonts/语言：run 级声明会覆盖 docDefaults，
    且与 demo-cn 的正样本语义（docDefaults 承载）脱节。

旧实现回顾（避免按旧经验修）：
  - xlsx 旧版：基于 sample.xlsx 清 sheetData——sample.xlsx 含 14 部件
    （drawings/vmlDrawing/comments/printerSettings 等样本残留），"内容清空"仍
    开出样本框架；已否决。
  - pptx 旧版：基于 sample.pptx 清文本——sample 骨架只有 1 个 slideLayout，
    "添加幻灯片"版式列表只剩 Blank 一种（2026-09-05 用户报修）；已否决。

复现：python3 scripts/onlyoffice/make_empty_templates.py（输出模板即 HAP 打包来源；
修改模板后须重新构建 HAP 才生效，rawfile 目录随 HAP 走）

用法：python3 scripts/onlyoffice/make_empty_templates.py
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_DIR = os.path.join(ROOT, 'scripts', 'onlyoffice', 'templates_src')
SRC_XLSX = os.path.join(SRC_DIR, 'simple1.xlsx')
SRC_PPTX = os.path.join(SRC_DIR, 'blank.pptx')
SRC_DOCX = os.path.join(SRC_DIR, 'empty.docx')
DST_DIR = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile',
                       'onlyoffice', 'templates')
DST_W = os.path.join(DST_DIR, 'empty.docx')
DST_X = os.path.join(DST_DIR, 'empty.xlsx')
DST_P = os.path.join(DST_DIR, 'empty.pptx')

# —— 真空白部件内容（标准 OOXML，无微软扩展 namespace）——
# sheet1：默认列宽（无 <cols>）、无单元格（sheetData 空）、A1 选中 ——
# "新建表格"的官方语义（Excel 新建亦然：dimension A1 + sheetData 空）
BLANK_SHEET1 = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<dimension ref="A1"/>'
    '<sheetViews><sheetView tabSelected="1" workbookViewId="0">'
    '<selection activeCell="A1" sqref="A1"/></sheetView></sheetViews>'
    '<sheetFormatPr defaultRowHeight="15"/>'
    '<sheetData/>'
    '<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>'
    '</worksheet>\n'
)
BLANK_WORKBOOK = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<fileVersion appName="xl" lastEdited="7" lowestEdited="7" rupBuild="22527"/>'
    '<workbookPr/><bookViews><workbookView xWindow="0" yWindow="0"'
    ' windowWidth="25820" windowHeight="15620"/></bookViews>'
    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
    '<calcPr calcId="0"/></workbook>\n'
)
BLANK_SST = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    ' count="0" uniqueCount="0"></sst>\n'
)
BLANK_PROP_CORE = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/'
    'metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"'
    ' xmlns:dcterms="http://purl.org/dc/terms/"'
    ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    '<dc:creator></dc:creator><cp:lastModifiedBy></cp:lastModifiedBy>'
    '</cp:coreProperties>\n'
)
BLANK_PROP_APP = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/'
    'extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/'
    '2006/docPropsVTypes"><Application>Microsoft Excel</Application>'
    '<HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant>'
    '<vt:lpstr>Sheets</vt:lpstr></vt:variant><vt:variant><vt:i4>1</vt:i4>'
    '</vt:variant></vt:vector></HeadingPairs>'
    '<TitlesOfParts><vt:vector size="1" baseType="lpstr">'
    '<vt:lpstr>Sheet1</vt:lpstr></vt:vector></TitlesOfParts>'
    '<AppVersion>16.0300</AppVersion></Properties>\n'
)

# —— docx 空模板：styles.xml 内容（docDefaults = 文档默认语言/默认字体的唯一载体）——
# 全段照抄 demo-cn.docx word/styles.xml 的 docDefaults（2026-09-05 真机已确认
# "识别对了"：ascii=Arial 西文 + eastAsia=SimSun 中文 + w:lang zh-CN + sz 22 五号）。
# 字段说明（勿凭感觉增减）：rFonts 决定默认字体（eastAsia=SimSun → 新建即中文
# 字形）；w:lang 决定状态栏/拼写/默认语言（"English - United States" 消失）；
# pBdr=0 + spacing after=200/line=276 是官方生成器的空文档默认段落格式（demo-cn
# 原样），删掉后引擎按内置默认（spacing after=100）与 demo-cn 行为分叉。
DOCX_STYLES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults><w:rPrDefault><w:rPr>'
    '<w:rFonts w:ascii="Arial" w:eastAsia="SimSun" w:hAnsi="Arial" w:cs="Arial"/>'
    '<w:sz w:val="22"/><w:szCs w:val="22"/>'
    '<w:lang w:val="zh-CN" w:eastAsia="zh-CN" w:bidi="ar-SA"/>'
    '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>'
    '<w:pBdr><w:top w:val="none" w:sz="4" w:space="0" w:color="000000"/>'
    '<w:left w:val="none" w:sz="4" w:space="0" w:color="000000"/>'
    '<w:bottom w:val="none" w:sz="4" w:space="0" w:color="000000"/>'
    '<w:right w:val="none" w:sz="4" w:space="0" w:color="000000"/>'
    '<w:between w:val="none" w:sz="4" w:space="0" w:color="000000"/>'
    '</w:pBdr><w:spacing w:after="200" w:line="276" w:lineRule="auto"/>'
    '</w:pPr></w:pPrDefault></w:docDefaults></w:styles>\n'
)
# 骨架 [Content_Types].xml 只声明 document.xml → 追加 styles.xml Override
DOCX_CT = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '</Types>\n'
)
# 包级 _rels/.rels 保持原样（只挂 officeDocument rId1）——styles 是 **word/document.xml
# 的部件关系**，必须挂在 word/_rels/document.xml.rels（2026-09-05 踩坑：第一版误把
# styles 关系追加到包级，Target=styles.xml 在包根找不到 → x2t 当孤立部件丢弃 →
# doct_bin 无 docDefaults → 状态栏仍 en-US。真机证据：转换产物 768B 仅含 0x409）。
DOCX_DOC_RELS = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>\n'
)

# —— pptx 文档语言对齐（2026-09-12 用户需求：三种格式新建语言统一中文简体）——
# 官方 blank 主题自带 165 处 lang="en-US"（slideMaster / 11 个 slideLayout / 母版与
# 版式里的占位符 run / notesMaster / notesSlide / presentation 的 defaultTextStyle
# defPPr）——引擎据此把新建演示判为 English（状态栏 "English - United States"），
# 与 docx 模板 docDefaults 的 w:lang=zh-CN 不对齐。PPTX 的语言声明只出现在
# lang="..." 属性上（run / endParaRPr / defRPr / defPPr），故纯文本级替换即可。
PPTX_LANG_FROM = 'lang="en-US"'
PPTX_LANG_TO = 'lang="zh-CN"'

# 骨架部件 → 重写内容（未列出的部件原样保留）
XLSX_REPLACES = {
    'xl/workbook.xml': BLANK_WORKBOOK,
    'xl/worksheets/sheet1.xml': BLANK_SHEET1,
    'xl/sharedStrings.xml': BLANK_SST,
    'docProps/core.xml': BLANK_PROP_CORE,
    'docProps/app.xml': BLANK_PROP_APP,
}


def rewrite_zip(src_path, dst_path, replaces):
    """以官方骨架 src 为底，按 replaces {部件名: 新内容} 重写部件。"""
    if not os.path.isfile(src_path):
        raise SystemExit('骨架缺失: %s（来源见文件头注释）' % src_path)
    src = zipfile.ZipFile(src_path)
    names = src.namelist()
    for key in replaces:
        if key not in names:
            raise SystemExit('骨架缺部件 %s（friendly: 骨架版本不符，须更新本脚本）'
                             % key)
    with zipfile.ZipFile(dst_path, 'w', zipfile.ZIP_DEFLATED) as out:
        for item in src.infolist():
            data = replaces.get(item.filename)
            if data is None:
                data = src.read(item.filename)
            else:
                data = data.encode('utf-8')
            out.writestr(item, data)
    src.close()


def empty_xlsx():
    rewrite_zip(SRC_XLSX, DST_X, XLSX_REPLACES)


def empty_docx():
    """最小 docx 骨架（真机验证引擎可打开的 3 部件包）→ 补 styles.xml
    （docDefaults 默认中文）+ Content_Types/rels 声明 → empty.docx。
    注意：骨架 word/document.xml 保持"单空段落"不动——它已被真机验证可打开；
    默认中文只经 docDefaults（demo-cn 同款），勿再往 document.xml 写任何内容。"""
    if not os.path.isfile(SRC_DOCX):
        raise SystemExit('docx 骨架缺失: %s（来源见文件头注释）' % SRC_DOCX)
    src = zipfile.ZipFile(SRC_DOCX)
    names = src.namelist()
    for key in ('[Content_Types].xml', '_rels/.rels', 'word/document.xml'):
        if key not in names:
            raise SystemExit('docx 骨架缺部件 %s（骨架版本不符，须更新本脚本）' % key)
    with zipfile.ZipFile(DST_W, 'w', zipfile.ZIP_DEFLATED) as out:
        for item in src.infolist():
            if item.filename == '[Content_Types].xml':
                data = DOCX_CT.encode('utf-8')
            else:
                data = src.read(item.filename)
            out.writestr(item, data)
        # 新增部件（骨架中没有 → 追加写入；styles 关系放 word/_rels/document.xml.rels——
        # 包级目录仅是 package rels，挂错层级 = styles 被孤立，见 DOCX_DOC_RELS 注释）
        out.writestr('word/styles.xml', DOCX_STYLES.encode('utf-8'))
        out.writestr('word/_rels/document.xml.rels', DOCX_DOC_RELS.encode('utf-8'))
    src.close()


def empty_pptx():
    """空白主题骨架（11 版式全集）→ 清理文档属性/缩略图 → empty.pptx"""
    if not os.path.isfile(SRC_PPTX):
        raise SystemExit('pptx 骨架缺失: %s（来源见文件头注释）' % SRC_PPTX)
    src = zipfile.ZipFile(SRC_PPTX)
    names = src.namelist()
    _must = ('ppt/presentation.xml', 'ppt/slides/slide1.xml',
             'ppt/slideMasters/slideMaster1.xml')
    for key in _must + tuple('ppt/slideLayouts/slideLayout%d.xml' % i for i in range(1, 12)):
        if key not in names:
            raise SystemExit('pptx 骨架缺部件 %s（骨架版本不符，须更新本脚本）' % key)
    with zipfile.ZipFile(DST_P, 'w', zipfile.ZIP_DEFLATED) as out:
        for item in src.infolist():
            if item.filename == 'docProps/core.xml':
                data = BLANK_PROP_CORE.encode('utf-8')
            elif item.filename == 'docProps/thumbnail.jpeg':
                continue  # 预览缩略图（样本外观），空白模板勿带
            else:
                data = src.read(item.filename)
                if item.filename.endswith('.xml'):
                    data = data.decode('utf-8').replace(PPTX_LANG_FROM, PPTX_LANG_TO).encode('utf-8')
            out.writestr(item, data)
    src.close()


def check(path, asserts):
    """产物校验：zip 完整 + 内容断言，任一失败非零退出。"""
    if not os.path.isfile(path):
        raise SystemExit('产物缺失: ' + path)
    z = zipfile.ZipFile(path)
    bad = z.testzip()
    if bad:
        raise SystemExit('产物 zip 损坏: %s (%s)' % (path, bad))
    for name, must_have, must_not in asserts:
        data = z.read(name).decode('utf-8')
        for s in must_have:
            if s not in data:
                raise SystemExit('%s:%s 缺失断言失败: "%s"' % (path, name, s))
        for s in must_not:
            if s in data:
                raise SystemExit('%s:%s 污染断言失败: "%s"' % (path, name, s))
    print('%s ok (%d entries, %.1f KB)' % (path, len(z.namelist()),
                                           os.path.getsize(path) / 1024))
    z.close()


if __name__ == '__main__':
    os.makedirs(DST_DIR, exist_ok=True)
    empty_docx()
    empty_xlsx()
    empty_pptx()
    check(DST_W, [
        # 新建 word 默认中文判据：docDefaults 带 w:lang zh-CN + eastAsia=SimSun；
        # 无 run 级字体/语言覆盖（defaults 承载）；en-US 黑名单防回退
        ('word/styles.xml', ['w:lang w:val="zh-CN"', 'w:eastAsia="SimSun"'],
         ['w:val="en-US"']),
        ('word/document.xml', ['<w:body>', '<w:sectPr'], ['<w:rFonts', 'w:lang']),
        ('[Content_Types].xml', ['styles+xml'], []),
        # styles 必须是 document 的部件关系（word/_rels/document.xml.rels）；
        # 包级 _rels/.rels 只挂 officeDocument（挂 styles 进去即 dangling——x2t 丢
        # docDefaults，2026-09-05 真机实锤 768B bin 只有 0x409）
        ('word/_rels/document.xml.rels', ['styles.xml'], []),
        ('_rels/.rels', ['word/document.xml'], []),
    ])
    check(DST_X, [
        # 真空白判据：无单元格/列宽/多 sheet；标准 sheet 名；空 sst
        ('xl/worksheets/sheet1.xml', ['<sheetData/>'], ['<row ', '<cols', 'EEF0F6']),
        ('xl/workbook.xml', ['name="Sheet1"'], ['sheet2', 'sheet3', 'Лист']),
        ('xl/sharedStrings.xml', ['count="0"'], ['<si>']),
    ])
    check(DST_P, [
        # 空白演示判据：首滑无任何文本；标准 11 版式齐；样本作者/标题残留已清
        ('ppt/slides/slide1.xml', ['p:ph type="ctrTitle"'], ['<a:t>', '<a:pPr>']),
        ('ppt/presentation.xml', ['sldIdLst', 'lang="zh-CN"'], []),
        ('docProps/core.xml', [], ['Teamlab', 'Oleg', '>User<', 'dc:title']),
    ])
    n_l = len([n for n in zipfile.ZipFile(DST_P).namelist()
               if n.startswith('ppt/slideLayouts/slideLayout') and n.endswith('.xml')])
    if n_l != 11:
        raise SystemExit('empty.pptx slideLayout 数 %d != 11' % n_l)
    # 语言对齐判据：全包（含母版/版式/备注，它们不逐条断言）不得残留 en-US
    _zp = zipfile.ZipFile(DST_P)
    _left = [n for n in _zp.namelist()
             if n.endswith('.xml') and PPTX_LANG_FROM in _zp.read(n).decode('utf-8')]
    _zp.close()
    if _left:
        raise SystemExit('empty.pptx 残留 %s：%s' % (PPTX_LANG_FROM, ', '.join(_left)))
    print('完成（模板随 HAP 打包：重新构建 HAP 后生效；重跑本脚本可再生成）')
