#!/usr/bin/env python3
"""生成含图 pptx 诊断样本 smoke/samples/sample-img.pptx（幂等重生成）。

**用途**：判定 `_offline_media` 媒体供给链缺失的**真实影响**。审计
（docs/ONLYOFFICE_OHOS_ASSETS_GAP_AUDIT.md §1）列为 P0：引擎对文档内嵌媒体的
运行时虚拟路径 `_offline_media/imageN` 由部署形态供给（服务器版落缓存目录、
桌面版走 C++ Local 文件链），B 架构没有这一层 → rawfile miss。到底"丢不丢图"
需要一个含图文档才能验证（原唯一 pptx 样本 sample.pptx 无 ppt/media）。

**做法**：以 sample.pptx（1 张幻灯片 + 一个标题框）为基底，插入
ppt/media/image1.png（PIL 画四象限 + 白十字，高对比，截图上一眼可辨）
+ slide1.xml 的 `<p:pic>` + slide1 rels 的 image 关系 + Content_Types 的 png Default。

用法: python3 scripts/onlyoffice/make_img_sample.py
产物: scripts/onlyoffice/smoke/samples/sample-img.pptx（入库；随包进 rawfile/smoke/samples）
"""
import os
import zipfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'smoke', 'samples', 'sample.pptx')
DST = os.path.join(ROOT, 'smoke', 'samples', 'sample-img.pptx')
TMP_IMG = '/tmp/lso_img_sample.png'

# 图片位置/尺寸（EMU；914400 = 1 英寸）——幻灯片上部、4 英寸见方，必定入镜
PIC = ('<p:pic><p:nvPicPr><p:cNvPr id="100" name="Picture 1"/>'
       '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
       '<p:blipFill><a:blip r:embed="rIdImg1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
       '<p:spPr><a:xfrm><a:off x="609600" y="3200400"/><a:ext cx="3657600" cy="3657600"/></a:xfrm>'
       '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>')
REL = ('<Relationship Id="rIdImg1" '
       'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
       'Target="../media/image1.png"/>')
PNG_DEFAULT = '<Default Extension="png" ContentType="image/png"/>'
XML_DEFAULT = '<Default Extension="xml" ContentType="application/xml"/>'


def make_png():
    im = Image.new('RGB', (240, 240), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 119, 119], fill=(214, 45, 32))       # 左上 红
    d.rectangle([120, 0, 239, 119], fill=(0, 133, 62))      # 右上 绿
    d.rectangle([0, 120, 119, 239], fill=(0, 84, 166))      # 左下 蓝
    d.rectangle([120, 120, 239, 239], fill=(255, 185, 0))   # 右下 黄
    d.rectangle([110, 0, 130, 239], fill=(255, 255, 255))   # 白竖条
    d.rectangle([0, 110, 239, 130], fill=(255, 255, 255))   # 白横条
    im.save(TMP_IMG, 'PNG')


def patch(name, xml):
    """按部件名打补丁；未涉及部件原样返回"""
    if name == 'ppt/slides/slide1.xml':
        assert '</p:spTree>' in xml, 'slide1.xml 结构不符（sample.pptx 变了？）'
        return xml.replace('</p:spTree>', PIC + '</p:spTree>')
    if name == 'ppt/slides/_rels/slide1.xml.rels':
        assert '</Relationships>' in xml
        return xml.replace('</Relationships>', REL + '</Relationships>')
    if name == '[Content_Types].xml':
        if 'Extension="png"' not in xml:
            assert XML_DEFAULT in xml
            return xml.replace(XML_DEFAULT, XML_DEFAULT + PNG_DEFAULT)
        return xml
    return xml


def main():
    make_png()
    zin = zipfile.ZipFile(SRC)
    with zipfile.ZipFile(DST, 'w', zipfile.ZIP_DEFLATED) as zo:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename.endswith('.xml') or item.filename.endswith('.rels'):
                data = patch(item.filename, data.decode('utf-8')).encode('utf-8')
            item.compress_type = zipfile.ZIP_DEFLATED
            zo.writestr(item, data)
        zo.write(TMP_IMG, 'ppt/media/image1.png')

    z = zipfile.ZipFile(DST)
    assert z.testzip() is None, '产物 zip 校验失败'
    assert 'ppt/media/image1.png' in z.namelist()
    assert 'rIdImg1' in z.read('ppt/slides/_rels/slide1.xml.rels').decode('utf-8')
    assert 'rIdImg1' in z.read('ppt/slides/slide1.xml').decode('utf-8')
    assert 'Extension="png"' in z.read('[Content_Types].xml').decode('utf-8')
    print('生成 %s（%d bytes, %d 部件）' % (DST, os.path.getsize(DST), len(z.namelist())))


if __name__ == '__main__':
    main()
