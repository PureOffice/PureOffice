# POC-1 ONLYOFFICE 编辑器 WebView 渲染 + 桥 实现计划

> **For agentic workers:** 推荐用 superpowers:executing-plans 逐任务执行本计划。步骤用 checkbox（`- [ ]`）跟踪。

**Goal:** 在鸿蒙 Pad 真机跑通一个最小 HAP：用**系统 WebView** 渲染 ONLYOFFICE 编辑器（sdkjs），并让最小 `window.Asc.*` 原生桥走通 open/save/close 回调——验证「系统 WebView 渲染编辑器 + 异步桥改写」这条路可行。

**Architecture:** ArkUI/ArkTS 壳 + 系统 `Web` 组件 + `onInterceptRequest` 供给 `onlyoffice://` 资源 + `registerJavaScriptProxy` 注入 `window.Asc.*` 异步桥。ONLYOFFICE 前端（web-apps/sdkjs）打进 rawfile；编辑器画布/工具条由 sdkjs 渲染（**不依赖 core**——用内部格式示例/空文档，真实 docx 转换归 POC-2/3）。

**Tech Stack:** HarmonyOS NEXT 6.1.0(23)、ArkTS/ArkUI、系统 Web 组件(@ohos.web.webview)、CEF-only `onlyoffice://` scheme、sdkjs(JS)、hvigorw、hdc。

**前置约束（已确认）：**
- 目标真机 `192.168.1.8:33363`，hdc 在 `/apps/harmony/sdk/default/openharmony/toolchains/hdc`
- 对齐 wineohos：签名 `.ohos/*.cer|.p7b|.p12`、`targetSdkVersion=6.1.0(23)`、`runtimeOS: HarmonyOS`、`nativeCompiler: BiSheng`
- 工程根：`/data/share/office`（当前仅 `.temp`、`docs`）

---

### Task 1: 创建 OHOS HAP 工程骨架

**Files:**
- Create: `build-profile.json5`, `hvigorfile.ts`, `oh-package.json5`, `AppScope/app.json5`, `AppScope/resources/base/element/string.json`, `AppScope/resources/base/media/app_icon.png`
- Create: `entry/src/main/module.json5`, `entry/src/main/ets/entryability/EntryAbility.ets`, `entry/src/main/ets/pages/EditorPage.ets`(Task 3), `entry/src/main/resources/base/profile/main_pages.json`, `entry/src/main/resources/base/element/string.json`, `entry/src/main/resources/base/element/color.json`
- Copy: `../wineohos/.ohos/*` (签名证书), `../wineohos/hvigor/hvigor-config.json5`

- [ ] **Step 1: 建目录 + 拷签名/构建配置（不改动 wineohos）**

```bash
cd /data/share/office
mkdir -p AppScope/resources/base/element AppScope/resources/base/media \
  entry/src/main/ets/entryability entry/src/main/ets/pages \
  entry/src/main/resources/base/element entry/src/main/resources/base/profile \
  entry/src/main/resources/rawfile entry/src/main/resources/rawfile/onlyoffice \
  hvigor
cp ../wineohos/.ohos/* .ohos/ 2>/dev/null; mkdir -p .ohos && cp ../wineohos/.ohos/* .ohos/
cp ../wineohos/hvigor/hvigor-config.json5 hvigor/ 2>/dev/null
# 图标：从 wineohos 拷一个已存在的 media 图标（避免重新造图）
find ../wineohos -name 'app_icon.png' | head -1 | xargs -I{} cp {} AppScope/resources/base/media/app_icon.png
ls -R AppScope entry/src/main/resources | head -40
```

- [ ] **Step 2: 写 `build-profile.json5`**

```json5
{
  "app": {
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "./.ohos/default_WineHua_RVwdLEoMMxAEucWW3N5BFF3ZUbxXV0JDDsGj3yoRFUs=.cer",
          "keyAlias": "debugKey",
          "keyPassword": "00000019925D80B9B00A4F7EB96E01710867F5FAEF16EDAA43BCCEFE886442CCD39AD01DBCF2095E0B",
          "profile": "./.ohos/default_WineHua_RVwdLEoMMxAEucWW3N5BFF3ZUbxXV0JDDsGj3yoRFUs=.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "./.ohos/default_WineHua_RVwdLEoMMxAEucWW3N5BFF3ZUbxXV0JDDsGj3yoRFUs=.p12",
          "storePassword": "0000001962D48F70338CB8A384B52432F6C11FF794D49CCDBB0A014C8B2132EFA84BDEB452F578F4D7"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "targetSdkVersion": "6.1.0(23)",
        "compatibleSdkVersion": "6.1.0(23)",
        "runtimeOS": "HarmonyOS",
        "buildOption": { "nativeCompiler": "BiSheng" }
      }
    ],
    "buildModeSet": [ { "name": "debug" }, { "name": "release" } ]
  },
  "modules": [ { "name": "entry", "srcPath": "./entry", "targets": [ { "name": "default", "applyToProducts": ["default"] } ] } ]
}
```

> 签名 material 与 wineohos 一致（复用 debug 证书）。若你改用新证书，替换 `.ohos/*` 文件名与上面字段。

- [ ] **Step 3: 写 `hvigorfile.ts`**

```ts
import { appTasks } from '@ohos/hvigor-ohos-plugin';
export default { system: appTasks, plugins: [] }
```

- [ ] **Step 4: 写 `oh-package.json5`**

```json5
{ "name": "onlyoffice_poc1", "version": "1.0.0", "description": "POC1 webview render + bridge", "dependencies": {}, "devDependencies": { "@ohos/hvigor-ohos-plugin": "6.1.0" } }
```

- [ ] **Step 5: 写 `AppScope/app.json5`**

```json5
{ "app": { "bundleName": "com.onlyoffice.poc1", "vendor": "onlyoffice", "versionCode": 1000000, "versionName": "1.0.0", "icon": "$media:app_icon", "label": "$string:app_name" } }
```

- [ ] **Step 6: 写 AppScope 字符串**

`AppScope/resources/base/element/string.json`:
```json
{ "string": [ { "name": "app_name", "value": "OnlyOfficePOC1" } ] }
```

- [ ] **Step 7: 写 `entry/src/main/module.json5`**

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "description": "OnlyOffice editor render POC1",
    "mainElement": "EntryAbility",
    "deviceTypes": ["tablet", "phone", "2in1"],
    "deliveryWithInstall": true,
    "installationFree": false,
    "pages": "$profile:main_pages",
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "description": "$string:EntryAbility_desc",
        "icon": "$media:app_icon",
        "label": "$string:EntryAbility_label",
        "startWindowIcon": "$media:app_icon",
        "startWindowBackground": "$color:start_window_background",
        "exported": true,
        "skills": [ { "entities": ["entity.system.home"], "actions": ["action.system.home"] } ]
      }
    ]
  }
}
```

- [ ] **Step 8: 写 entry 资源文件**

`entry/src/main/resources/base/profile/main_pages.json`:
```json
{ "src": [ "pages/EditorPage" ] }
```
`entry/src/main/resources/base/element/string.json`:
```json
{ "string": [ { "name": "EntryAbility_desc", "value": "POC1" }, { "name": "EntryAbility_label", "value": "OnlyOffice" } ] }
```
`entry/src/main/resources/base/element/color.json`:
```json
{ "color": [ { "name": "start_window_background", "value": "#FFFFFF" } ] }
```

- [ ] **Step 9: 写 `EntryAbility.ets`**

```ts
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'Poc1';
const DOMAIN = 0x0001;

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/EditorPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent success');
    });
  }
}
```

- [ ] **Step 10: 写 `.gitignore` + 初始化 git**

```bash
cd /data/share/office
cat > .gitignore <<'EOF'
entry/build/
build/
.ohos/.certs/
node_modules/
oh_modules/
.hvigor/
EOF
git init 2>/dev/null
git add -A && git commit -m "chore: scaffold OHOS HAP project skeleton (POC-1)" 
```

**Expected:** 工程目录/文件齐全；`git status` 干净。

---

### Task 2: 拉取 ONLYOFFICE 前端（web-apps + sdkjs）并确定初始化入口

> POC-1 不依赖 core。只取 sdkjs（编辑器画布+最小工具条）与 web-apps（可选完整 UI）的静态产物，打包进 rawfile，用于"零上下文工程师"直接跑。

**Files:**
- Create: `entry/src/main/resources/rawfile/onlyoffice/`
- Create: `onlyoffice_frontend.sh`（拉取+拷贝脚本）
- Modify: none

- [ ] **Step 1: 写拉取脚本（clone sdkjs），拷贝产物到 rawfile**

```bash
cd /data/share/office
mkdir -p scripts/onlyoffice
cat > scripts/onlyoffice/fetch_frontend.sh <<'EOF'
#!/usr/bin/env bash
set -e
SDK_DIR=/data/share/office/.temp/onlyoffice_frontend
mkdir -p "$SDK_DIR" /data/share/office/entry/src/main/resources/rawfile/onlyoffice
cd "$SDK_DIR"
# sdkjs：编辑器引擎 + api（JS 库，无需构建即可被 <script> 引入）
[ -d sdkjs ] || git clone --depth=1 https://github.com/ONLYOFFICE/sdkjs.git
# web-apps：完整编辑器前端 UI（工具条/菜单），开源 AGPL 版
[ -d web-apps ] || git clone --depth=1 https://github.com/ONLYOFFICE/web-apps.git
# 拷贝到 rawfile
mkdir -p rawfileweb
cp -r sdkjs/docs rawfileweb/ 2>/dev/null || true
cp -r sdkjs/licenses rawfileweb/ 2>/dev/null || true
cp -r sdkjs/vendor rawfileweb/ 2>/dev/null || true
cp -r sdkjs/sdkjs rawfileweb/ 2>/dev/null || true
cp -r sdkjs/api rawfileweb/ 2>/dev/null || true
echo "RAWFILE_DEST=" /data/share/office/entry/src/main/resources/rawfile/onlyoffice
EOF
chmod +x scripts/onlyoffice/fetch_frontend.sh
./scripts/onlyoffice/fetch_frontend.sh
echo "--- sdkjs 顶层 ---"; ls /data/share/office/.temp/onlyoffice_frontend/sdkjs | head -30
echo "--- api 产物 ---"; ls /data/share/office/.temp/onlyoffice_frontend/sdkjs/api 2>/dev/null | head
```

- [ ] **Step 2: 确认 sdkjs 的编辑器初始化 API（读源码定入口，不臆造）**

```bash
cd /data/share/office/.temp/onlyoffice_frontend/sdkjs
echo "--- 找 api.js / editor 初始化入口 ---"
find . -maxdepth 3 -iname 'api.js' -o -iname '*editor*.js' 2>/dev/null | grep -viE 'node_modules|\.min\.' | head -20
echo "--- 找 最小宿主示例/测试 html（能直接跑编辑器的例子） ---"
find . -maxdepth 4 -iname '*.html' 2>/dev/null | head -20
```

**Expected:** 能定位到 `api.js`（供 `<script>` 引入的编辑器 API），以及一个可直接初始化编辑器的宿主 html 示例。若 sdkjs 自带可运行 demo，直接用它作我们宿主页的蓝本；否则用 Task 3 的宿主页 + 其公开 `Asc` 编辑器 API。**此步骤结果是 Task 3-5 宿主页与桥成员的依据，勿跳过。**

- [ ] **Step 3: 把 sdkjs/web-apps 产物拷进 rawfile（确定后可运行）**

```bash
# 上一步确定入口后，把需要的 sdkjs 静态产物拷入 rawfile（Task 4 用 onInterceptRequest 供给）
cp -r /data/share/office/.temp/onlyoffice_frontend/sdkjs/sdkjs \
      /data/share/office/entry/src/main/resources/rawfile/onlyoffice/sdkjs
cp -r /data/share/office/.temp/onlyoffice_frontend/sdkjs/api \
      /data/share/office/entry/src/main/resources/rawfile/onlyoffice/api
cp -r /data/share/office/.temp/onlyoffice_frontend/sdkjs/vendor \
      /data/share/office/entry/src/main/resources/rawfile/onlyoffice/vendor 2>/dev/null || true
find /data/share/office/entry/src/main/resources/rawfile/onlyoffice -maxdepth 2 | head -30
```

---

### Task 3: 宿主页面 `EditorPage.ets` — Web 组件 + 加载编辑器

**Files:**
- Create: `entry/src/main/ets/pages/EditorPage.ets`
- Create: `entry/src/main/resources/rawfile/onlyoffice/editor.html`
- Create: `entry/src/main/resources/rawfile/onlyoffice/data/document.json`（内部格式示例，POC-1 用空/极简文档）

- [ ] **Step 1: 写内部格式示例文档（极简，供编辑器加载）**

`entry/src/main/resources/rawfile/onlyoffice/data/document.json`（sdkjs 内部格式的最小样例，含空段落；ONLYOFFICE 内部格式由 sdkjs 解析）：
```json
{ "document": { "pages": [ { "paragraphs": [ { "text": "POC-1 编辑器渲染验证", "spans": [ { "text": "POC-1 编辑器渲染验证" } ] } ] } ], "size": { "width": 11909, "height": 16838 } } }
```

- [ ] **Step 2: 写 `editor.html` — 引入 sdkjs api 并用 `Asc` 初始化编辑器、暴露加载钩子**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no"/>
  <script src="/onlyoffice/api/scripts/api.js"></script>
  <style> html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden} #container{width:100%;height:100%} </style>
</head>
<body>
  <div id="container"></div>
  <script>
    window.onlyofficeBridge = null;
    // 宿主在页面加载后调用：初始化编辑器，加载内部格式
    window.initEditor = function () {
      var app = new Asc.editor(document.getElementById('container'), {});
      window.onlyofficeBridge = { app: app, counter: 0 };
      var url = '/onlyoffice/data/document.json';
      app.load(url, function (data){ /* 内部格式已加载 */ });
      return 'init-editor-ok';
    };
  </script>
</body>
</html>
```

> 说明：`Asc` / `editor.html` 的精确初始化 API 以 Task 2 Step 2 读到的 sdkjs 实际接口为准，必要时在此处微调（本例给出公开 `Asc.editor` 的可用形态）。

- [ ] **Step 3: 写 `EditorPage.ets` — 只含一个 `Web` 组件，加载 `onlyoffice://`**

```ts
import { webview } from '@kit.ArkWeb';
import { WebView, WebResourceRequest, WebResourceResponse } from '@kit.ArkWeb';

@Entry
@Component
struct EditorPage {
  controller: webview.WebviewController = new webview.WebviewController();

  // 最小原生桥：注入到 window.Asc.* 所依赖的宿主对象（异步代理）
  bridgeObj: object = {
    getDocumentsCount(): number { return 1; },
    getDocumentUrl(): string { return 'onlyoffice://app/editor.html'; },
    asc_saveDocument(): string { return 'ok'; }
  };

  build() {
    Column() {
      Web({ src: 'onlyoffice://app/editor.html', controller: this.controller })
        .javaScriptProxy({
          object: this.bridgeObj, name: 'Asc', methodList: ['getDocumentsCount', 'getDocumentUrl', 'asc_saveDocument'], controller: this.controller
        })
        .onInterceptRequest((event: WebResourceRequest): WebResourceResponse => {
          return loadFromRawfile(event.request.url);   // 见 Task 4
        })
        .onPageEnd(() => {
          // 页面加载完，调用 sdkjs 初始化 + 注入桥
          this.controller.runJavaScript('window.initEditor ? initEditor() : console.log("no initEditor")');
        })
        .onErrorReceive((event) => {
          console.error('Web error: ' + event.error.getErrorInfo());
        })
        .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }
}
```

---

### Task 4: `onlyoffice://` scheme → rawfile 资源供给（`onInterceptRequest`）

**Files:**
- Create: `entry/src/main/ets/common/rawfileLoader.ets`
- Modify: `EntryAbility` 或 `EditorPage.ets`（注册 loader）

- [ ] **Step 1: 写 rawfile 加载器**

`entry/src/main/ets/common/rawfileLoader.ets`：
```ts
import { WebResourceResponse, WebResourceRequest } from '@kit.ArkWeb';
import { resourceManager } from '@kit.LocalizationKit';

let rm: resourceManager.ResourceManager | null = null;
export function initResourceManager(manager: resourceManager.ResourceManager) { rm = manager; }

// 把 onlyoffice://app/<path> 映射到 rawfile/onlyoffice/<path>，读资源并返回
export function loadFromRawfile(url: string): WebResourceResponse {
  const rawPrefix = 'onlyoffice://app/';
  let path = '';
  if (url.startsWith(rawPrefix)) {
    path = url.substring(rawPrefix.length);
  } else {
    return new WebResourceResponse('text/plain', 'utf-8', '');
  }
  const raw = `onlyoffice/${path}`;
  try {
    const ary = rm!.getRawFileContentSync(raw);  // Uint8Array
    const body = new ArrayBuffer(ary.byteLength);
    new Uint8Array(body).set(ary);
    const mime = guessMime(path);
    return new WebResourceResponse(mime, 'utf-8', body);
  } catch (e) {
    console.error('rawfile miss: ' + raw + ' err=' + JSON.stringify(e));
    return new WebResourceResponse('text/plain', 'utf-8', '');
  }
}

function guessMime(p: string): string {
  if (p.endsWith('.js')) return 'application/javascript';
  if (p.endsWith('.json')) return 'application/json';
  if (p.endsWith('.html')) return 'text/html';
  if (p.endsWith('.css')) return 'text/css';
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.svg')) return 'image/svg+xml';
  if (p.endsWith('.woff2')) return 'font/woff2';
  if (p.endsWith('.ttf')) return 'font/ttf';
  return 'application/octet-stream';
}
```

- [ ] **Step 2: 在 EntryAbility 初始化 ResourceManager 并在页面用 loader**

在 `EntryAbility.onWindowStageCreate` 里加：`initResourceManager(this.context.resourceManager)`；`EditorPage.onInterceptRequest` 改为返回 `loadFromRawfile(request.url)`（把 Task 3 的占位替换为对本函数的调用）。

---

### Task 5: 注入 `window.Asc.*` 最小桥（`registerJavaScriptProxy`）+ 反向调用

**Files:**
- Modify: `EditorPage.ets`
- Create: `entry/src/main/ets/common/ascBridge.ets`

- [ ] **Step 1: 写桥对象定义，暴露给 JS（异步代理，方法列表对齐 sdkjs 需求）**

`entry/src/main/ets/common/ascBridge.ets`：
```ts
// window.Asc.* 的宿主侧实现。ONLYOFFICE sdkjs 通过 window.Asc.<member> 与原生交互。
// 桥成员以 Task2 Step2 读到的 sdkjs 实际调用为准；这里给 open/save/close 的最小可用集合。
export const ascBridge = {
  getDocumentsCount(): number { return 1; },
  getDocumentUrl(): string { return 'onlyoffice://app/editor.html'; },
  asc_saveDocument(args: string): string { console.log('Asc.saveDocument: ' + args); return 'ok'; },
  asc_closeDocument(): string { console.log('Asc.closeDocument'); return 'ok'; },
  asc_onFileOpened(): string { return 'ok'; }
};
export const ascBridgeMethodList = ['getDocumentsCount', 'getDocumentUrl', 'asc_saveDocument', 'asc_closeDocument', 'asc_onFileOpened'];
```

- [ ] **Step 2: 在 `EditorPage.ets` 用 `registerJavaScriptProxy` 注册（替代 `javaScriptProxy` 占位），并在 onPageEnd 运行 initEditor**

```ts
.controller.onPageEnd(() => {
  this.controller.registerJavaScriptProxy(ascBridge, 'Asc', ascBridgeMethodList);
  this.controller.refresh();
})
```

---

### Task 6: 构建 HAP + 真机部署

**Files:** none（仅命令）

- [ ] **Step 1: hvigor 配置检查 + 构建**

```bash
cd /data/share/office
export OHOS_SDK=/apps/harmony/sdk/default/openharmony
export PATH=$OHOS_SDK/toolchains:$PATH
# 若无全局 hvigorw，用 wineohos 的同款
ls /apps/harmony/bin/hvigorw && /apps/harmony/bin/hvigorw --version
/apps/harmony/bin/hvigorw clean --no-daemon
/apps/harmony/bin/hvigorw assembleHap --mode module -p product=default --no-daemon
echo "---  产物 ---"
find . -name '*.hap' 2>/dev/null
```

**Expected:** 在 `entry/build/default/outputs/default/` 生成 `entry-default-signed.hap`。

- [ ] **Step 2: 安装到真机 + 启动 + 看日志**

```bash
H=/apps/harmony/sdk/default/openharmony/toolchains/hdc
$H list targets
$H -t 192.168.1.8:33363 install -r entry/build/default/outputs/default/entry-default-signed.hap
$H -t 192.168.1.8:33363 shell aa start -a EntryAbility -b com.onlyoffice.poc1
$H -t 192.168.1.8:33363 hilog | grep -iE 'poc1|onlyoffice|Asc|initEditor|Web error' | tail -50
```

**Expected:** app 启动、无 `Web error`、日志出现 `initEditor` 相关输出。

---

### Task 7: 验证 POC-1 通过标准

- [ ] **Step 1: UI 验证（真机看屏/截屏）**

```bash
H=/apps/harmony/sdk/default/openharmony/toolchains/hdc
$H -t 192.168.1.8:33363 shell snapshot_display -f /data/local/tmp/poc1.png
$H -t 192.168.1.8:33363 file recv /data/local/tmp/poc1.png ./poc1.png
```
**Expected:** 截图显示编辑器画布出现「POC-1 编辑器渲染验证」文本、有工具栏痕迹、无白屏。

- [ ] **Step 2: 桥回调验证（runJavaScript 主动探测）**

在 `EditorPage` 增加一个调试按钮/入口或直接在 onPageEnd 追加：
```ts
this.controller.runJavaScript('window.Asc && (window.Asc.getDocumentsCount ? window.Asc.getDocumentsCount() : "no-asc")',
  (r) => console.log('Asc probe result: ' + r));
```
**Expected:** 日志 `Asc probe result: 1` —— 证明 `window.Asc.*` 桥已注入且回穿 native。

- [ ] **Step 3: 记录 POC-1 结论（渲染可行 + 桥走通）**

```bash
cat > /data/share/office/docs/poc1-result.md <<'EOF'
# POC-1 结论
- 日期: $(date +%F)
- 结果: PASS/FAIL
- 编辑器渲染: (WebView 显示 sdkjs 画布, 文本/工具条可见)
- window.Asc.* 桥: (open/save/close 回调是否走通, 哪些需调整)
- 存在的问题: ...
- 桥改写工作量清单: (逐回调列: 留JS/走桥/需重写)
EOF
```

> 若 FAIL 且卡在"桥成员对不上 sdkjs"→ 回 Task 2 Step 2 按实际 sdkjs 调用修正 `ascBridge` 成员，重跑 6/7。若 FAIL 卡在"WebView 加载不了 sdkjs 资源"→ 排查 Task 4 的 mime 与 rawfile 路径。

---

### Task 8: 性能/回调频率实测（POC-1 附加验收项）

- [ ] **Step 1: 记录高频回调**

在 `ascBridge` 各方法加计数器并定期回传：
```ts
let counters: Record<string, number> = {};
Object.keys(ascBridge).forEach(k => { const o = ascBridge[k as keyof typeof ascBridge] as any; const f = o; ascBridge[k as keyof typeof ascBridge] = (...a:any[]) => { counters[k] = (counters[k]||0)+1; return f.apply(null,a); }; });
```
再加一个 `runJavaScript` 定期（如每 5s）取 `counters` 打日志，观察：哪些成员被高频调、是否都在 JS 侧消化（只有 I/O 类走原生）。用于判定"留 JS 还是走桥、异步降级是否够"。

- [ ] **Step 2: 大文档加载耗时**

把 `document.json` 换成较大内部格式（或临时用 sdkjs 示例大文档），用 `onInterceptRequest` 计时 + `onPageEnd` 计时，记录首屏时间。验证"文件 URL / onInterceptRequest 喂内容、避免大字符串过桥"是否成立。

---

## Self-Review 记录

- **Spec 覆盖**：§5 POC-1 目标（UI 渲染/输入滚动、open/save/close 回调走通、桥同步→异步换算、性能实测）→ 对应 Task 3(渲染)/Task 5(桥)/Task 7(验证+清单)/Task 8(性能)。§6 工程结构 → Task 1。§7 部署链路 → Task 6。✓
- **占位符扫描**：无 TBD/TODO；sdkjs 初始化 API（Task 2 Step2 先读源码再定，Task 3/5 给了可用的公开 `Asc` 形态并在任务内注明"以实际为准/必要时微调"）— 属"读仓库定型"的渐进式步骤，非空白占位。✓
- **类型一致性**：`loadFromRawfile`/`initResourceManager`(Task4) 在 Task3 引用；`ascBridge`/`ascBridgeMethodList`(Task5) 在 Task3/5 同名引用。✓
- **现实依赖**：POC-1 用"空/极简内部格式 + sdkjs"渲染，**不依赖 core**——把 POC-1 与 POC-2(core 交叉编译)解耦，保证 POC-1 能独立交付"渲染+桥"结论。

> 注：`Asc.editor` 初始化与 sdkjs 内部格式 JSON 的确切结构存在版本差异风险，Task 2 Step 2 的"先读 sdkjs 实际 demo"是本计划最关键的一次实际核验；由此确定的 API/格式会回填 Task 3/5。
