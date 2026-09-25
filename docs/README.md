## 快速开始（从零复现）

```bash
# 环境：工具链路径由 scripts/onlyoffice/env.sh 统一探测（PATH → SDK 环境变量 →
#   通用安装布局；探测不到即报错，**不内置任何本机默认路径**）。要显式指定时：
#   OHOS_HDC / OHOS_HVIGORW / OHOS_SDK_ROOT / OHOS_NDK / OHOS_CJK_FONTS_DIR
#   target device → OHOS_DEV（必须显式指定，无默认值）

# 0) 子模块与补丁（幂等，已应用即跳过；grunt-build.sh 全链会自动调用）
#    远端分布（判据 = .gitmodules 的 url）：
#      core / build_tools            → ONLYOFFICE 官方，pin release/v9.4.0
#      sdkjs / web-apps / desktop-apps → PureOffice fork 的 ohos 分支：定制已固化进
#        提交，checkout 即定制态——**没有** patch_sdkjs_desktop.sh 之类（已随 fork
#        化删除，别再找）
git submodule update --init
bash scripts/onlyoffice/patch_core_ohos.sh      # core OHOS 平台补丁（native 链前置；唯一剩下的 patch）
cp build-profile.json5.template build-profile.json5   # 本机签名配置（模板含说明；不入库）

# 1) 构建库产物（first time / clean 误清后）
python3 scripts/onlyoffice/core3d/gen_cmake.py
cmake -S build/core3d -B build/core3d/build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/scripts/onlyoffice/core3d/ohos-arm64.toolchain.cmake
cmake --build build/core3d/build -j$(nproc)

# 2) 一键：增量装配（空模板/注入 webapps/字体）+ HAP 打包 + 装机 + 重启
OHOS_DEV=<ip:port> bash scripts/onlyoffice/deploy_ohos.sh

# 3) 自动验收（可选）：启动带 m7accept 参数 → 自动打开样本并验证打开/保存链
hdc -t <ip:port> shell aa start -a EntryAbility -b app.fuqidian.pureoffice --ps m7accept 1
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
third_party/core|build_tools      # ONLYOFFICE 官方源码（submodule pinned）
third_party/sdkjs|web-apps|desktop-apps  # PureOffice fork（ohos 分支，定制即源码）
scripts/onlyoffice/
  desktop/grunt-build.sh          # 官方构建 + 装配唯一入口（--no-upstream 仅装配）
  desktop/ascdesktop_shim_raw.js  # 页面侧 AscDesktopEditor 适配层（装配期展开成桥方法）
  desktop/asc_methods.txt         # 桥需实现的方法清单（一行一个，装配期生成调用表）
  make_empty_templates.py         # 新建空模板（empty.docx/xlsx/pptx）
  build_editors_ohos.py           # 装配：webapps/sdkjs/fonts/index.html/smoke/version.json
  deploy_ohos.sh                  # 一键增量：装配(模板/注入) + 打包 + 安装 + 重启
  smoke/                          # 验收样本与诊断脚本（samples/ 子目录）
docs/                             # 设计/关键点/功能矩阵/合规方案（见下表）
```

## 常用命令

```bash
# 构建 HAP（严禁 clean——会清掉 build/core3d native 产物）；
# hvigorw 需在 PATH（或 export OHOS_HVIGORW=<path>），探测见 scripts/onlyoffice/env.sh
hvigorw assembleHap -p product=default --mode module --no-daemon

# 真机（多设备必须 -t <ip:port>）
hdc list targets
hdc -t <ip:port> install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t <ip:port> shell "aa force-stop app.fuqidian.pureoffice; aa start -a EntryAbility -b app.fuqidian.pureoffice"
hdc -t <ip:port> shell "uitest screenCap -p /data/local/tmp/s.jpeg" && hdc -t <ip:port> file recv /data/local/tmp/s.jpeg /tmp/s.jpeg   # 截图（本设备 uitest 无 snapshot_display）
```

## 踩坑速查

1. **hvigor 严禁 clean**——会删 build/core3d 的 libx2t.a，native 链接失败，重建 10+ 分钟。
2. **改动未见效**：先确认进包（`strings HAP | grep <新字符串>`）——.ets 增量可能不刷新。
3. **openDocument 字节必须 Uint8Array**——string 传入得到空模型或卡死。
4. **ArkTS→页面传二进制必须 base64 信封**——runJavaScript 走字符串会损坏 NUL 字节。
5. **产物不入库**：rawfile 运行时资源（webapps/sdkjs/fonts/index.html/…）
   全是构建产物，`grunt-build.sh` / `deploy_ohos.sh` 重生成；仅空模板与样本保留跟踪。
6. **sdkjs 双清单**：核心（sdk-all-min.js）与 common（sdk-all.js）由官方 loadSdk 自动加载，
   勿手工预载/向清单加类文件（加载顺序错误 = 字体链崩溃/打开静默失败）。
7. **改子模块分两条路**（判据 = `.gitmodules` 的 url）：指向 `PureOffice/*` 的
   （sdkjs/web-apps/desktop-apps）走 **fork 直提交 → `git -C third_party/<仓> push
   origin ohos` → 主仓 `git add` 更新指针**（不 push 则别人 clone 后 submodule
   update 失败）；指向 `ONLYOFFICE/*` 的（core）走 `patches/core-ohos/*.patch` 幂等
   应用，工作区 modified 是预期态、勿清理。详见 ONLYOFFICE_FORK_MIGRATION_PLAN.md
   头部与 §3.3。

## 文档里的历史文件指针（ascshim 于 2026-09-23 退役后）

多份设计文档写于 ascshim 时代，里面的**文件指针已失效**——机制都还在，只是位置变了。
读老文档时按本表换算：

| 文档里写的 | 现状 |
|---|---|
| `scripts/onlyoffice/desktop/src/*.js`（ascshim 段：`30_open` / `40_save` / `44_modalguard` / `09_fonts` …） | **已删**。对应机制在 `scripts/onlyoffice/ohos/{boot,bridge,fonts}.js`（DI 打开链、保存、焦点守卫、字体注册表）或三个 fork |
| `make_ascshim.py`、`desktop/src/assemble.txt` | **已删**。不再有 ascshim 生成步 |
| `patches/{sdkjs,webapps}-desktop/`、`patch_{sdkjs,webapps}_desktop.sh` | **已删**。定制改为进 fork（见上面速查 7） |
| ascshim 段号（「3.4 段 DI」「3.7 删 AscDesktopEditor」「3.8.2b 覆写」等） | 段号已无意义。按**机制名**在 `scripts/onlyoffice/ohos/` 或三个 fork 里搜 |

**定位某个机制现在在哪的最快路径**：

```bash
grep -rn "<机制关键词>" scripts/onlyoffice/ohos/ third_party/web-apps/apps third_party/sdkjs 2>/dev/null
```

### 行号与统计数字同样不可信

2026-09-25 抽样核实三份大文档共 60 处引用，**16 处行号不符**——fork 的定制提交持续
插入/删除行，一切 `file.js:行号` 都在持续漂移。统计数字同理（「88 个零依赖文件」实为 80、
「32 个主题 pptx」实为 36、「24 个 IS_NATIVE_EDITOR 文件」实为 32）。

**结论：按符号名搜，不要按行号跳。**
```bash
grep -rn "<方法名/符号名>" third_party/sdkjs third_party/web-apps scripts/onlyoffice/
```
个别已核实并修正的**断言性错误**（区别于行号漂移）在各文档内保留了「〔…核实〕」注记，
可据此判断某处是「位置过时」还是「事实有误」。

## 文档索引

| 文档 | 内容 |
|---|---|
| docs/ONLYOFFICE_OHOS_PORT_DESIGN.md | 总设计：B 架构决策依据、阶段路线图 |
| docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md | 关键点：DOCY v5/v10、打开/保存链、探针体系 |
| docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md | 保存链源码依据（不依赖服务器） |
| docs/ONLYOFFICE_OHOS_FEATURE_MATRIX.md | 功能支持矩阵：已实现/降级/未实现 + 升级路线 |
| docs/ONLYOFFICE_OHOS_PRODUCT_ROADMAP.md | 产品路线：P0-P2 差距清单 |
| docs/OPENSOURCE_COMPLIANCE_PLAN.md | 开源合规整改方案（AGPL） |
