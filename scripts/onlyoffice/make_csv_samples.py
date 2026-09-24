#!/usr/bin/env python3
"""生成 CSV 编码/分隔符诊断样本（幂等重生成）：sample-gbk.csv / sample-semi.csv。

**用途**：验证打开链的 CSV 参数嗅探（`formats.ets` 的 csvOpenExtra）。x2t 侧对 CSV
源要求宿主显式给出编码与分隔符——无 BOM 时它自己测不出编码（getEncodingByContent
只认 BOM），分隔符也不按 .csv 扩展名填（只认 .tsv/.scsv），二者任一为空即判转换
失败。参数若写死，只能覆盖 UTF-8+逗号一种形态：Excel 导出的 GBK 中文解成乱码、
分号/制表符分隔的整行挤成一列——两种坏法都要有样本才能验证修复。

样本设计：与既有 sample.csv **内容相同、仅编码或分隔符不同**，真机打开后互相对照
（同一份数据渲染结果应一致）：
  sample.csv        UTF-8 + 逗号（既有样本，回归 case open-csv 依赖，不由本脚本生成）
  sample-gbk.csv    GBK   + 逗号 + CRLF 行尾（Excel 中文导出的真实形态）
  sample-semi.csv   UTF-8 + 分号

用法: python3 scripts/onlyoffice/make_csv_samples.py
产物: scripts/onlyoffice/smoke/samples/sample-{gbk,semi}.csv（入库；随包进
      rawfile/onlyoffice/smoke/samples，m7 验收按 m7file= 名取用）
"""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(ROOT, 'smoke', 'samples')

ROWS = [
    ['姓名', '部门', '金额', '日期'],
    ['张三', '研发', '1200.50', '2026-01-15'],
    ['李四', '市场', '880.00', '2026-02-20'],
]


def _is_utf8(raw):
    try:
        raw.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def write_sample(name, text, encoding, delim):
    """写样本并回读断言——样本必须真的落在嗅探要区分的那一侧，否则测试是假绿。

    断言依据（与本脚本用途一一对应）：
      GBK 样本：字节序列必须**不是**合法 UTF-8（正是嗅探判 GBK 的依据；
                若它碰巧合法，样本就退化成了 UTF-8 用例）
      分隔符：文本里必须含该分隔符、且不含优先级更高的候选（逗号样本除外）
    """
    path = os.path.join(SAMPLES, name)
    data = text.encode(encoding)
    with open(path, 'wb') as f:
        f.write(data)

    with open(path, 'rb') as f:
        back = f.read()
    assert back == data, '%s: 回读字节不一致' % name
    utf8_ok = _is_utf8(back)
    expect_utf8 = (encoding == 'utf-8')
    if utf8_ok != expect_utf8:
        raise SystemExit('%s: UTF-8 合法性不符（期望 %s，实际 %s）——样本失去区分度'
                         % (name, expect_utf8, utf8_ok))
    if text.split('\n')[0].find(delim) < 0:
        raise SystemExit('%s: 首行不含分隔符 %r' % (name, delim))
    print('  %s: %d bytes, %s, delim=%r' % (name, len(data), encoding, delim))


def main():
    if not os.path.isdir(SAMPLES):
        raise SystemExit('样本目录不存在：%s' % SAMPLES)
    # GBK 用 CRLF：Excel 中文导出的真实形态，同时覆盖嗅探对 \r 的鲁棒性
    gbk_text = '\r\n'.join(','.join(r) for r in ROWS) + '\r\n'
    semi_text = '\n'.join(';'.join(r) for r in ROWS) + '\n'
    print('CSV 样本 →', SAMPLES)
    write_sample('sample-gbk.csv', gbk_text, 'gbk', ',')
    write_sample('sample-semi.csv', semi_text, 'utf-8', ';')
    print('完成（%d 行数据共用一份内容，仅编码/分隔符不同）' % len(ROWS))


if __name__ == '__main__':
    main()
