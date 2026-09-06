# ONLYOFFICE → HarmonyOS NEXT 移植（B 架构）

把 ONLYOFFICE DesktopEditors（AGPL-3.0）移植到商用鸿蒙 Pad：ArkTS 薄壳 + 系统 ArkWeb
渲染 ONLYOFFICE web 编辑器 + native core(x2t) 转换引擎。真机已验证：docx/xlsx/pptx
打开 → 编辑 → 保存全链闭环。

## 功能（已实现）

- **打开**：欢迎页「打开本地文件」（系统选择器）/「最近使用」列表 / 新建（Word/Excel/PPT 空文档）
- **编辑**：三格式完整工具栏/菜单/界面渲染
- **保存**：新建=另存为（系统保存对话框）；打开的文件=覆盖原文件；最近列表随保存刷新
- **导出**：文件菜单另存为系统位置
- **默认中文**：界面 + 新建文档默认语言 zh-CN
- **插件系统 + AI 插件**（2026-09-06）：官方 web 语义插件链（plugins.json 装配 → 后台插件 run →
  插件菜单/AI 工具栏注册/弹窗全通）；随包官方 AI 插件 3.2.2（AGPL）——顶部「AI」按钮组、
  对话/摘要/翻译窗口；**模型配置**：首次点 Chatbot 无模型时按官方语义自动弹设置窗口
  （Ollama localhost:11434 等 provider 自理）

## 快速开始（从零复现）

```bash
# 环境（可环境变量覆盖）：
#   OHOS SDK /apps/harmony/sdk/default/openharmony → OHOS_NDK
#   hdc /apps/harmony/sdk/default/openharmony/toolchains/hdc → OHOS_HDC
#   hvigor /apps/harmony/bin/hvigorw → OHOS_HVIGORW
#   target device → OHOS_DEV（必须显式指定，无默认值）

# 0) 子模块与补丁
git submodule update --init                 # core/sdkjs/web-apps/build_tools（官方 release/v9.4.0）
bash scripts/onlyoffice/patch_core_ohos.sh  # core OHOS 平台补丁（幂等）

# 1) 构建库产物（first time / clean 误清后）
python3 scripts/onlyoffice/core3d/gen_cmake.py
cmake -S build/core3d -B build/core3d/build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/scripts/onlyoffice/core3d/ohos-arm64.toolchain.cmake
cmake --build build/core3d/build -j$(nproc)

# 2) 一键：增量装配（ascshim/空模板/注入 webapps/字体）+ HAP 打包 + 装机 + 重启
OHOS_DEV=<ip:port> bash scripts/onlyoffice/deploy_ohos.sh

# 3) 自动验收（可选）：启动带 m7accept 参数 → 自动打开样本并验证打开/保存链
hdc -t <ip:port> shell aa start -a EntryAbility -b app.hackeris.winehua --ps m7accept 1
# 日志：hdc -t <ip:port> shell cat .../files/web_console.txt（页面与壳侧统一落盘）
```

## 工程结构

```
entry/src/main/
  ets/pages/EditorPage.ets        # 壳：Web 组件 + 编译/打开/保存链（SaveTarget 单一事实源）
  ets/common/ascBridge.ets        # AscNative 桥（JS 同步 _call + 注册）
  ets/common/rawfileLoader.ets    # onInterceptRequest：onlyoffice/* 与 userfile/* 沙箱映射
  ets/common/x2t.ets              # x2tConvertSync（NAPI）
  ets/common/recents.ets          # 最近使用（recents.json）
  resources/rawfile/onlyoffice/   # 运行时资源（构建产物，不入库）
third_party/core|sdkjs|...        # ONLYOFFICE 官方源码（submodule pinned）
scripts/onlyoffice/
  desktop/grunt-build.sh          # 官方构建 + 装配唯一入口（--no-upstream 仅装配）
  desktop/make_ascshim.py         # ascshim.js 拼装（src/*.js → rawfile）
  desktop/src/*.js                # 页面适配层（桥/打开/保存/欢迎页）
  make_empty_templates.py         # 新建空模板（empty.docx/xlsx/pptx）
  build_editors_ohos.py           # 装配：webapps/sdkjs/fonts/index.html/smoke/version.json
  deploy_ohos.sh                  # 一键增量：装配(ascshim/模板/注入) + 打包 + 安装 + 重启
  smoke/                          # 验收样本与诊断脚本（samples/ 子目录）
docs/                             # 设计/关键点/功能矩阵/合规方案（见下表）
```

## 常用命令

```bash
# 构建 HAP（严禁 clean——会清掉 build/core3d native 产物）
/apps/harmony/bin/hvigorw assembleHap -p product=default --mode module --no-daemon

# 真机（多设备必须 -t <ip:port>）
hdc list targets
hdc -t <ip:port> install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t <ip:port> shell "aa force-stop app.hackeris.winehua; aa start -a EntryAbility -b app.hackeris.winehua"
hdc -t <ip:port> shell snapshot_display -f /data/local/tmp/s.jpeg && hdc -t <ip:port> file recv /data/local/tmp/s.jpeg /tmp/s.jpeg   # 截图（必须 .jpeg 后缀）
```

## 踩坑速查

1. **hvigor 严禁 clean**——会删 build/core3d 的 libx2t.a，native 链接失败，重建 10+ 分钟。
2. **改动未见效**：先确认进包（`strings HAP | grep <新字符串>`）——.ets 增量可能不刷新。
3. **openDocument 字节必须 Uint8Array**——string 传入得到空模型或卡死。
4. **ArkTS→页面传二进制必须 base64 信封**——runJavaScript 走字符串会损坏 NUL 字节。
5. **产物不入库**：rawfile 运行时资源（webapps/sdkjs/fonts/ascshim.js/index.html/…）
   全是构建产物，`grunt-build.sh` / `deploy_ohos.sh` 重生成；仅空模板与样本保留跟踪。
6. **sdkjs 双清单**：核心（sdk-all-min.js）与 common（sdk-all.js）由官方 loadSdk 自动加载，
   勿手工预载/向清单加类文件（加载顺序错误 = 字体链崩溃/打开静默失败）。

## 文档索引

| 文档 | 内容 |
|---|---|
| docs/ONLYOFFICE_OHOS_PORT_DESIGN.md | 总设计：B 架构决策依据、阶段路线图 |
| docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md | 关键点：DOCY v5/v10、打开/保存链、探针体系 |
| docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md | 保存链源码依据（不依赖服务器） |
| docs/ONLYOFFICE_OHOS_FEATURE_MATRIX.md | 功能支持矩阵：已实现/降级/未实现 + 升级路线 |
| docs/ONLYOFFICE_OHOS_PRODUCT_ROADMAP.md | 产品路线：P0-P2 差距清单 |
| docs/OPENSOURCE_COMPLIANCE_PLAN.md | 开源合规整改方案（AGPL） |
