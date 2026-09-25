# ascshim 设计总览（web 层适配注入）

> **〔2026-09-23 已退役〕ascshim 主体已删除**：20 段定制全部源码化进三个 fork
> （见 `ONLYOFFICE_FORK_MIGRATION_PLAN.md`）；`make_ascshim.py` 与 `desktop/src/`
> 已不存在，运行时注入产物 `ascshim.js` 也不再生成。**新增适配不要按本文方式**。
> 仍留在构建链里的只剩 `desktop/ascdesktop_shim_raw.js` 与 `asc_methods.txt`
> （`build_editors_ohos.py` 读这两者生成 AscDesktopEditor 相关片段）。
> 子模块改动流程见 FORK_MIGRATION_PLAN 头部与 §3.3。

> 一句话：官方 web-apps / sdkjs 我们不改源码，**运行时把壳层适配注入进去**。
> 本文是这一层的**目录**——用来判断"该不该打开某个文件"，不是实现说明（实现细节在各段文件头部注释里）。

## 1. 为什么存在

B 架构 = 系统 WebView（ArkWeb）承载官方 web 编辑器 + native core（libconvertershell/x2t）做转换。
官方 web 产物假定自己跑在浏览器/CEF 里，与我们的壳有三处不匹配，故需要一层适配：

| 层 | 机制 | 位置 | 现状 |
|---|---|---|---|
| native | **patch 文件**（官方源码 + 幂等应用） | `scripts/onlyoffice/patches/core-ohos/*.patch` | 正规做法 ✅ |
| 构建期 | 资源装配 / index.html 改写 / 字体模板生成 | `build_editors_ohos.py`、`make_*`、`grunt-build.sh` | ✅ |
| **运行时** | **ascshim**（本文） | `scripts/onlyoffice/desktop/src/*.js` → `ascshim.js` | 本层 |

**生成链**：`src/*.js`（12 段，按序号拼接）→ `python3 make_ascshim.py`（拼装 + 占位符替换 + `node --check`）
→ `entry/src/main/resources/rawfile/onlyoffice/ascshim.js` → `build_editors_ohos.py` 把它作为
`<script src>` 注入各 app `index.html` 的 **`<head>` 首行**（早于官方所有脚本）。
**ascshim.js 是生成产物，勿手改**；改适配请改 `src/*.js` 后重跑（deploy 脚本已含此步）。

## 2. 副作用边界（重要）

ascshim 注入在 `<head>` 最早处——这带来一个后果：**官方对象此刻都还不存在**。

- **必须这么早的段**：`00_theme`（抢在官方 themeinit 读 localStorage 之前）、`09_fonts`（字体预取）、
  `20_bridge`（字体表要早于 sdk-all 加载）。
- **其余段**只能等官方对象出现——这就是各段里 `setTimeout` 轮询的来源，**不是设计失误，是早注入的代价**。
- 页门控（`pathname.indexOf('/main/index.html')`）用于区分"编辑器页 / 欢迎页"，两页共用同一份 ascshim。

## 3. 各段清单

| 段 | 干什么 | 依赖的官方契约 | 失效症状 | 判据日志 |
|---|---|---|---|---|
| `00_theme` | 默认主题=经典浅色 | 预写 `localStorage::ui-theme-id`（官方 themeinit 读、Themes.js 写） | 主题回落"跟系统" | `LSO_UITHEME` |
| `00_boot` | 公共工具 + 自动保存默认关 + **自检器** | — | — | `LSO_SHIM_STATUS` |
| `09_fonts` | CJK/系统字体字节装填（首帧方块修复） | `AscFonts.g_font_files` / `g_fonts_streams` / `FontStream`（sdkjs min） | 中文首帧方块 | `FONT_WARM_FILLED` |
| `10_engine` | Gateway 踢闸（serverId / images 引擎闸门）+ 字体流取证 | `Common.Gateway` 及其事件 | 文档加载卡住 | `LSO_GW_ONBIN_HOOKED` |
| `20_bridge` | AscDesktopEditor 装配（方法表 / 字体注册表 / LocalStartOpen 派发） | `window.desktop`、`__fonts_files` 契约 | 文档打不开 | `LSO_FB64_OVERRIDDEN`、`ASC_FOUND` |
| `30_open` | DI 打开链（loadConfig 补发 / CDocInfo / 权限 / 直调 Main）+ **新建入口**（`desktop://` 导航 → 桥命令） | 各 editor 的 `ApplicationController` / `Main`；全局 `window.open` | 打不开 / 空模型 / 点「新建」白屏 | `LSO_INIT_ALL_OK`、`LSO_CREATE_NEW` |
| `40_save` | 保存 / 关闭 / 文件菜单档位适配 + **放映全屏通道**（3.7 平常删除 `AscDesktopEditor`；3.7.1 在 `preview:show/hide` 期间临时恢复它——引擎据此才调 `SetFullscreen`） | sdkjs 保存链、`Gateway.requestClose`、web-apps `preview:show`/`preview:hide` | 存不了 / 另存为不可用 / **放映不进入壳层全屏**（画面只在 webview 内铺） | `LSO_SAVE_HOOKED`、`LSO_FS_BRIDGE` |
| `44_modalguard` | 壳层事件防护（native 缺失导致 handler 抛错 → Backbone 中断） | `Common.NotificationCenter` | 弹窗空白 / 主题只切一半 | `LSO_EVT_GUARD_HOOKED` |
| `45_print` | 打印链（`asc_Print` 覆写→元文件流）+ 打印机注入 + 快速打印 | sdkjs `asc_Print` / `asc_nativeGetPDF` | 打印按钮无反应 | `LSO_PRINT_HOOKED` |
| `50_init` | 初始化尾（等 `AscNative` 注入 → INSTALL） | `window.AscNative`（ArkWeb 注入） | 全链不工作 | `ASC_FOUND` |
| `55_lic` | 许可信息弹层 | 关于面板入口 | 许可链接无效 | — |
| `57_about` | 欢迎页「关于」入口（`app:version` 补发） | `window.sdk.fire('on_native_message', ...)` | 关于入口不显示 | `LSO_APP_VERSION_SENT` |

## 4. 自检：一行日志看全绿

每段 hook 就位时自登记（`window.__lsoShim` 数组），`00_boot` 的自检器在页面加载后汇总输出：

```
LSO_SHIM_STATUS ok=8/8 [theme,bridge,modal,fonts,engine,open,save,print] in 3200ms
LSO_SHIM_STATUS ok=6/8 MISSING [fonts,print] got [theme,bridge,modal,engine,open,save]
```

- 两页各自独立自检：**欢迎页期望 3 项**（theme/bridge/about）、**编辑器页期望 8 项**。
  欢迎页没有 `modal`（它不加载 webapps 的 `Common`，`NotificationCenter` 不存在）——
  首版自检曾在此误报 MISSING，据此把期望值从 `both` 改成 `editor`。
- 期望清单在 `00_boot.js` 的 `EXPECT` 里（页值 `editor` / `home` / `both`）——**新增段请顺手加一行**。
  漏登记只是少检查一项，不会误报。
- **用途**：官方升级 / 资源改动后，先看这一行，再决定要不要读代码。

真机读法：

```bash
hdc -t <dev> shell "grep LSO_SHIM_STATUS /data/app/el2/100/base/app.fuqidian.pureoffice/haps/entry/files/web_console.txt | tail -2"
```

## 5. 使用规则

1. **什么时候该打开 ascshim**：只有两种情况——① 官方 submodule 升级后自检报 MISSING；
   ② 新功能**必须**注入官方运行时对象（覆写原型 / 挂事件 / 等内部状态）。
2. **不该进来的**：能用 ArkTS 侧解决的（文件、权限、native 调用、UI 壳）、能用构建期解决的
   （资源、index.html、字体、模板）——一律不进 ascshim。
3. **每段只做一件事**，头部注释写清「根因 + 实证 + 失效征兆」；新增段同时更新本文表格与自检清单。
4. **验证靠真机日志**：各段的 `LSO_*` / `FONT_WARM_*` 判据见上表——日志是这一层唯一的验收面。
