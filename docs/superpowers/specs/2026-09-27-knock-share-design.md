# 碰一碰传送（Share Kit）接入设计

日期：2026-09-27
状态：已实现并真机闭环（docx/xlsx 实测；pptx 同构）。实现期形成的最终机制
（注册拆分跟随文档、发送 utd 固定 general.file、无文档收发路由等）与本文
设计有差异，正本见 docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md §17.7。

## 1. 目标（用户拍板的三场景）

| # | 角色 | 场景 | 接收后动作 |
|---|---|---|---|
| A | 接收端 | 对端为**任意 app**（华为分享碰一碰推图片），我们声明图片接收能力 | **立即插入当前文档** |
| B | 接收端 | 对端为 **Pure Office**（发送当前文档），我们声明文档格式接收能力 | **立即打开**（新 tab） |
| C | 发送端 | 本机把当前文档**保存为临时文件发送**（不弹保存 UI、不回写源文件、不进 recents） | — |

## 2. 技术基座（已核实）

- SDK 含 `@kit.ShareKit`（`@hms.collaboration.harmonyShare` + `systemShare`）；**无需任何权限声明**。
- 发送侧 `harmonyShare.on('knockShare', cb)`（since 12；多窗口版 since 20）→ 回调 `SharableTarget.share(SharedData)`。
- 接收侧 `harmonyShare.on('dataReceive', RecvCapabilityRegistry, cb)`（PC/2in1 since 20，**Tablet since 23**）→
  回调 `ReceivableTarget.receive(dir, {onDataReceived, onResult})`；沙箱接收仅支持文件类型。
- 版本门槛：项目 target API 23 ✅；1.6 实测系统 7.0.0.107 / API 26，华为分享服务与 NFC 栈进程在运行。
- **可碰配对：1.3（phone）↔ 1.5（PC/2in1）已确认可用**——验证主力配对；1.6（tablet）能否碰未确认，不阻塞。
- 生命周期纪律：`onPageShow` 注册 / `onPageHide` **必须解除**（官方样例明确，后台持注册是错误态）。
- 兜底语义：对端发来的类型与注册能力不匹配 → 系统走华为分享默认接收（落系统目录），**不是错误**；
  数量超限 → 系统弹窗。我们只声明能力，不处理不匹配。

## 3. 架构：一个注册层 + 三条复用链

```
EditorPage（编辑器页，页面级生命周期）
  ├─ onPageShow:  harmonyShare.on('knockShare')      ← 场景 C
  │               harmonyShare.on('dataReceive')      ← 场景 A/B（windowId=主窗口，注册一次）
  ├─ onPageHide:  对应 off(...)
  └─ 收发落点（宿主 ArkTS）──execCommand──▶ 40_save.js 注入项（页面侧）──▶ 引擎 API
```

新增宿主模块 `common/knockShare.ets`：注册/解除、能力表、接收目录管理、探针打点。
页面侧复用 `40_save.js` 的 `AscNative.execCommand` 反向通道，新增两个命令：
`knock:insertImage`（路径）与 `knock:acceptDoc`（不需要——见 4.2，场景 B 纯宿主侧闭环）。

## 4. 场景设计

### 4.1 场景 A：接收图片 → 插入当前文档

复用已闭环的插图链（引擎发起 onShowFileSelector → 宿主应答），宿主只是把
「picker 选图」换成「直答碰一碰收到的文件」，三格式（word/cell/slide）行为天然一致：

1. 宿主 `onDataReceived` → 图片写入**当前活跃 tab** 的 `tabDir()`（与 PICKFILE_OK 同落点，同命名冲突策略）。
2. `pendingKnockImage` 记在**该 tab 的 ctx 上**（每 tab 独立 Web 上下文，FileSelector 请求自带 ctx，
   挂页面级状态会串 tab）；随后对该 tab 的 Web `execCommand('knock:insertImage')` → 页面侧调
   `api.asc_addImage()`（等价于用户点工具栏「插入图片」）。
3. 该 tab 的引擎发起 `onShowFileSelector` → 宿主发现该 ctx 的 `pendingKnockImage` 非空 → **跳过 picker**，
   `result.handleFileList([dst])` → 引擎 `_uploadCallback` 落图（后半段与现有链完全同路）。
4. `pendingKnockImage` 用后即清；onShowFileSelector 先到而 pending 为空 → 正常走 picker（无串扰）。
   收图后用户切 tab 再切回 → execCommand 已对收图时的活跃 tab 发出，插入落在原 tab（符合"当前文档"语义）。

边界：**无活跃文档 tab 时收到图片** → `ReceivableTarget.reject(NO_RECEIVABLE_ERROR)`
（诚实拒绝，系统侧向发送端提示；不做"收到暂存"——引入待插队列属于未验证场景，先记录不做）。

### 4.2 场景 B：接收 Pure Office 文档 → 立即打开

纯宿主侧闭环，不经过页面：

1. `capabilities` 中声明 9 种格式 UTD（逐条精确枚举，复用 `module.json5` 打开方式注册的实测值，
   不用通配——与上架审核口径一致）+ `general.image`（场景 A）。
2. `onDataReceived` → 文件记录里的 uri → `handleLocalUri(uri)`（现有打开链入口）→ 新 tab 打开，
   recents/身份链自动走通。
3. 接收落点用系统给的临时目录（`receive()` 参数），由打开链负责拷进 tab 工作目录；临时目录随启动 sweep 清理。

### 4.3 场景 C：发送当前文档（临时文件）

1. `knockShare` 回调 → 取当前活跃 tab；无活跃 tab → `clarifyNonShare`（API 22+）说明无可分享内容。
2. 序列化 + x2t 转换与保存链同路，落盘改为**固定临时路径** `<cache>/knock/<文件名>.<ext>`：
   - 复用 `doSaveAs(ctx, outBuf, ext)` 的转换内核，新增不弹 picker 的分支（如 `doSendTemp`）；
   - **不回写源文件、不改文件身份（'none'→'uri' 不发生）、不补 recents、不动 isNewUnsaved**。
   - 未保存的新建文档被碰 = 直接导出临时副本发送（用户拍板，无交互）。
3. `new systemShare.SharedData({ utd: <按后缀的精确 UTD>, uri: fileUri.getUriFromPath(临时文件),
   title: <文件名> })` → `sharableTarget.share(data)`。
4. 临时文件发送完成后保留（对端可能在传输窗口内重试），随启动 sweep 清理；
   发送期间禁用重复触发（进行中再碰 → 新回调直接 `clarifyNonShare`）。

MVP 不带卡片缩略图（thumbnailUri 缺省由系统出文件默认卡片）；效果不满意再补，不在本期。

## 5. 决策记录

| 决策 | 取值 | 理由 |
|---|---|---|
| 插图通路 | 复用 onShowFileSelector 应答（pending 直答） | 三格式统一、改动面最小、后半段已真机闭环；直调引擎落图 API（cell `asc_addImageDrawingObject` 等）作为备选不采用——各格式入口不统一 |
| 接收文档动作 | 立即打开（新 tab） | 用户拍板 |
| 未保存文档被碰 | 自动导出临时副本 | 用户拍板（"保存为临时文件去发送"） |
| 无文档时收图 | reject | 诚实拒绝优于静默丢弃；待插队列是未验证场景（最小复杂度原则） |
| UTD 声明 | 精确枚举复用 module.json5 | 上架审核口径："声明宽于能力"会被打回的前科 |
| 缩略图 | MVP 不做 | 卡片模板有系统默认；优先验证传输链 |

## 6. 风险与前置验证

| 风险 | 等级 | 处置 |
|---|---|---|
| NFC 硬件 | 已消解 | 1.3↔1.5 可碰（用户实测）；验证主力配对即此二台。1.6 能否碰顺带摸底，无响应不影响本设计成立 |
| utd 归一匹配（发 jpeg 收 general.image 是否命中） | 中 | 真机验证；不命中时接收声明改为子类型逐条枚举 |
| `asc_addImage` 模拟点击的时序（编辑态 vs 选态） | 中 | 真机验证插入结果；异常时降级为 toast 提示手动粘贴（不阻塞场景 B/C） |
| 双真机物理碰撞无法自动化 | 固有 | 验收靠手指；探针打点（KNOCK_REG/KNOCK_RECV/KNOCK_INSERT_OK/KNOCK_SEND_*）进 web_console 日志链供取证 |

## 7. 验证方案（真机 1.3 发送端 + 1.6 接收端）

1. 摸底（前置）：系统应用场景碰一碰可用性。
2. 场景 A：手机相册碰 1.6（Pure Office 在编辑 docx）→ 图片入文；编辑 xlsx / pptx 各一遍；无文档时 → 拒绝提示。
3. 场景 B：1.3 上 Pure Office 发 docx → 1.6 新 tab 打开、内容正确；xlsx/pptx 同。
4. 场景 C：1.6 编辑已有文档/未保存新建各一遍 → 碰 1.3 接收 → 文件完整可打开（zip 校验）；
   确认源文件未被回写、recents 无新条目。
5. 回归：现有三格式打开/保存/插图链不回退（onShowFileSelector 新增 pending 分支的旁路验证：
   正常工具栏插图仍走 picker）。

## 8. 不做（本期）

隔空传送（gesturesShare）、系统分享面板入口（startSystemSharing）、卡片缩略图、
接收暂存队列、发送进度 UI（系统承担）。
