# 碰一碰传送（Share Kit）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-09-27-knock-share-design.md` 落地三场景——A 接收图片插入当前文档、B 接收文档立即打开、C 当前文档导出临时文件发送。

**Architecture:** 全部改动在主仓 ArkTS 壳层（fork 零改动）：新模块 `common/knockShare.ets` 承担注册/能力表/临时目录；接收复用 onShowFileSelector 应答链（ctx 挂 pending 直答，跳过 picker）；发送复用 `saveAsBin` 的转换内核（b64→x2t→产物校验）落 cache 临时目录后 `sharableTarget.share()`。引擎与页面资产零改动。

**Tech Stack:** ArkTS（API 23）、`@kit.ShareKit`（harmonyShare/systemShare）、`@kit.ArkData`（uniformTypeDescriptor）、既有 formats/bytes/fs 工具。

**验证基线说明:** 本仓库无 ArkTS 单测框架，任务内验证 = hvigor 编译通过 + `node --check`（如有 js）+ 代码走查；真机联调为 Task 7（后置，用户给 1.3↔1.5 设备后执行）。

---

### Task 1: `common/knockShare.ets` 模块（能力表 + 注册 + 临时目录 + UTD 映射）

**Files:**
- Create: `entry/src/main/ets/common/knockShare.ets`

- [ ] **Step 1: 写模块**

```typescript
/**
 * knockShare.ets —— Share Kit 碰一碰传送的注册与能力声明（设计
 * docs/superpowers/specs/2026-09-27-knock-share-design.md）。
 *
 * 职责单一：注册/解除、能力表、接收临时目录、后缀→UTD 映射。收发业务
 * （插入图片/打开文档/导出发送）在 EditorPage——本模块不持有页面状态。
 *
 * 生命周期纪律：onPageShow 注册、onPageHide 必须解除——后台持注册是
 * 官方样例明示的错误态。
 *
 * 接收能力（dataReceive）= general.image + formats 全部 9 格式的精确 UTD。
 * UTD 值与 module.json5 打开方式注册逐字一致（实测规范化结果）；收发两端
 * 都用精确类型（官方体验规范「发起分享需使用精细化的 utd 类型」）。对端
 * 发来的类型与能力不匹配时系统走华为分享默认接收（落系统目录）——那是
 * 官方兜底语义，不是错误，本层不处理。
 */
import { harmonyShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';

/** 后缀 → 精确 UTD（发送侧 SharedData 用；与 module.json5/FormATS 同源维护） */
const UTD_BY_EXT: Record<string, string> = {
  'docx': 'org.openxmlformats.wordprocessingml.document',
  'doc': 'com.microsoft.word.doc',
  'rtf': 'general.rich-text',
  'txt': 'general.plain-text',
  'xlsx': 'org.openxmlformats.spreadsheetml.sheet',
  'xls': 'com.microsoft.excel.xls',
  'csv': 'general.comma-separated-values-text',
  'pptx': 'org.openxmlformats.presentationml.presentation',
  'ppt': 'com.microsoft.powerpoint.ppt',
};

export function utdOfExt(ext: string): string {
  const u = UTD_BY_EXT[ext];
  return (u !== undefined) ? u : '';
}

/** dataReceive 能力表（图片 + 9 文档格式） */
export function recvCapabilities(): harmonyShare.RecvCapability[] {
  const caps: harmonyShare.RecvCapability[] = [
    { utd: utd.UniformDataType.IMAGE, maxSupportedCount: 5 },
  ];
  const exts = Object.keys(UTD_BY_EXT);
  for (let i = 0; i < exts.length; i++) {
    caps.push({ utd: UTD_BY_EXT[exts[i]], maxSupportedCount: 5 });
  }
  return caps;
}

/** 设备是否具备碰一碰能力（syscap 探测；不支持时宿主不注册，轻碰无响应=官方语义） */
export function knockSupported(): boolean {
  return canIUse('SystemCapability.Collaboration.HarmonyShare');
}

export interface KnockReceivable {
  /** 收到可接收数据（target 需立即 receive/reject，不可持有跨事件） */
  onReceivable: (target: harmonyShare.ReceivableTarget) => void;
  /** 对端碰一碰请求分享（宿主导出临时文件后 target.share） */
  onKnock: (target: harmonyShare.SharableTarget) => void;
}

let registered = false;
let receivable: KnockReceivable | null = null;

/**
 * 注册碰一碰收发事件（windowId=主窗口；单窗口应用恒定）。
 * 重复注册前先解除——on/off 以 capabilityRegistry 为键，幂等由此保证。
 */
export function knockRegister(winId: number, recv: KnockReceivable,
  log: (m: string) => void): void {
  if (!knockSupported()) {
    log('KNOCK_REG_SKIP no-syscap');
    return;
  }
  knockUnregister(log);
  receivable = recv;
  const sendReg: harmonyShare.SendCapabilityRegistry = { windowId: winId };
  harmonyShare.on('knockShare', sendReg, (target: harmonyShare.SharableTarget) => {
    log('KNOCK_EVENT knockShare');
    if (receivable !== null) {
      receivable.onKnock(target);
    }
  });
  const recvReg: harmonyShare.RecvCapabilityRegistry = {
    windowId: winId,
    capabilities: recvCapabilities(),
  };
  harmonyShare.on('dataReceive', recvReg,
    (target: harmonyShare.ReceivableTarget) => {
      log('KNOCK_EVENT dataReceive');
      if (receivable !== null) {
        receivable.onReceivable(target);
      }
    });
  registered = true;
  log('KNOCK_REG win=' + winId);
}

/** 解除注册（onPageHide 必调；未注册时 no-op） */
export function knockUnregister(log: (m: string) => void): void {
  if (!registered) {
    return;
  }
  try {
    const sendReg: harmonyShare.SendCapabilityRegistry = { windowId: 0 };
    // windowId 只用于注册去重，off 传相同结构即可（系统按 event 类型匹配）
    harmonyShare.off('knockShare', sendReg);
    const recvReg: harmonyShare.RecvCapabilityRegistry = {
      windowId: 0,
      capabilities: recvCapabilities(),
    };
    harmonyShare.off('dataReceive', recvReg);
  } catch (e) {
    log('KNOCK_OFF_ERR ' + String(e));
  }
  registered = false;
  receivable = null;
  log('KNOCK_UNREG');
}
```

注意：`harmonyShare.off` 的 capability 参数如与 on 时不一致导致解除失败（真机验证点），fallback 是持有 on 时的同一对象引用在模块级（把 sendReg/recvReg 提为模块级变量），Step 2 走查时确认。

- [ ] **Step 2: 修订 off 一致性**

把 `knockRegister` 里的 `sendReg`/`recvReg` 提升为模块级变量 `let sendReg: ... | null` / `let recvReg: ... | null`，`knockUnregister` 使用注册时保存的同一引用并在成功后置 null。`off` 失败场景（回调仍在）比「解除失败但置 registered=false」更糟——所以 try/catch 里失败也要 `registered` 保持 true 并打日志。

- [ ] **Step 3: 编译验证**

```bash
. scripts/onlyoffice/env.sh && cd /data/share/office && "$OHOS_HVIGORW" assembleHap -p product=default --no-daemon 2>&1 | tail -5
```
Expected: `BUILD SUCCESSFUL`（此时模块未被引用，仅验证语法/导入）。

---

### Task 2: DocTabCtx 挂 pending + onShowFileSelector 直答（场景 A 后半段）

**Files:**
- Modify: `entry/src/main/ets/pages/DocTabHost.ets:69`（DocTabCtx 字段）与 `:377`（onShowFileSelector 绑定）

- [ ] **Step 1: DocTabCtx 加字段**

在 `DocTabCtx` 的 `onPickFile` 声明（:96）前加：

```typescript
  /** 碰一碰接收的待插图片（绝对路径；非空时下一次 onShowFileSelector 直答它并清空。
   *  挂 per-tab 而非页面级：FileSelector 请求自带 ctx，页面级状态会串 tab） */
  pendingKnockImage: string = '';
```

- [ ] **Step 2: onShowFileSelector 直答分支**

读 `:377` 附近现有绑定（形如 `.onShowFileSelector((event) => { ... ctx.onPickFile(event.result, acceptTypes) })`），在该回调体**最前**加：

```typescript
    .onShowFileSelector((event) => {
      // 碰一碰接收直答（场景 A 后半段）：pending 非空 = 本次请求由
      // asc_addImage() 触发，跳过 picker 直接回填已接收文件——后半段
      // （引擎 _uploadCallback → 落图）与用户选图链完全同路。用后即清，
      // 先到而 pending 为空的请求照常走 picker（正常插图不回归）。
      if (ctx.pendingKnockImage.length > 0) {
        const p = ctx.pendingKnockImage;
        ctx.pendingKnockImage = '';
        ctx.log('KNOCK_PICK_DIRECT ' + p);
        event.result.handleFileList([p]);
        return true;
      }
      ...（现有代码不动）
    })
```

（以现有回调实际结构为准——若回调经 helper 转发 `ctx.onPickFile`，分支加在绑定处、转发之前。）

- [ ] **Step 3: 编译验证**

同 Task 1 Step 3。Expected: `BUILD SUCCESSFUL`。

---

### Task 3: EditorPage 接收路由（场景 A 插图 + 场景 B 打开 + 注册生命周期）

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`

- [ ] **Step 1: 导入与状态**

文件头 import 区加：

```typescript
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { knockRegister, knockUnregister, knockSupported } from '../common/knockShare';
```

struct 内（约 :193 `saveBusy` 附近的状态区）加：

```typescript
  /** 碰一碰接收在途（reject 幂等防抖） */
  private knockRecvBusy: boolean = false;
```

- [ ] **Step 2: 注册/解除钩子**

@Entry struct 直接加页面级生命周期（与 `aboutToAppear` 平级）：

```typescript
  onPageShow(): void {
    try {
      const actx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(actx).then((mw: window.Window) => {
        const winId = mw.getWindowProperties().id;
        knockRegister(winId, {
          onReceivable: (target: harmonyShare.ReceivableTarget) => {
            this.onKnockReceivable(target);
          },
          onKnock: (target: harmonyShare.SharableTarget) => {
            this.onKnockShare(target);
          },
        }, (m: string) => this.arkLog(m));
      }).catch((e: Object) => {
        this.arkLog('KNOCK_WIN_ERR ' + String(e));
      });
    } catch (e) {
      this.arkLog('KNOCK_REG_ERR ' + String(e));
    }
  }

  onPageHide(): void {
    // 后台持注册是官方样例明示的错误态——页面不可见即解除
    knockUnregister((m: string) => this.arkLog(m));
  }
```

- [ ] **Step 3: 接收实现（场景 A/B）**

struct 内私有方法区加：

```typescript
  /** 碰一碰接收（场景 A 图片→插入当前文档 / 场景 B 文档→立即打开）。
   *  receive 的目录参数用 cache 专用子目录：文件被打开链/插图链拷走后即
   *  无用，启动 sweepKnockFiles 统一清。 */
  private onKnockReceivable(target: harmonyShare.ReceivableTarget): void {
    if (this.knockRecvBusy) {
      target.reject(harmonyShare.ReceivableErrorCode.NO_RECEIVABLE_ERROR);
      return;
    }
    const ctx = this.activeDocCtx();
    if (ctx === null) {
      // 无打开文档：图片无处可插，诚实拒绝（系统侧向发送端提示）
      this.arkLog('KNOCK_RECV_REJECT no-doc');
      target.reject(harmonyShare.ReceivableErrorCode.NO_RECEIVABLE_ERROR);
      return;
    }
    this.knockRecvBusy = true;
    const aCtx = getContext(this) as common.UIAbilityContext;
    const dstDir = aCtx.cacheDir + '/knock';
    try {
      fs.mkdirSync(dstDir);
    } catch (e) {
      // 已存在——正常路径
    }
    target.receive(dstDir, {
      onDataReceived: (sharedData: systemShare.SharedData) => {
        try {
          const recs = sharedData.getRecords();
          for (let i = 0; i < recs.length; i++) {
            const u = recs[i].uri;
            if (u === undefined || u.length === 0) {
              continue;
            }
            this.knockHandleFile(ctx, u);
          }
        } catch (e) {
          this.arkLog('KNOCK_RECV_DATA_ERR ' + String(e));
        }
      },
      onResult: (resultCode: harmonyShare.ShareResultCode) => {
        this.arkLog('KNOCK_RECV_RESULT code=' + resultCode);
        this.knockRecvBusy = false;
      },
    });
  }

  /** 单个接收文件处理：按后缀分流（图片→pending+asc_addImage；文档→打开） */
  private knockHandleFile(ctx: DocTabCtx, uri: string): void {
    let base = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      base = decodeURIComponent(base);
    } catch (de) {
      // 同 handleLocalUri：编码异常按原样
    }
    base = base.replace(/[\\/]/g, '_');
    const dot = base.lastIndexOf('.');
    const ext = dot > -1 ? base.substring(dot + 1).toLowerCase() : '';
    if (ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'gif'
      || ext === 'bmp' || ext === 'webp') {
      // 场景 A：拷进本 tab 工作目录（与 PICKFILE_OK 同落点）→ 挂 pending →
      // 调 asc_addImage()（=用户点「插入图片」）→ 引擎发起 onShowFileSelector
      // → Task 2 的直答分支回填
      const ab = readFileBuf(uri);
      if (ab === null) {
        this.arkLog('KNOCK_IMG_READERR ' + uri);
        return;
      }
      const dst = ctx.tabPath(base);
      if (!writeFileBuf(dst, ab)) {
        this.arkLog('KNOCK_IMG_WRITE_ERR ' + dst);
        return;
      }
      ctx.pendingKnockImage = dst;
      this.arkLog('KNOCK_IMG_READY tab=' + ctx.id + ' ' + base
        + ' bytes=' + ab.byteLength);
      ctx.js('(function(){try{'
        + 'if(window.editor&&window.editor.asc_addImage){'
        + 'window.editor.asc_addImage();console.error("KNOCK_ADDIMG ok");}'
        + 'else{console.error("KNOCK_ADDIMG nf");}}catch(e)'
        + '{console.error("KNOCK_ADDIMG err "+e);}})()', 'knock');
      return;
    }
    if (specOf(ext) !== null) {
      // 场景 B：文档 → 现有打开链（readFileBuf → openNewTabEntry；userUri=接收
      // 临时文件路径，保存目标=该路径——接收件视同用户文件）
      const ab = readFileBuf(uri);
      if (ab === null) {
        this.arkLog('KNOCK_DOC_READERR ' + uri);
        return;
      }
      this.arkLog('KNOCK_DOC_OPEN ' + base + ' size=' + ab.byteLength);
      this.openNewTabEntry(ab, ext, base, true, false, uri);
      return;
    }
    this.arkLog('KNOCK_FILE_SKIP ext=' + ext);
  }
```

说明：`activeDocCtx()` 若 EditorPage 已有「当前活跃 doc tab」获取方式（docTabs/kind 判定），复用之；否则加：

```typescript
  /** 当前活跃的文档 tab（home tab 或空态返回 null） */
  private activeDocCtx(): DocTabCtx | null {
    const ctx = this.curCtx();  // 以 DocTabHost 暴露的当前 tab 取值为准
    return (ctx !== null && ctx.kind === 'doc') ? ctx : null;
  }
```

（`curCtx` 对应 DocTabHost 的当前 tab 访问器——实施时按 `docTabs`/Tabs `onChange` 的现有索引取值，勿新造状态。）

- [ ] **Step 4: 编译验证**

同前。Expected: `BUILD SUCCESSFUL`。（`onKnockShare` 引用的方法在 Task 4 实现——本任务先放空壳 `private onKnockShare(_t: harmonyShare.SharableTarget): void { }`，Task 4 替换。）

---

### Task 4: 发送链（场景 C：临时文件导出 + share）

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets`（saveAsBin 拆内核 + doSendTemp + onKnockShare 实现）

- [ ] **Step 1: saveAsBin 拆出转换内核**

现 `saveAsBin(ctx, param)`（:456）中「b64 解码 → in.bin 落盘 → x2t → 产物校验 → outBuf」整段抽成：

```typescript
  /** saveAsBin/doSendTemp 共用转换内核：DOCY b64 → 目标格式字节（落 tab 临时槽，
   *  产物 zip 校验）。失败返回 null（日志齐备）。 */
  private convertSaveBytes(ctx: DocTabCtx, param: string): ArrayBuffer | null {
    // ——原 saveAsBin 的 try 块体（b64ToBuf 起、至 checkSaveOut 判定止）原样搬入，
    //   doSaveAs 调用之前——返回 outBufA；各 return 'false' 改为 return null，
    //   SAVE_AS_* 打点前缀改 SAVE_CVT_*（save:send 复用时区分来源）
  }
```

`saveAsBin` 变为：

```typescript
  private saveAsBin(ctx: DocTabCtx, param: string): string {
    try {
      const out = this.convertSaveBytes(ctx, param);
      if (out === null) {
        return 'false';
      }
      // forceExt：系统保存框默认名与后缀按表定（原注释保留）
      const specA = specOf(ctx.state.ext.length > 0 ? ctx.state.ext : 'docx');
      const extA = specA !== null ? specA.saveExt : 'docx';
      this.doSaveAs(ctx, out, extA);
      return 'true';
    } catch (e) {
      this.arkLog('SAVE_AS_ERR ' + String(e));
      return 'false';
    }
  }
```

- [ ] **Step 2: doSendTemp**

```typescript
  /** 碰一碰发送（场景 C）：当前文档导出**临时副本**发出去——不弹保存框、不回写
   *  源文件、不改文件身份（'none'→'uri' 不发生）、不补 recents、不动未保存守卫
   *  （用户拍板语义：保存为临时文件去发送）。落 <cacheDir>/knock/<名>.<ext>，
   *  启动 sweepKnockFiles 清。 */
  private doSendTemp(ctx: DocTabCtx, param: string): string {
    try {
      const out = this.convertSaveBytes(ctx, param);
      if (out === null) {
        return 'false';
      }
      const srcExt = ctx.state.ext.length > 0 ? ctx.state.ext : 'docx';
      const spec = specOf(srcExt);
      const ext = spec !== null ? spec.saveExt : 'docx';
      // 发送名：当前文档名（新建未命名 → defaultDocName，与另存为默认名同源）
      let name = ctx.state.name.length > 0 ? ctx.state.name : this.defaultDocName(ext);
      const dn = name.lastIndexOf('.');
      name = (dn > 0 ? name.substring(0, dn) : name) + '.' + ext;
      name = name.replace(/[\\/]/g, '_');
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dir = aCtx.cacheDir + '/knock';
      try {
        fs.mkdirSync(dir);
      } catch (e) {
        // 已存在——正常路径
      }
      const dst = dir + '/' + name;
      if (!writeFileBuf(dst, out)) {
        this.arkLog('KNOCK_SEND_WRITE_ERR ' + dst);
        return 'false';
      }
      this.arkLog('KNOCK_SEND_FILE ' + dst + ' size=' + out.byteLength);
      return 'true';
    } catch (e) {
      this.arkLog('KNOCK_SEND_ERR ' + String(e));
      return 'false';
    }
  }
```

- [ ] **Step 3: save:bin 分叉 + 状态标志**

struct 状态区加：

```typescript
  /** 碰一碰发送在途：save:bin 上报路由到 doSendTemp（正常保存语义全部旁路）。
   *  至多一个在途——进行中再碰被 onKnockShare 拒绝 */
  private knockSendTab: DocTabCtx | null = null;
```

`save:bin` 命令处理（:361-366）在调 `saveBinRaw` 前加分叉：

```typescript
    if (cmd === 'save:bin') {
      // 碰一碰发送分叉：序列化产物路由到临时导出，不进正常保存链
      if (this.knockSendTab === ctx) {
        this.knockSendTab = null;
        const rs = this.doSendTemp(ctx, param);
        this.knockShareTarget(rs === 'true' ? this.knockPendingTarget : null);
        return rs;
      }
      const r = this.saveBinRaw(ctx, param, userFlag > 0);
      ...
    }
```

配套状态：

```typescript
  /** knockShare 回调 target（save:bin 异步回来时交还系统） */
  private knockPendingTarget: harmonyShare.SharableTarget | null = null;

  /** 序列化转换完成后交还系统（失败走 clarifyNonShare 说明） */
  private knockShareTarget(target: harmonyShare.SharableTarget | null): void {
    const t = this.knockPendingTarget;
    this.knockPendingTarget = null;
    if (t === null) {
      return;
    }
    if (target === null) {
      t.clarifyNonShare({ message: '文档导出失败，请重试' });
      return;
    }
    const ctx = this.knockSendTab;  // 已在 save:bin 分叉置 null 前取出——见下
    ...
  }
```

（实施注意：分叉处先取 `const sendCtx = ctx;` 再置 `this.knockSendTab = null`，把 `dst`/`name`/`ext` 通过 `doSendTemp` 改为返回值对象 `{ok, path, name, ext}` 传给 knockShareTarget，避免 ctx 状态竞态——**以「doSendTemp 返回结构体」为准实现**，上面分叉示意里的 rs==='true' 简化写法在实施时替换。）

- [ ] **Step 4: onKnockShare 实现**

替换 Task 3 的空壳：

```typescript
  /** 对端碰一碰 → 导出当前文档临时副本并发送（场景 C）。
   *  无文档/发送在途 → clarifyNonShare；有文档 → 触发页面序列化
   *  （window.editor.asc_Save()，页面经 save:bin 上报，分叉见 Step 3）。 */
  private onKnockShare(target: harmonyShare.SharableTarget): void {
    const ctx = this.activeDocCtx();
    if (ctx === null) {
      target.clarifyNonShare({ message: '请在打开文档的界面再试' });
      return;
    }
    if (this.knockSendTab !== null || this.knockPendingTarget !== null) {
      target.clarifyNonShare({ message: '上一次发送尚未完成，请稍候' });
      return;
    }
    this.knockSendTab = ctx;
    this.knockPendingTarget = target;
    ctx.js('(function(){try{'
      + 'if(window.editor&&window.editor.asc_Save){'
      + 'window.editor.asc_Save();console.error("KNOCK_SAVE ok");}'
      + 'else{console.error("KNOCK_SAVE nf");}}catch(e)'
      + '{console.error("KNOCK_SAVE err "+e);}})()', 'knock');
    // 序列化无响应兜底（页面异常时不吊死系统等待窗口）：10s 后交还失败
    setTimeout(() => {
      if (this.knockPendingTarget !== null) {
        this.arkLog('KNOCK_SEND_TIMEOUT');
        this.knockSendTab = null;
        this.knockShareTarget(null);
      }
    }, 10000);
  }
```

`knockShareTarget` 的成功分支（补全 Step 3 省略段）：

```typescript
    // 成功分支：按落盘产物构造 SharedData（精确 UTD + 文件 uri + 标题）
    const utdStr = utdOfExt(sendExt);
    const data = new systemShare.SharedData({
      utd: utdStr.length > 0 ? utdStr : utd.UniformDataType.PLAIN_TEXT,
      uri: fileUri.getUriFromPath(sendPath),
      title: sendName,
    });
    t.share(data).then(() => {
      this.arkLog('KNOCK_SHARE_OK ' + sendName);
    }).catch((e: Object) => {
      this.arkLog('KNOCK_SHARE_ERR ' + String(e));
    });
```

（imports 补：`import { fileUri } from '@kit.CoreFileKit'`、`import { utdOfExt } from '../common/knockShare'`；`uniformTypeDescriptor as utd` 若 EditorPage 未引入则一并加。）

- [ ] **Step 5: 编译验证**

同前。Expected: `BUILD SUCCESSFUL`。

---

### Task 5: 启动清扫挂 knock 目录

**Files:**
- Modify: `entry/src/main/ets/pages/EditorPage.ets:1491`（sweepPrintFiles 旁新增 + aboutToAppear :2064 挂调用）

- [ ] **Step 1: sweepKnockFiles**

```typescript
  /** 启动清扫：删 cache 里碰一碰收发残留（接收件被拷走后即无用；发送副本系统
   *  传输窗口短，跨进程生命周期无意义。幂等，与 sweepPrintFiles 同款兜底）。 */
  private sweepKnockFiles(): void {
    try {
      const aCtx = getContext(this) as common.UIAbilityContext;
      const dir = aCtx.cacheDir + '/knock';
      try {
        fs.rmdirSync(dir);
      } catch (e) {
        // 不存在=常态
      }
      fs.mkdirSync(dir);
      this.arkLog('KNOCK_SWEEP');
    } catch (e) {
      this.arkLog('KNOCK_SWEEP_ERR ' + String(e));
    }
  }
```

- [ ] **Step 2: 挂调用**

`aboutToAppear`（:2057 起）现有 `sweepPrintFiles()` 调用旁加 `this.sweepKnockFiles();`。

- [ ] **Step 3: 编译验证**

同前。

---

### Task 6: 文档同步 + 全量编译

**Files:**
- Modify: `docs/ONLYOFFICE_OHOS_FEATURE_MATRIX.md`（「分享」行：降级 → 已接（Share Kit 碰一碰收发），并修正「SDK 无 ShareKit」过时记录）
- Modify: `docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md`（新增碰一碰小节：注册生命周期纪律、pending 直答机制、save:bin 分叉、UTD 与 module.json5 同源维护约束）
- Modify: `docs/ONLYOFFICE_PERSISTENCE_MAP.md` 若 cache/knock 目录涉及持久化摸排口径

- [ ] **Step 1: 文档更新**（按各文件现有行文风格，注释纪律同样适用：描述最终状态）
- [ ] **Step 2: 全量编译** `assembleHap` BUILD SUCCESSFUL
- [ ] **Step 3: 提交**（分任务提交：Task1+5 / Task2+3 / Task4 / Task6 各一笔，commit message 描述动机与机制）

---

### Task 7: 真机联调（后置——用户给 1.3↔1.5 后执行，本计划不阻塞在此）

**前置：** 1.5 部署最新包（当前 1.5 上是旧版）；`hdc shell param get const.product.software.version` 记录 1.5 系统版本（PC/2in1 沙箱接收 since API 20）。

| # | 步骤 | 判据（web_console 日志 / 截图） |
|---|---|---|
| 1 | 摸底：1.3 相册选图 → 碰 1.5（PureOffice 在前台但无文档） | 华为分享系统卡片出现；PureOffice 无崩溃 |
| 2 | 场景 A：1.5 打开 docx → 1.3 相册碰 | `KNOCK_EVENT dataReceive` → `KNOCK_IMG_READY` → `KNOCK_ADDIMG ok` → `KNOCK_PICK_DIRECT` → 图片入文；截图 |
| 3 | 场景 A 回归：1.5 工具栏手动「插入图片」 | 仍弹系统 picker（`KNOCK_PICK_DIRECT` 不出现） |
| 4 | 场景 B：1.3 PureOffice 发送 docx（见 #6）→ 碰 1.5 | `KNOCK_DOC_OPEN` → 新 tab 打开、内容正确 |
| 5 | 场景 B 收 xlsx/pptx | 同上，三格式 |
| 6 | 场景 C：1.5 编辑已有 docx → 碰 1.3（PureOffice 前台） | `KNOCK_SAVE ok` → `KNOCK_SEND_FILE` → `KNOCK_SHARE_OK`；1.3 收到文件、zip 校验过、**源文件未被回写、recents 无新条目** |
| 7 | 场景 C：未保存新建文档被碰 | 自动导出临时副本发送成功；文件名=未命名.docx |
| 8 | 边界：欢迎页/无文档态被碰收图 | `KNOCK_RECV_REJECT no-doc`，系统提示 |
| 9 | 边界：发送中再碰 | `clarifyNonShare` 提示「上一次发送尚未完成」 |
| 10 | 回归：`regression.sh` 全量 | 现有 case 无回退 |
| 11 | 摸底扩展：1.3 碰 1.6 | 记录 1.6 能否碰（不阻塞） |

---

## Self-Review 记录

- **Spec 覆盖**：A=Task2+3、B=Task3、C=Task4、临时目录清扫=Task5、风险处置（reject/clarifyNonShare/发送在途防抖）=Task3/4、验证=Task7。✅ 无缺口。
- **占位符**：Task 4 Step 3/4 两处标了「实施注意」的竞态修正（doSendTemp 返回结构体）——这是有意的实施指令而非占位；其余步骤均含完整代码。⚠️ 实施时按标注落实。
- **类型一致性**：`KnockReceivable`（Task1）↔ `onKnockReceivable`/`onKnockShare`（Task3/4）签名一致；`pendingKnockImage`（Task2）↔ Task3 写入点一致；`convertSaveBytes` 返回 `ArrayBuffer | null`（Task4 Step1）与两处调用一致。✅
