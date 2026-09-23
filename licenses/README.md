# 随包第三方许可证正本

本目录存放**随 HAP 分发的第三方组件**的许可证全文。构建时由
`scripts/onlyoffice/build_editors_ohos.py` 的 `install_licenses()` 连同根
`LICENSE` / `NOTICE` 一起拷进包内 `rawfile/onlyoffice/licenses/`（编辑器内
About → 「源码与声明」可访问），使「许可信息随二进制可得」不依赖外网。

本工程自身的授权与上游 ONLYOFFICE 的 AGPL-3.0（含官方附加条款）见仓库根
`LICENSE` / `NOTICE`。

## 清单与对应关系

| 文件 | 许可 | 覆盖的随包组件 | 正本来源 |
|---|---|---|---|
| `OFL-1.1.txt` | SIL Open Font License 1.1 | Liberation Sans/Serif/Mono；Noto Sans CJK SC；Noto Serif CJK SC | <https://openfontlicense.org/documents/OFL.txt> |
| `GPL-3.0.txt` | GNU GPL v3 | FandolFang（仿宋）、FandolKai（楷体） | CTAN `fandol.zip` 内上游自带 `COPYING`（<https://mirrors.ctan.org/fonts/fandol.zip>） |
| `Fandol-README.txt` | ——（授权声明原文） | 同上 | 同一包内 `README`（原文：「These fonts's licensing is GPL + GPL font exception.」） |
| `MPL-2.0.txt` | Mozilla Public License 2.0 | OpenSymbol | Debian `common-licenses`（Mozilla 官方文本，逐字） |

校验和（改动本目录文本后须同步更新）：

```
e0e18125674e1542f95ea36a4a958f57  OFL-1.1.txt
e3d54d1b83c7e0bbbc6657c325be7e4c  GPL-3.0.txt
2f25a2971cbae92620da95594673367c  Fandol-README.txt
815ca599c9df247a0c7f619bab123dad  MPL-2.0.txt
```

## 两个需要说明的点

**1. Fandol 的 GPL「对应源码」如何满足。** 随包的是**改动过**的字体：上游发布的是
CFF 轮廓的 `.otf`，而引擎的 wasm libfont 只吃静态 `glyf` TrueType，故经
`otf2ttf` 转轮廓 + `pyftsubset` 抽 GB2312 子集（链见 `make_cjk_font_src.sh` 与本
目录同级的 `build_editors_ohos.py`）。GPL-3.0 §6 要求提供对应源码，此处以
「**上游原文件 + 逐字的修改命令 + 本仓库中改动后的产物**」三者共同满足：字体这类
作品的「可修改形式」就是字体文件自身，而改动后的子集 TTF 随包分发、构建脚本在
仓库内逐字可复现（`scripts/onlyoffice/`）。

**2. 「GPL font exception」原文未随上游包分发。** Fandol 包内只有 `COPYING`
（GPL-3 全文）与 `README`（一句授权声明），例外的正文上游并未提供文件；公开可查的
通行例外条款用于**在文档中嵌入**字体时豁免该文档，与本工程「分发修改后的字体软件」
这一场景无关，故本目录只逐字收录上游实际分发的那两份文本，不代拟例外正文。
