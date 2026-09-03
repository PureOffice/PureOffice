# ONLYOFFICE → HarmonyOS NEXT 移植（B 架构）

把 ONLYOFFICE DesktopEditors(AGPL-3.0) 移植到商用鸿蒙 Pad 的工程。**迭代 1 已达成「真文件打开 → 编辑 → 保存」最小产品闭环（2026-09-03 真机 ✅）。**

## 现状一句话

「ArkTS 薄壳 + 系统 ArkWeb 渲染 ONLYOFFICE web 编辑器 + native core(x2t) 转换引擎」= **B 架构**。
真机验证：`sample.docx`（俄语文本+表格，8 页）→ 打开渲染完整 → 自动插入 OOH 编辑标记 → 保存 → `save.docx` 内 document.xml **同时含编辑标记与原文内容**（1017 个 `<w:t>`，原文 1016 + 标记 1，增量精确）。

## 关键文档

| 文档 | 内容 |
|---|---|
| [docs/ONLYOFFICE_OHOS_PORT_DESIGN.md](docs/ONLYOFFICE_OHOS_PORT_DESIGN.md) | 总设计：为何走 B（CEF/Chromium 调研结论）、阶段路线图、POC 1-5 状态、风险表 |
| [docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md](docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md) | **方案关键点**：DOCY v5/v10 家族、打开/保存链最终形态、传输规则、探针体系、构建部署细节与坑 |
| [docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md](docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md) | 保存链全源码考古（为何不依赖 saveDocumentToZip/服务器） |

## 快速开始

```bash
# 0) 环境（已具备；均可环境变量覆盖见各脚本）
#   OHOS SDK: /apps/harmony/sdk/default/openharmony（SDK 6.1.0(23), BiSheng clang）→ OHOS_NDK
#   hdc:      /apps/harmony/sdk/default/openharmony/toolchains/hdc → OHOS_HDC
#   hvigor:   /apps/harmony/bin/hvigorw → OHOS_HVIGORW
#   真机:     192.168.1.8:33363（hdc 已配对）→ OHOS_DEV；bundle: app.hackeris.winehua

# 从零复现（仓库 = 可复现内容集合：源码 + 构建脚本 + submodule pin）：
git submodule update --init                            # 四库（core/sdkjs/web-apps/build_tools，官方 release/v9.4.0）
bash scripts/onlyoffice/patch_core_ohos.sh             # core OHOS 补丁（power-idempotent；03 执行位保险）
python3 scripts/onlyoffice/pack_web.py                 # rawfile/onlyoffice 运行时资源（163MB 产物，不入库）
python3 scripts/onlyoffice/core3d/gen_cmake.py && cmake -S build/core3d -B build/core3d/build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/scripts/onlyoffice/core3d/ohos-arm64.toolchain.cmake \
  && cmake --build build/core3d/build -j$(nproc)      # core(x2t) 静态库（仓库已带 build/ 缓存时跳过）

# 1) 打包 + 装机 + 重启（迭代1 部署闭环；--probe 加读运行探针）
bash scripts/onlyoffice/deploy_ohos.sh --probe

# 2) 真机验证闭环（autotest 自动跑：打开 sample.docx → mark(OOH-ts) → save）
#    probe.txt 落点: hdc shell cat /data/app/el2/100/base/app.hackeris.winehua/haps/entry/files/probe.txt
#    保存产物:       .../files/save.docx；拉回解压验 document.xml 指纹即可

# 3) 手动验证：壳层三个按钮 打开 sample.docx / 标记 / 保存
```

## 工程结构

```
entry/src/main/
  ets/
    pages/EditorPage.ets          # 壳：Web 组件 + 打开/标记/保存按钮 + 探针(probe.txt)
    common/ascBridge.ets          # AscConvertProxy(x2t 打开桥) + AscSaveProxy(保存桥) + rawfileLoader
    common/rawfileLoader.ets      # onInterceptRequest：onlyoffice  rawfile + userfile/<name> 沙箱映射
    common/x2t.ets                # x2tConvertSync 等 NAPI 封装
  cpp/                            # convertershell：x2t 26 库打包成 .so + NAPI convert/convertSync/version
  resources/rawfile/onlyoffice/   # web-apps + sdkjs（官方 release/v9.4.0 配套）+ fonts + document.docx
    webapps/.../documenteditor/main/index.html   # 含注入：Asc.Addons.ooxml + __oobDocy 打开桥 + 探针
third_party/core | sdkjs          # ONLYOFFICE 源码（双仓库均 pinned release/v9.4.0）
scripts/onlyoffice/               # 构建：core3d(交叉编译)/打包/部署/审计
docs/                             # 本组文档
```

## 常用命令

```bash
# 构建（切勿 clean！会清掉 build/core3d 的 native 静态库，重建需 10+ 分钟）
/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon

# 真机
hdc list targets
hdc -t 192.168.1.8:33363 shell   # 注意：多设备必须 -t
hdc -t 192.168.1.8:33363 install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t 192.168.1.8:33363 shell "aa force-stop app.hackeris.winehua; aa start -a EntryAbility -b app.hackeris.winehua"
# 截图
hdc -t 192.168.1.8:33363 shell snapshot_display && hdc -t 192.168.1.8:33363 file recv /data/local/tmp/snapshot_*.jpeg /tmp/s.png

# core3d（libx2t.a 等）重建（被 clean 误清后恢复用）
python3 scripts/onlyoffice/core3d/gen_cmake.py
cmake -S build/core3d -B build/core3d/build -DCMAKE_TOOLCHAIN_FILE=/data/share/office/scripts/onlyoffice/core3d/ohos-arm64.toolchain.cmake
cmake --build build/core3d/build -j$(nproc)
```

## 当前任务状态

- **迭代 1**（2.1+2.2+2.4 MVP）：✅ 完成（2026-09-03）—— 真文件打开/编辑/保存闭环 + 部署脚本沉淀
- **迭代 2**（xlsx/pptx）：✅ 完成（2026-09-03）。**docx/xlsx/pptx 三格式「打开→渲染→编辑→保存」全部真机验证通过**（xlsx cells 渲染三修：loadBinary 统一拦截 PK→x2t、踢闸后 wb.resize 重绘、asc_setZoom 需 factor=1.0——详见 docs/KEYPOINTS §10 / NEXT_STEPS）。仓库已正规化：third_party 四库转 submodule（pin release/v9.4.0）、核心补丁集中在 scripts/onlyoffice/patches/、运行时产物（rawfile/onlyoffice 163MB 等）gitignore 由脚本重生成
- **迭代 3**（生命周期/大文档阈值/原生对话框）：未开始
- 遗留：index.html 内诊断打点（f3/o0/p5/pf 系）可留作调试通道，正式化时瘦身

## 踩坑速查（本轮实测）

1. **hvigor 严禁 clean**——`hvigorw clean` 会删 `build/core3d`，`libx2t.a` 消失导致 native 链接失败，重建 10+ 分钟。
2. **增量构建可能不带最新 .ets**——若改动 EditorPage.ets 后行为不变，先 `strings HAP | grep <新字符串>` 确认已打包（本次踩坑：modules.abc 未刷新，改动没进包）。
3. **openDocument 的 DOCY 必须用 Uint8Array 传入**——string（二进制串）读 v10 会得到空模型或死循环卡死（详见 KEYPOINTS §4）。
4. **ArkTS→页面传二进制必须 base64 信封**——raw 字符串含 NUL 等字节经 runJavaScript 会损坏。
5. **页面 console 走 `console.error`**——I 级日志随 app 切后台被丢，E 级稳定（EditorPage.onConsole 转发 hilog `[web]` 前缀）。
