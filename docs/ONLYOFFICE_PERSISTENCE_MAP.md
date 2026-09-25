# 持久化键清单与升级风险底图

背景：用户反馈「升级后新建文档空白」未确诊；本应用的部署形态（单机 WebView +
永久持久化 + 高频升级）是官方未处理过的组合，web 层持久化状态没有版本/迁移机制。
本文是 2026-09-25 对全部持久化面的一次摸排底图，用于排查「升级后行为异常」类
问题时快速定位状态域。

## 总结论

**web 层 localStorage 没有「坏了出空白/打不开」级的危险域键。** 官方偏好域占绝对
多数且天然自愈（读不到回默认）；引擎没有 IndexedDB/文档缓存库；Desktop 本地链
（`sdkjs/common/Local/`）不含持久化调用。因此「升级后空白」类故障的嫌疑重心不在
localStorage，而在**字体链（内置表 × 用户字体旧清单）与启动链本身**。

## 摸排方法与覆盖面

- `Common.localStorage`（web-apps `util/LocalStorage.js`）封装调用点：web-apps 四处
  apps 全量提取键名（common/lib + documenteditor + spreadsheeteditor +
  presentationeditor）
- 不走封装的直接 `localStorage.*`：web-apps 仅 `htmlutils.js`（test 探测 /
  settings-ui-rtl / content-theme 三处）
- sdkjs 直接调用：`keychainstorage.js` / `apiBase*.js` / `cell/api*.js` 个位数处
- IndexedDB：web-apps + sdkjs 全域 grep 零命中
- 宿主沙箱：`entry/src/main/ets/` 全量写盘点

## web 层键分类（约 230 个）

### 1. 偏好域（~225 个，风险：极低）

前缀 `de-` / `sse-` / `pe-`。缩放、面板宽度、工具栏形态、autoformat 开关、
编码/分隔符/单位、拼写选项、recent shapes/bullets/functions、各提示隐藏位等。
语义 = 「读不到用默认值」，坏了的表现是体验回退，不是功能损坏。升级跨版本时
新增/改名键自动走默认，无需迁移。

### 2. 主题三键：`ui-theme-id` / `ui-theme` / `content-theme`（风险：低~中，显示级）

- fork 侧 `web-apps/apps/common/main/lib/util/themeinit.js`：
  `uitheme.set_id(localStorage.getItem("ui-theme-id") || 'theme-classic-light')` ——
  旧版本存的 id 升级后在主题清单中不存在时的具体表现**未实测破坏态**（按官方
  回退逻辑应为显示级问题，不是空白）。
- `content-theme` 在 `htmlutils.js:202` 决定暗色 body class，同样显示级。
- 排查「升级后界面变色/样式错」先看这三个键。

### 3. 身份类：`guest-id` / `guest-username`（风险：无）

协同场景身份，离线部署不消费。

### 4. 插件域（风险：低，可清除自愈）

`asc_plugins_background` / `asc_plugins_background_stopped`
（`apiBase_plugins.js` 后台插件服务表）、`asc_plugin_commands_log`、
插件通用 key（`apiBase_plugins.js:1409-1420`）。AI 插件启用中；结构升级导致
解析失败时表现为插件后台异常，清除对应键即自愈。

### 5. 加密键 `oo-crypto-object`（风险：无）

`keychainstorage.js` 的协同密钥链记录存储。本部署的加密文档走 x2t
`m_sPassword` 直传，不消费该键。

### 6. 共键双语义：`sse-spellcheck-locale`（风险：低，需长期盯）

**我们与官方共用一个键、语义不同**：官方 `Spellcheck.js` 把它当「拼写检查语言」
设置读写；fork 侧 `sdkjs/cell/api.js` 读它做**文档默认语言**初始化（缺省 2052，
回归 case `newlang-xls`）。用户在官方设置里改过拼写语言 → 同时改变我们的文档
语言兜底值。值域都是 locale 数字，当前兼容；跨版本若官方改值语义需重审。

## 宿主沙箱持久化

| 文件/目录 | 写者 | 升级行为 | 风险评估 |
|---|---|---|---|
| `files/recents.json` | recents.ets | 保留 | 低。损坏容错好：解析失败不重写文件（防脏数据扩散），调用方按空处理 |
| `files/userfonts/` + `index.json` | userFonts.ets | 保留 | **中。见下** |
| `files/app_version.json` | EditorPage | 对比触发 removeCache | 机制本体（资源缓存自愈） |
| `files/samples/` | copySandboxSamples | 每次启动重拷 | 无 |
| `_offline_media/<tab>/` | x2t 转换链 | 启动 sweep 兜底 | 无 |
| `files/web_console.txt` | arkLog | 每次启动 TRUNC | 无 |

### 用户字体是唯一残余中危项

`index.json` 格式 `{"v":1,"fonts":[{id,file,family,...}]}` —— **按名存储、无下标**
（安全设计，运行时 `g_font_files.length` 追加分配，内置字体文件数变化不会错位）。
但两个缺口：

1. **`"v":1` 版本字段没有消费方**——只写不校验，纯摆设。将来格式真变化时
   没有任何迁移钩子。
2. **「新内置字体表 × 旧用户清单」组合未在字体表大改版本后验证过**。宋体族
   别名、黑体换 Noto 这类大动作后，老用户的导入字体与重排后的注册表的交互
   只被「按名解析」这层约定保护着。

缓解：字体表大改的发版，验证清单里加一条「带旧导入字体的升级模拟」（装旧版
导字体 → 覆盖装新版 → 验下拉与渲染）。

## 对「升级后空白」反馈的排查指向

底图完成后，web 状态域基本排除（无空白级键），嫌疑排序更新为：

1. **字体链**：内置表大改 × 用户字体旧清单（上节中危项）；或字体注册/渲染槽
   失败（表现恰为「整 run 空白」且静默）
2. **启动链 JS 死**：web_console.txt 找 `JSERR` / `MISSING` 三件套（参照
   ColorPaletteExt 前案）
3. WebView 磁盘缓存：已有 `?v=` + removeCache 双自愈，排后面
   （前车之鉴：不得用缓存清理解释页面行为 bug）

用户侧最强二分仍是**卸载重装**：清掉沙箱+localStorage 后正常 → 状态域问题
（此时按本底图逐域二分）；仍空白 → 包本身问题，本地可复现。
