#!/usr/bin/env python3
"""生成含图诊断样本（幂等重生成）：sample-img.pptx / sample-img.docx。

**用途**：判定 `_offline_media` 媒体供给链（引擎内嵌图的渲染路径）的真实影响。
审计（docs/ONLYOFFICE_OHOS_ASSETS_GAP_AUDIT.md §1）列为 P0：引擎对文档内嵌媒体的
运行时虚拟路径 `_offline_media/imageN` 由部署形态供给（服务器版落缓存目录、桌面版走
C++ Local 文件链、native 版 GetImagesPath），B 架构的供给点是拦截层
（rawfileLoader.ets 的 `_offline_media/` 分支 + x2t 解包出的 `<filesDir>/media/`）。
到底"丢不丢图"必须有含图文档才能验证（原样本 sample.pptx / sample.docx 均无 media）。

**做法**：以现成样本为基底 zip 直改——
  pptx：sample.pptx + `ppt/media/image1.png` + slide1 的 `<p:pic>` + slide rels + Content_Types
  docx：sample.docx + `word/media/image1.png` + body 首部的 `<w:drawing>`（inline 图）
        + document.xml.rels + Content_Types
图片为 PIL 画的四象限 + 白十字（高对比，截图上一眼可辨）。

用法: python3 scripts/onlyoffice/make_img_sample.py
产物: scripts/onlyoffice/smoke/samples/sample-img.{pptx,docx}（入库；随包进 rawfile/smoke/samples）
"""
import os
import zipfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(ROOT, 'smoke', 'samples')
TMP_PPTX = '/tmp/lso_img_sample_ppt.png'
TMP_DOCX = '/tmp/lso_img_sample_doc.png'
TMP_XLSX = '/tmp/lso_img_sample_xls.png'
# 三格式用不同配色：per-tab 媒体隔离失效（串图）时截图上一眼可辨（看到的会是对方配色）
PPT_COLORS = ((214, 45, 32), (0, 133, 62), (0, 84, 166), (255, 185, 0))     # 红绿蓝黄
DOC_COLORS = ((0, 170, 190), (200, 0, 160), (120, 120, 120), (20, 20, 20))  # 青品灰黑
XLS_COLORS = ((255, 122, 0), (110, 60, 190), (10, 90, 40), (130, 90, 40))   # 橙紫深绿棕

# 图片位置/尺寸（EMU；914400 = 1 英寸）——4 英寸见方，必定入镜
W_EMU = '3657600'
PIC = ('<p:pic><p:nvPicPr><p:cNvPr id="100" name="Picture 1"/>'
       '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
       '<p:blipFill><a:blip r:embed="rIdImg1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
       '<p:spPr><a:xfrm><a:off x="609600" y="3200400"/><a:ext cx="' + W_EMU + '" cy="' + W_EMU + '"/></a:xfrm>'
       '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>')
# docx 的 inline 图：wp/a/pic 三个命名空间就地声明——sample.docx 根元素未声明 a/pic
# （只声明了 wp），就地声明可避免动根元素（zip 直改最小面）
DOC_DRAWING = (
    '<w:p><w:r><w:drawing>'
    '<wp:inline distT="0" distB="0" distL="0" distR="0">'
    '<wp:extent cx="' + W_EMU + '" cy="' + W_EMU + '"/>'
    '<wp:docPr id="100" name="Picture 1"/>'
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
    '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
    '<pic:nvPicPr><pic:cNvPr id="100" name="Picture 1"/><pic:cNvPicPr/></pic:nvPicPr>'
    '<pic:blipFill><a:blip r:embed="rIdImg1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + W_EMU + '" cy="' + W_EMU + '"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
    '</pic:pic></a:graphicData></a:graphic>'
    '</wp:inline></w:drawing></w:r></w:p>')

REL_PPT = ('<Relationship Id="rIdImg1" '
           'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
           'Target="../media/image1.png"/>')
REL_DOC = ('<Relationship Id="rIdImg1" '
           'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
           'Target="media/image1.png"/>')
# xlsx：工作表 rels 指向 drawing 部件，drawing 自己的 rels 再指向媒体
# （OOXML 图片标准三层：sheet → drawing → media；与 docx/pptx 的两层不同）
REL_XLS_SHEET = ('<Relationship Id="rIdImg1" '
                 'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" '
                 'Target="../drawings/drawing1.xml"/>')
DRAWING_XLS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"'
               ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
               ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
               '<xdr:twoCellAnchor editAs="oneCell">'
               '<xdr:from><xdr:col>1</xdr:col><xdr:colOff>190500</xdr:colOff>'
               '<xdr:row>1</xdr:row><xdr:rowOff>95250</xdr:rowOff></xdr:from>'
               '<xdr:to><xdr:col>6</xdr:col><xdr:colOff>0</xdr:colOff>'
               '<xdr:row>12</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>'
               '<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="100" name="Picture 1"/>'
               '<xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr>'
               '<xdr:blipFill><a:blip r:embed="rIdImg1"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
               '<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + W_EMU + '" cy="' + W_EMU + '"/></a:xfrm>'
               '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>'
               '<xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>')
DRAWING_XLS_RELS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                    + REL_DOC.replace('Target="media/', 'Target="../media/') + '</Relationships>')
DRAWING_OVERRIDE = ('<Override PartName="/xl/drawings/drawing1.xml" '
                    'ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>')
PNG_DEFAULT = '<Default Extension="png" ContentType="image/png"/>'
XML_DEFAULT = '<Default Extension="xml" ContentType="application/xml"/>'
# 固定条目时间戳：入库二进制样本必须 byte-stable——zipfile 默认取当前时间/源文件 mtime，
# 每次重跑都产生 git diff（样本是"可复现产物"，不是随手生成的临时文件）
FIXED_DATE = (2026, 1, 1, 0, 0, 0)


def make_png(path, colors):
    """四象限 + 白十字。colors（左上,右上,左下,右下）——两格式用不同配色，
    这样 per-tab 媒体隔离失效（串图）时截图上一眼可辨：看到的是对方的配色。"""
    im = Image.new('RGB', (240, 240), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 119, 119], fill=colors[0])
    d.rectangle([120, 0, 239, 119], fill=colors[1])
    d.rectangle([0, 120, 119, 239], fill=colors[2])
    d.rectangle([120, 120, 239, 239], fill=colors[3])
    d.rectangle([110, 0, 130, 239], fill=(255, 255, 255))   # 白竖条
    d.rectangle([0, 110, 239, 130], fill=(255, 255, 255))   # 白横条
    im.save(path, 'PNG')


def _add_png_default(xml):
    if 'Extension="png"' in xml:
        return xml
    assert XML_DEFAULT in xml, '[Content_Types].xml 无 xml Default（样本变了？）'
    return xml.replace(XML_DEFAULT, XML_DEFAULT + PNG_DEFAULT)


def patch_pptx(name, xml):
    """按部件名打补丁；未涉及部件原样返回"""
    if name == 'ppt/slides/slide1.xml':
        assert '</p:spTree>' in xml, 'slide1.xml 结构不符（sample.pptx 变了？）'
        return xml.replace('</p:spTree>', PIC + '</p:spTree>')
    if name == 'ppt/slides/_rels/slide1.xml.rels':
        assert '</Relationships>' in xml
        return xml.replace('</Relationships>', REL_PPT + '</Relationships>')
    if name == '[Content_Types].xml':
        return _add_png_default(xml)
    return xml


def patch_docx(name, xml):
    """docx 补丁：图插在 body 首部（打开即见，无需滚动）"""
    if name == 'word/document.xml':
        i = xml.index('<w:body>') + len('<w:body>')
        return xml[:i] + DOC_DRAWING + xml[i:]
    if name == 'word/_rels/document.xml.rels':
        assert '</Relationships>' in xml
        return xml.replace('</Relationships>', REL_DOC + '</Relationships>')
    if name == '[Content_Types].xml':
        return _add_png_default(xml)
    return xml


def build(src_name, dst_name, media_part, patch, img_path, kind, extra=None):
    src = os.path.join(SAMPLES, src_name)
    dst = os.path.join(SAMPLES, dst_name)
    zin = zipfile.ZipFile(src)
    with zipfile.ZipFile(dst, 'w') as zo:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename.endswith('.xml') or item.filename.endswith('.rels'):
                data = patch(item.filename, data.decode('utf-8')).encode('utf-8')
            zi = zipfile.ZipInfo(item.filename, date_time=FIXED_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = item.external_attr
            zo.writestr(zi, data)
        # 新增部件（xlsx 的 drawing 层；pptx/docx 无）
        for name, text in (extra or {}).items():
            zi = zipfile.ZipInfo(name, date_time=FIXED_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zo.writestr(zi, text.encode('utf-8'))
        with open(img_path, 'rb') as f:
            img = f.read()
        zi = zipfile.ZipInfo(media_part, date_time=FIXED_DATE)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zo.writestr(zi, img)
    zin.close()

    # 引用链断言：承载部件（sheet/slide/document）→ 其 rels → 媒体部件，
    # 逐层确认补丁真的接上了（漏一层 = 打开后无图，且不报错）
    rel_part = {'ppt': 'ppt/slides/_rels/slide1.xml.rels',
                'doc': 'word/_rels/document.xml.rels',
                'xls': 'xl/worksheets/_rels/sheet1.xml.rels'}[kind]
    doc_part = {'ppt': 'ppt/slides/slide1.xml',
                'doc': 'word/document.xml',
                'xls': 'xl/worksheets/sheet1.xml'}[kind]
    z = zipfile.ZipFile(dst)
    assert z.testzip() is None, '产物 zip 校验失败：' + dst
    assert media_part in z.namelist()
    assert 'rIdImg1' in z.read(rel_part).decode('utf-8'), rel_part + ' 未接上图片引用'
    assert 'rIdImg1' in z.read(doc_part).decode('utf-8'), doc_part + ' 未接上图片引用'
    assert 'Extension="png"' in z.read('[Content_Types].xml').decode('utf-8')
    if kind == 'xls':
        assert 'xl/drawings/drawing1.xml' in z.namelist()
        assert 'rIdImg1' in z.read('xl/drawings/_rels/drawing1.xml.rels').decode('utf-8')
        # <drawing> 必须在工作表级 extLst **之外**（落进 extLst 内 = schema 违规，
        # x2t 静默忽略 → 图既不显示也不进 bin）
        sh = z.read('xl/worksheets/sheet1.xml').decode('utf-8')
        assert sh.index('<drawing') < sh.rindex('<extLst>'), 'drawing 落进 extLst（schema 违规）'
    print('生成 %s（%d bytes, %d 部件）' % (dst_name, os.path.getsize(dst), len(z.namelist())))
    z.close()


def patch_xlsx(name, xml):
    """xlsx 补丁：图挂 sheet1（只含 printerSettings，最干净）"""
    if name == 'xl/worksheets/sheet1.xml':
        # <drawing> 是 CT_Worksheet 序列里 extLst 之前的元素——插在 <extLst> **开始标签**
        # 之前（不是 </extLst> 前：那会落进 extLst 内部，schema 违规，x2t 直接忽略该
        # 元素，表现为"图打不开也看不到"）
        k = xml.rindex('<extLst>')
        return xml[:k] + '<drawing r:id="rIdImg1"/>' + xml[k:]
    if name == 'xl/worksheets/_rels/sheet1.xml.rels':
        assert '</Relationships>' in xml
        return xml.replace('</Relationships>', REL_XLS_SHEET + '</Relationships>')
    if name == '[Content_Types].xml':
        x = _add_png_default(xml)
        if 'drawing1.xml' in x:
            return x
        return x.replace('</Types>', DRAWING_OVERRIDE + '</Types>')
    return xml


def main():
    make_png(TMP_PPTX, PPT_COLORS)
    make_png(TMP_DOCX, DOC_COLORS)
    make_png(TMP_XLSX, XLS_COLORS)
    build('sample.pptx', 'sample-img.pptx', 'ppt/media/image1.png', patch_pptx, TMP_PPTX, 'ppt')
    build('sample.docx', 'sample-img.docx', 'word/media/image1.png', patch_docx, TMP_DOCX, 'doc')
    build('sample.xlsx', 'sample-img.xlsx', 'xl/media/image1.png', patch_xlsx, TMP_XLSX, 'xls',
          extra={'xl/drawings/drawing1.xml': DRAWING_XLS,
                 'xl/drawings/_rels/drawing1.xml.rels': DRAWING_XLS_RELS})


if __name__ == '__main__':
    main()
