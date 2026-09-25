# 加密文档打开：调研与实测（2026-09-12）

> 目标：用户收到带密码的 Office 文档（同事发来的加密 docx 等）能否在本应用打开。
> 结论：**引擎侧完全就绪，缺口全在壳层接线**——已在真机（1.6 = MatePad 11.5 S）
> 完成「密文打开 → 编辑 → 保存仍为密文」闭环实测。

## 一、引擎侧事实（core/x2t 无需任何改动）

| # | 事实 | 证据 |
|---|---|---|
| 1 | 密文识别走 CFB 容器探测：存在 `EncryptionInfo` 流 → `MS_OFFCRYPTO` | `Common/OfficeFileFormatChecker2.cpp:642-668`（判据 `:651`）、`:749-752` |
| 2 | 解密实现：`ECMACryptFile::DecryptOfficeFile(in, out, password, bDataIntegrity)` | `OfficeCryptReader/source/ECMACryptFile.cpp:881` |
| 3 | 支持 Agile（AES-CBC + SHA-1/256/512，keyBits/spinCount 任意）与 Standard（RC4/AES-128/192/256）；**Extensible 不支持**（解析函数直接 `return false`） | `ECMACryptFile.cpp:928-957`（版本分派）、`:679-682`（Extensible） |
| 4 | **打开链自带密文回退**：`docx2doct_bin` 解压失败 → 探测 → `mscrypt2oot_bin`（xlsx/pptx 同构） | `X2tConverter/src/lib/docx.h:52-58`、`xlsx.h:57-87`、`pptx.h:51-60` |
| 5 | 密码载体 = 转换参数 `m_sPassword`（XML 解析）→ `getPassword()` | `cextracttools.h:796-804`；消费点 `lib/crypt.h:60` |
| 6 | **保存链自带加密输出**：`doct_bin2docx` → `dir2zipMscrypt`，`hasSavePassword()` 时 zip 后再 `oox2mscrypt` | `lib/docx.h:149` + `lib/common.h:206-225`；密码参数 `m_sSavePassword`（`cextracttools.h:801-804`） |
| 7 | 旧二进制格式（.doc/.xls/.ppt）密码透传点齐全（XOR/RC4/AES） | `lib/doc.h:55/87/109`、`lib/xls.h:49/72`、`lib/ppt.h:49/73` |
| 8 | 上述代码**已编入随包 .so** | `entry/src/main/cpp/CMakeLists.txt:44-47` 链接 `libooxml_crypt.a`；`nm` 命中 `DecryptOfficeFile`/`EncryptOfficeFile`/`mscrypt2oot_bin`/`CryptoPP::*`(5857 个) |

## 二、错误码（UI 判据，已实测）

| 常量 | 值 | 含义 |
|---|---|---|
| `AVS_FILEUTILS_ERROR_CONVERT_DRM` | `0x8004135a` | **未提供密码**（密文文档） |
| `AVS_FILEUTILS_ERROR_CONVERT_PASSWORD` | `0x8004135b` | **密码错误** |
| `AVS_FILEUTILS_ERROR_CONVERT_DRM_UNSUPPORTED` | `0x80041355` | 不支持的加密类型 |

定义 `Common/OfficeFileErrorDescription.h:239-245`；映射 `lib/common.h:115-130`；
密文分支返回点 `lib/crypt.h:66-72`（`password.empty()` 区分两码）。

## 三、真机实测矩阵（2026-09-12，1.6 MatePad 11.5 S）

样本：`scripts/onlyoffice/smoke/samples/enc.{docx,xlsx,pptx}`（msoffcrypto 由 sample.* 生成，
ECMA-376 Agile / AES-256 / SHA-512 / spinCount 100000，口令 `1234`）。

| 场景 | 命令（m7args） | 实测结果 |
|---|---|---|
| 无密码 | `m7file=enc.docx` | `OPEN_X2T rc=0x8004135a`（需要密码） |
| 密码错 | `m7file=enc.docx;m7pwd=wrong` | `OPEN_X2T rc=0x8004135b`（密码错） |
| 带密码 docx | `m7file=enc.docx;m7pwd=1234` | `rc=0x0` + `M7AUTO_DOC_READY` |
| 带密码 xlsx | `m7file=enc.xlsx;m7pwd=1234` | `rc=0x0` + `M7AUTO_DOC_READY` |
| 带密码 pptx | `m7file=enc.pptx;m7pwd=1234` | `rc=0x0` + `M7AUTO_DOC_READY` |
| 保存（不传密码） | `…;m7auto=1` | 产物 `check=zip ok`，但 `file` 判定 = **明文 zip**（密文被静默降级） |
| 保存（传 `m_sSavePassword`） | 同上 | 产物 `CDFV2 Encrypted`；第三方实现 msoffcrypto 用 `1234` 校验通过并解出 20 部件，正文含编辑标记 `M7AUTO-EDIT-OK` |
| **保存产物再打开**（round-trip） | 把上一步产物当样本部署后 `m7file=enc.docx;m7pwd=1234` | `rc=0x0` + `M7AUTO_DOC_READY`（37888 字节产物，同密码可重新打开） |
| **产品路径弹框输入** | 无 `m7pwd` 打开 → 弹框手输 1234 → 确定 | `OPEN_PWD_SUBMIT len=4` → `rc=0x0` → `P1B_OPEN_TAB` → `LSO_OPEN_DOCUMENT_OK` |
| **编辑经保存进入产物** | 打开后输入文本 → 工具栏保存 | 产物解密后正文含该文本（`ENC-EDIT-OK`） |
| **另存为保持加密** | 打开密文 → 文件菜单「另存为」 | `SAVE_AS_X2T rc=0x0` + `check=zip ok`；沙箱 `saveas-out.docx` = `CDFV2 Encrypted`，同密码解出 20 部件 |
| **取消密码框** | 弹框点「取消」 | `OPEN_PWD_CANCEL` → 弹框关闭、回欢迎页、**无** `LSO_OPEN_DOCUMENT_OK`；随后重新打开正常 |

即：**打开密文 → 编辑 → 保存（仍加密）→ 再次打开**全链闭环成立；
保存产物的加密参数为 x2t 固定的 Agile 档（AES-256 + SHA-512，spinCount 100000），
不沿用原文件的加密参数（原文件若为较弱的 Standard/RC4，保存后即被升级为该档）。

结论：**打开只需把密码填进 `m_sPassword`，保存只需填 `m_sSavePassword`**——
两个方向的引擎能力都已具备且产出标准格式（第三方工具可解，非私有格式）。

## 四、缺口与处置（全在壳层；2026-09-12 已实现）

| # | 缺口 | 处置 |
|---|---|---|
| 1 | 打开链无重试回路（转换失败即 `return 'false'`） | 转换抽成 `attempt(pwd)` 闭包、收尾拆出 `finishOpenTab`——密码交互可异步重转（临时文件已落盘，重转不重读源文件） |
| 2 | 错误码未区分 | 按码分派：`0x8004135a` 首弹密码框 / `0x8004135b` 弹重试框（"密码错误"）/ `0x80041355` 明确告知不支持该加密方式 |
| 3 | 密码无处存放 | `DocTabState.pwd`（per-tab）；打开成功即写入，保存链复用 |
| 4 | 产物校验会拦密文（实测 `BAD:ZIPBAD`） | `checkSaveOut` 前置放行 CFB 容器头（`isEncryptedContainer`） |
| 5 | 无密码输入 UI | 自绘覆盖层（与未保存守卫框同款——CustomDialog 真机点击失效、AlertDialog 无取消键的既有教训），`TextInput(type: Password)` + 回车提交 |

## 五、方案

### 5.1 打开链
```
x2t 失败
  ├─ rc = 0x8004135a  → 首次需要密码
  ├─ rc = 0x8004135b  → 上次密码错（提示「密码错误，请重试」）
  └─ rc = 0x80041355  → 不支持的加密类型（明确报错，不给重试）
        ↓ 弹密码框 → 密码拼进 <m_sPassword> → 重跑同一次转换（inP 已落盘，无需重读源文件）
        ↓ 成功后 ctx.state.pwd = 密码（供保存链）
```
打开链重入点：`EditorPage.openNewTabEntry` 内 x2t 调用处包一层循环即可（临时文件与
目标路径不变）。

### 5.2 保存链
- 保存/另存为时若 `ctx.state.pwd` 非空 → XML 加 `<m_sSavePassword>` → 产物保持加密。
- `checkSaveOut` 前置放行 CFB 头（`isEncryptedContainer`）。
- **必须做**：实测证明不做则「编辑一次 → 明文落盘」，属静默安全降级。

### 5.3 密码输入 UI：两个选项

| | A. 官方 JS 密码框 | B. ArkTS 原生密码框（推荐） |
|---|---|---|
| 载体 | `Common.Views.OpenDialog` 的 DRM 模式（`OpenDialog.js:77-90`）+ `asc_CDRMAdvancedOptions` | ArkTS `CustomDialog` + `TextInput(type: Password)` |
| 触发 | 页面发 `asc_onAdvancedOptions(DRM)` 事件（`Main.js:3002-3026` 收） | 打开失败处直接弹 |
| 回传 | `asc_setAdvancedOptions` → 桥 `SetAdvancedOptions("<m_sPassword>…")` | 直接拿到密码，不过桥 |
| 障碍 | ① 运行时未加载 `sdkjs/*/Local/api.js`，`EncryptionWorker.asc_setAdvancedOptions` 在 `isNeedCrypt()===false` 时直接 `return false`（`editorscommon.js:12766-12777`）→ 需在平台模块（`scripts/onlyoffice/ohos/`）自接；② 需实现 `SetAdvancedOptions` 桥（现返回 `'false'`，`ascBridge.ets:263-265`）；③ 事件源要自己造 | 无 |
| 观感 | 与官方 UI 一致 | 系统风格 |
| 成本 | 中（3 个接线点 + 重入） | 低（1 个 dialog + 重入） |

推荐 **B**：链路最短、失败态可控；A 的一致性收益不值三点接线与引擎状态机耦合。
**已按 B 实现**（`EditorPage` 的 `showPwdDialog`/`pwdDialogAction` + build 内覆盖层）。

### 5.4 附带（可选，非必须）
- 标题栏锁图标：`DocInfo.put_Encrypted(true)` 或 `asc_onDocumentPassword(true)`
  （消费点 `Header.js:329-336` / `view/Protection.js:359-377`）。
- 注意**不要**改 `CryptoMode` 返回值去点亮它——那会连带激活私有门户加密插件链
  （`EncryptionWorker.isNeedCrypt()`），副作用大。

## 六、未验证与风险

| 项 | 说明 |
|---|---|
| 旧二进制 .doc/.xls/.ppt 密文 | 代码路径有密码透传（`lib/doc.h`/`xls.h`/`ppt.h`），但**造不出样本**（msoffcrypto 只支持 OOXML）→ 未实测 |
| Extensible Encryption | core 明确不支持（`ECMACryptFile.cpp:679-682`）；只做了「暂不支持该加密方式」提示（`0x80041355`），无样本验证 |
| `setup.bin`/宏等其它密文变体 | 未覆盖 |
| 密码错误次数/锁定 | 官方无此语义，不做 |
| 大文档解密耗时 | `x2tConvertSync` 在 UI 线程同步执行（既有约束，非本次引入） |

## 七、工作量

| 项 | 量级 |
|---|---|
| 打开链重入 + 错误码分派 + ArkTS 密码框 | 核心，半天内 |
| 保存链 `m_sSavePassword` + 产物校验放行 | 已实测验证（本次） |
| 回归 case（`open-enc-*`/`save-enc-*`，样本已入库） | 小 |
| 手工清单（系统 picker 打开加密文件、错误密码重试观感） | 小 |

## 八、附：验收参数与产品路径的关系

`m7pwd`（`Smoke.pwd`）是**验收态**给首轮密码的通道：非空时打开链直接用它转换，
跳过弹框——回归用例靠它覆盖"带密码打开/密码错"两条链（`cases.tsv` 的 `open-enc-*`），
无需人手输入。产品路径 `m7pwd` 恒为空，走弹框收取密码；两条路径最终都汇到同一个
`attempt(pwd)` 转换函数与同一份 `ctx.state.pwd`，差别只在密码来源。

## 九、回归

改动后全量回归 **29/29 PASS**（2026-09-12 23:25 全量 + 单 case 重跑）。
`img-undo-ppt` 首轮超时失败（该 case 日志仅 29 行、停在欢迎页、全无打开链标签
= app 中途重启致 `web_console.txt` 被 TRUNC），单 case 重跑 15s PASS——**偶发**，
与本次改动无交集（密码为空的路径上 XML 逐字节不变，CFB 放行对明文产物不触发）。
