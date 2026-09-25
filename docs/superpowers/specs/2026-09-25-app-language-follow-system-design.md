# 应用语言跟随系统（Follow System Language）设计

**Goal:** 应用启动时按设备系统语言选择界面语言（46 种随包语言），不再固定中文；系统语言不在支持列表时回退英文。

**Architecture:** 语言**只在宿主一处解析**（ArkTS 读系统 locale → 归一化成 ONLYOFFICE 语言短码），产出的短码喂给三个消费方：① 欢迎页 URL ② 编辑器页 URL ③ 宿主读语言包（新建文档默认名）。页面侧不改归一化逻辑——它已完备，宿主传归一化后的短码即可满足幂等。关闭文档回欢迎页的两处跳转改为从 URL 读 lang，不再硬编码。

**Tech Stack:** ArkTS（`@ohos.i18n`）、ONLYOFFICE 页面层（`webapps/apps/common/locale.js` 的 `_requireLang`）、注入段 `scripts/onlyoffice/ohos/boot.js`、web-apps patch 流程（`Gateway.js`）。

---

## 1. 背景

### 1.1 现有语言链（事实，含证据）

| 环节 | 事实 | 证据 |
|---|---|---|
| 语言资源 | **46 种语言已随包**：`webapps/apps/<app>/main/locale/*.json`（含 `zh.json`、`zh-tw.json`、`en.json`、`ja/ko/de/fr/es/ru…`） | `entry/src/main/resources/rawfile/onlyoffice/webapps/apps/documenteditor/main/locale/`（46 个文件） |
| 语言选择 | URL 参数 `lang` **优先级最高**，其次 `defLang` | `webapps/apps/common/locale.js` 的 `_requireLang`：`(l \|\| _getUrlParameterByName('lang') \|\| defLang)` |
| 归一化 | `lang.toLowerCase().split(/[-_]/)` → 取前两段；**只有 `['pt-pt','zh-tw','sr-cyrl']` 三个四字母码**被保留，其余取首段 | 同上，`_4letterLangs` 定义在 `locale.js:46` |
| 语言加载 | `fetch('locale/' + lang + '.json')`；**失败则回退 `defLang`** | 同上 |
| 回退语言 | `defLang = '{{DEFAULT_LANG}}'` 占位符**未被 grunt 替换** → 运行时 `if (defLang[0] == '{') currentLang = defLang = 'en'`，即**回退英文** | `locale.js:44-49`（部署产物中占位符仍在） |
| 欢迎页语言 | 同样由 URL `lang` 决定（`utils.inParams.lang`，缺省英文） | `EditorPage.ets:237-238` 注释 |
| 宿主已有词条机制 | 新建文档默认名**已从官方语言包读取**（键 `[DE\|SSE\|PE].Controllers.LeftMenu.newDocumentTitle`），只是 lang 写死 `'zh'` | `EditorPage.ets:512-538` |

### 1.2 归一化行为核对（逐例）

| 宿主传入 | 归一化过程 | 结果 | 语言文件 |
|---|---|---|---|
| `zh-Hans-CN` | `zh-hans` → 不在四字母表 → 取首段 | `zh` | ✅ |
| `zh-TW` / `zh-Hant-TW` | `zh-tw` 在表内 / `zh-hant` 不在表 → `zh` | `zh-tw` / **`zh`（错！繁体被降级为简体）** | ✅ / ❌ |
| `en-US` | `en` | `en` | ✅ |
| `pt-PT` / `pt-BR` | `pt-pt` 在表内 / `pt` | `pt-pt` / `pt` | ✅ / ✅ |
| `ja-JP` / `ko-KR` | `ja` / `ko` | `ja` / `ko` | ✅ |
| `sr-Cyrl` | `sr-cyrl` 在表内 | `sr-cyrl` | ✅ |
| `th-TH`（不支持） | `th` → fetch 404 | 回退 `defLang` = **英文** | ✅（回退路径） |

**关键结论**：归一化本身很完备，**唯一会出错的是繁体（`zh-Hant*` 被降级成简体）** —— 必须由宿主在传入前纠正为 `zh-TW`。

### 1.3 现状：lang 硬编码点（6 处）

| # | 位置 | 现状 | 归属 |
|---|---|---|---|
| 1 | `EditorPage.ets:241` `homeUrl()` | `+ '&lang=zh-CN'` | 宿主 |
| 2 | `EditorPage.ets:272` `editorUrl()` | `'…&lang=zh-CN&title='` | 宿主 |
| 3 | `EditorPage.ets:516` `defaultDocName()` | `const lang = 'zh'`（直读 `locale/zh.json`） | 宿主 |
| 4 | `ohos/boot.js:40` | `lang: 'zh-CN'`（`editorConfig.lang`） | 注入段（可直改） |
| 5 | `ohos/boot.js:75` | `goback.url: '…index.html?lang=zh-CN'` | 注入段（可直改） |
| 6 | `webapps/apps/common/Gateway.js:360` | `window.location.href = '…index.html?lang=zh-CN'`（`requestClose` 回欢迎页） | **web-apps fork → 走 patch 流程** |

### 1.4 宿主原生 UI 的文案（范围提示）

宿主 ArkTS 侧另有 **~109 处中文文案字面量**（`EditorPage.ets` 70、`common/userFonts.ets` 24、`pages/DocTabHost.ets` 10、其余 5）——tab 条、+ 菜单、字体管理对话框、错误提示等**原生 UI，不随 Web 侧语言变化**。这条决定下面的分阶段取舍。

---

## 2. 目标与非目标

**目标**
- 启动时按系统语言显示界面（欢迎页 + 编辑器 + 文档内菜单/提示）
- 系统语言不支持时回退英文
- 繁体中文用户拿到**繁体**而非简体

**非目标（本期）**
- 运行中切换系统语言**不即时生效**（页面 URL 在启动时构造；重启应用生效）
- 不提供应用内手动语言切换入口（见 §6 待决策）
- 宿主原生 UI 文案的多语言（见 §4 阶段 2）

---

## 3. 设计

### 3.1 语言解析（宿主，唯一入口）

新建 `entry/src/main/ets/common/lang.ets`，**模块级函数**（ArkTS 的 `struct` 不支持 static 方法，故不做成 `EditorPage` 的成员）：

```typescript
import i18n from '@ohos.i18n';

/** 系统 locale → ONLYOFFICE 语言短码（规则与页面 locale.js:_requireLang 一致，见 1.2）。
 *  返回值对页面归一化幂等，故 URL 与语言包共用同一值。 */
let cachedLang: string = '';

export function systemLang(): string {
  if (cachedLang.length > 0) { return cachedLang; }
  let loc = '';
  try {
    // API 20 起 getSystemLocale() 废弃（本项目 API 23）→ 用 Locale 实例
    const l = i18n.System.getSystemLocaleInstance();
    // 繁体必须显式给四字母码 'zh-tw'：否则 'zh-hant' 不在四字母表 → 被降级成简体。
    // 双保险：script 标记（'zh-Hant-TW'）与地区码（'zh-TW' 可能不带 script）都判。
    const trad = l.script === 'Hant' || ['TW', 'HK', 'MO'].indexOf(l.region) >= 0;
    if (trad) { cachedLang = 'zh-tw'; return cachedLang; }
    loc = l.language + (l.region ? '-' + l.region : '');
  } catch (e) {
    cachedLang = 'en';   // 取不到系统语言 → 英文
    return cachedLang;
  }
  const p = loc.toLowerCase().split(/[-_]/);
  const two = p[0] + (p.length > 1 ? '-' + p[1] : '');
  const four = ['pt-pt', 'zh-tw', 'sr-cyrl'];
  const i = four.indexOf(two);
  cachedLang = i < 0 ? p[0] : four[i];
  return cachedLang;
}
```

**要点**
- **进程内只算一次并缓存**：系统语言在应用生命周期内不变，而 URL 构造会多次调用。
- 返回值是**归一化后的短码**（`zh` / `zh-tw` / `en` / `ja` …），对页面的 `_requireLang` **幂等**（`zh`→`zh`、`zh-tw`→`zh-tw`），因此 URL 传它、宿主读语言包也用它，**两边天然一致**。
- **繁体的两条判据都要留**：`script` 依赖系统 locale 是否带 script 标记（`zh-Hant-TW` 带、`zh-TW` 可能不带），单靠 `script` 有漏判风险。
- 首次调用发生在页面构造期（`homeUrl()`），同步 API，无需异步等待（实现时真机确认）。

### 3.2 六处改动

| # | 改法 |
|---|---|
| 1、2 | `&lang=zh-CN` → `&lang=' + systemLang()`（引 `common/lang.ets`） |
| 3 | `const lang = 'zh'` → `const lang = systemLang()`（与 URL 用同一个值，保证新建文档默认名与界面语言一致） |
| 4 | `boot.js` 的 `editorConfig.lang`：从 `window.location.search` 读 `lang`（与同文件已有 `fileType`/`title` 同款写法），缺省保留 `'zh-CN'` |
| 5 | `boot.js` 的 `goback.url`：拼当前 URL 的 lang（同上读取；缺省 `'zh-CN'`） |
| 6 | `Gateway.js` 的 `requestClose` 跳转：同样读当前 URL 的 lang（**patch 入库**：`scripts/onlyoffice/patches/webapps-*`，与既有 `ColorPaletteExt` 依赖补丁同流程） |

**为什么 4/5/6 不直接沿用宿主传值**：这三处发生在**页面内跳转**（关闭文档回欢迎页），此时只需**保持当前语言**，从当前 URL 读是最省事且不会漂移的做法（无需宿主再注入一次）。

### 3.3 实施中补充的两处（用户验收时指出）

**① 关于面板的合规文案**（`third_party/desktop-apps/common/loginpage/src/panelabout.js`）

面板里两行合规文案原本是**硬编码中文**——`基于 ONLYOFFICE DesktopEditors（AGPL-3.0）` 与
`完整源码与第三方声明见 NOTICE`——不随语言变（同文件其他文案都走 `_lang.xxx`，只有这两行没有）。
改为语言包词条 `aboutLicenseLine` / `aboutSourceLine`，**含 `{link}` 占位符**（中英文括号与语序
不同，整句进词条才能两者都自然）。`zh-CN` / `zh-TW` / `en-GB` 三个包提供翻译，**其余 44 个包
无此词条时代码回落到英文兜底**（`|| 'Based on …'`）——与 §6 决策 1 的回退策略一致。

同处还有一处漏网（英文验证时才暴露）：版本行的前缀 `'版本 ' + ver` 也硬编码在
`panelabout.js` 的 `on_native_message` 载荷里，改为 `aboutVersionPrefix` 词条
（zh = `版本`、en = `Version`）。**教训：文案散落在「HTML 模板」与「事件载荷」两处**，
只扫模板会漏掉后者。

**② 新建文档的「文档语言」**（`make_empty_templates.py` + `EditorPage.openNewFile`）

**「文档语言」与「界面语言」是两套东西**：界面语言是 UI 文案，文档语言是写进文档内容里的标识
（决定状态栏显示、拼写检查、标点规则）——docx 存在 `styles.xml` 的 docDefaults `w:lang`，
pptx 是散在母版/版式里的 165 处 `lang="…"` 属性，**xlsx 格式本身没有这个字段**。
原实现构建期写死 `zh-CN`，于是英文界面下新建的文档仍标中文。

改法：模板生成**参数化文档语言**，产出两套——`empty.<ext>`（zh-CN，历史路径不变）与
`empty.en.<ext>`（en-US）；宿主按 `systemLang().startsWith('zh')` 选。两套的**默认字体**
（`eastAsia="SimSun"`）与段落格式完全一致——文档语言不该改变字形，中文内容在任何界面语言下
都应是宋体。

### 3.4 语言文件的存在性

宿主侧（`defaultDocName`）与页面侧（`fetch`）都以 `locale/<lang>.json` 为准：

- 短码来自 §3.1 的归一化，**可能不在 46 种内**（如 `th`）→ 宿主 `getRawFileContentSync` 会抛异常，**已有 try/catch 兜底**（`EditorPage.ets:532-534` 记 `DEFAULT_NAME_LOCALE_ERR`，走代码内英文兜底——已按 §6 决策 2 由直写中文改为英文，与整体回退策略一致）。
- **兜底文案改为英文**（§6 决策 2）：现在是直写中文（"未命名的文档"），与「回退英文」策略不一致——英文系统下会冒出中文文档名。

---

## 4. 分层实施

### 阶段 1：Web 侧跟随系统（本方案主体，建议先做）

改动 = §3.2 的 6 处 + §3.1 的工具函数 + 1 条 patch。

覆盖范围：**欢迎页、三个编辑器的全部界面**（菜单、工具栏、对话框、右键菜单、状态栏、新建文档默认名、报错提示）—— 即用户实际看到界面的绝大部分。

验收：改系统语言 → 重启应用 → 欢迎页与编辑器整体切到该语言；改回中文恢复；繁体系统显示繁体。

### 阶段 2：宿主原生 UI 文案资源化（已实施，2026-09-25）

**为什么必须做**（§6 决策 4）：不做的话，英文系统下会出现「编辑器里全英文，但顶部 tab 条、+ 菜单、字体管理对话框、toast 提示仍是中文」的中英混排——这些是 ArkTS 原生组件，不归 Web 侧语言管。

**落点**：
- `entry/src/main/resources/base/element/string.json` —— 英文（**base 即兜底**，与 §6 决策 1 一致）
- `entry/src/main/resources/zh/element/string.json` —— 中文
- 取值入口 `entry/src/main/ets/common/i18n.ets` 的 `t(res, ...args)`；`EntryAbility.onCreate` 注入 resourceManager（早于任何页面构造）

**语言选择完全交给 ArkTS 资源系统**——按系统 locale 自动选目录，代码里没有任何语言判断。新增语言 = 加一个 `resources/<lang>/element/string.json`，代码零改动。这比阶段 1 的「URL 传参 + 页面归一化」更根本。

**两个实现要点（都是实测踩出来的）**：

1. **资源目录用 `zh` 而非 `zh_CN`**。设备 locale 存的是 `zh-Hans`（语言 + script、**无 region 段**，真机 `param get persist.global.language` 实证）；`zh_CN` 是 language+country，匹配不上会**静默回退 base（英文）**。`zh` 只限定语言，覆盖全部中文变体。同理 `en` 覆盖 `en-Latn-US`。
2. **`getStringSync` 只有 rest 参数重载**（`(resId: number, ...args: (string|number)[])`），**没有数组参数形式**——传 `args` 数组会编译报 `No overload matches this call`，必须写成 `...args` 展开。

**为什么走「运行时取值返回 string」而不是把 Resource 交给组件**：有一批消费方只吃 string——picker 的 `fileSuffixFilters`、`DocTabCtx.title` / `PhoneHomeCard.name` 这类数据字段、`userFonts` 的 `{ok, msg}` 返回值。若 UI 组件走 Resource、这些走运行时取值，同一份代码就有两套类型，容易漏改也容易漂移。统一成 string 后调用点形态一致：`t($r('app.string.x'), arg)`。

**范围边界**：
- 宿主剩余的中文只有**诊断日志**（`arkLog` 内容）与 **P0 探针标识**（`p0tabs=1` 自动验收态）——都不是用户可见 UI，故不纳入。
- 「字体管理」弹层目前**无 UI 触发源**（手机主页入口注释保留、Web 侧栏命令 `font:manage` 无按钮挂载），只能靠命令通路触达。

---

## 5. 验证方案

**改设备语言的途径**：设置 → 系统和更新 → 语言和输入法 → 语言（手动操作，最可靠；`hdc shell param set persist.global.language` 是否生效取决于设备策略）。

| 用例 | 操作 | 判据 |
|---|---|---|
| 英文系统 | 设备语言设为 English → 重启应用 | 欢迎页/编辑器为英文；tab 条（宿主 UI）仍中文（阶段 1 预期） |
| 简体中文 | 设备语言设为简体中文 → 重启 | 全中文（与现状一致，**回归不倒退**） |
| 繁体中文 | 设备语言设为繁體中文 → 重启 | 显示**繁体**（`zh-tw.json`）；若显示简体即为 §1.2 的 `zh-Hant` 降级 bug 未修 |
| 不支持语言 | 设备语言设为泰语 → 重启 | 回退英文（不白屏、不报错） |
| 关闭回欢迎页 | 任一语言下打开文档 → 关闭 | 欢迎页语言与关闭前一致（验 #5/#6） |
| 新建文档名 | 英文系统下新建 docx | 默认名为英文词条（验 #3） |

**取证方式**：`uitest screenCap` 截图 + 肉眼比对（本设备 uitest 无 `snapshot_display` 命令）；宿主侧可加 `arkLog` 打印解析出的短码（如 `LSO_LANG zh-tw src=zh-Hant-TW`）便于回归时定位。

### 5.1 阶段 2 真机验证结果（2026-09-25，MatePad 1.6；设备语言经设置应用切换）

| 场景 | 中文（`zh-Hans`） | 英文（`en-Latn-US`） |
|---|---|---|
| 宿主 tab 条 | 主页 | Home |
| 「+」新建菜单 | 文档 / 电子表格 | Document / Spreadsheet / Presentation |
| 未保存守卫标题 | 未保存的文档 | Unsaved Document |
| 守卫正文（`%s` + `\n`） | 文档「未命名的文档.docx」有未保存的修改。 | The document "Unnamed document.docx" has unsaved changes. |
| 守卫按钮 | 取消 / 不保存 | Cancel / Don't Save |
| Web 侧（阶段 1 回归） | 全中文 | 全英文；状态栏 English – United States（英文模板生效） |
| 新建文档默认名 | 未命名的文档.docx | Unnamed document.docx |

**未逐个操作覆盖**：手机原生主页卡片、关于面板、字体管理弹层、picker 过滤器描述、各 toast/错误提示。前三者在 Pad/PC 形态**没有入口**（手机主页仅 phone 形态渲染，phone 设备 1.3 未在线；关于面板入口同）；picker 与 toast 未逐一触发。这些与已验项**共用同一 `t()` 机制与同一套资源文件**；资源文件另经静态校验：72 个 key 中英齐全、**占位符数量与类型序逐 key 一致**（防参数错位）、base 无中文残留。

---

## 6. 已决策（2026-09-25）

1. **回退语言 = 英文**（不支持的系统语言一律英文）。与页面现状一致：`locale.js` 的 `defLang` 占位符未被 grunt 替换 → 运行时 `'en'`，**零改动**。
2. **宿主兜底文案 = 英文**：`defaultDocName` 读不到语言包时直写英文（与第 1 条一致；现为直写中文，需一并改）。
3. **应用内手动语言切换入口：本期不做**（非目标）。
4. **阶段 2（宿主原生 UI 资源化）纳入实施**。

---

## 7. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 繁体降级 | `zh-Hant*` 若漏了 §3.1 的 `script === 'Hant'` 分支会被静默降级为简体 | 验收表专列繁体用例 |
| 宿主与页面语言不一致 | 若宿主传短码、页面自己再归一化，两边规则若漂移会导致「界面英文、新建文档名中文」 | 宿主**只算一次**短码，URL 与语言包共用（§3.1 幂等性已核对） |
| `Gateway.js` patch 漂移 | web-apps 升级后 patch 需重放 | 走既有 patch 流程（幂等，`patch_webapps_*.sh`） |
| 语言读取时机 | ArkTS 页面构造早于 `i18n` 可用？ | `getSystemLocaleInstance()` 为同步 API，且 `systemLang()` 首次调用在页面构造期；实测确认（API 23） |
