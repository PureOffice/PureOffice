# ONLYOFFICE 鸿蒙回归

回归分两层，**两层都过才算通过**：

- **自动层**（本目录 `regression.sh` + `cases.tsv`）：真机跑 case 矩阵，判"链路是否还通"
- **手工层**（本文件 §3）：判"系统 UI / 渲染观感"——真机系统界面无法程序化注入，只能手指 + 目视

## 1. 自动层用法

```bash
# 全量（约 7 分钟，20 个 case；每个 case 命中终态标签即结束，不必等满超时）
OHOS_DEV=<设备ip:端口> bash scripts/onlyoffice/tests/regression.sh

# 单 case / 列清单 / 采基线（加 case 前用）
OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --case open-word
bash scripts/onlyoffice/tests/regression.sh --list
OHOS_DEV=... bash scripts/onlyoffice/tests/regression.sh --record --case <id>
```

- 输入清单：`cases.tsv`（字段说明见文件头；**加 case 改这里**）
- 产物：`out/<runid>/<id>.log`（该 case 完整日志）、`<id>.jpeg`（结束时刻截图，供人工复核）、`summary.txt`
- 退出码：0=全 PASS，1=有 FAIL，2=用法/环境错误（可直接接任何 CI/脚本）
- 前提：设备已装当前 HAP（先跑 `deploy_ohos.sh`）；脚本自己 force-stop + 拉起验收态

## 2. 覆盖与盲区

| 链路 | case | 判据本质 |
|---|---|---|
| 打开三格式 | `open-word` / `open-cell` / `open-slide` | 打开链打点 + 文档就绪快照（`PROF_SNAP`） |
| 保存三格式 | `save-word` / `save-cell` / `save-slide` | x2t 转换 + 回写源文件打点（`SAVE_BIN_X2T`/`SAVE_BIN_BACK`） |
| 字体装填 | `font-cjk` / `font-symbol` | 每个在册字体必须有 `FONT_WARM_FILLED id=<文件>`（缺流=渲染期静默回退，见 §4） |
| 字体映射 | 同上两 case | `FONT_PICK`（请求名 → 命中行）：仿宋/楷体不得被宋体截胡、Wingdings/Symbol 必落 OpenSymbol |
| 插件/AI 链 | `plug-ai-on` / `plug-ai-gated` | 「插件」tab 隐藏（`PLUG_TAB_GONE=true`）+ AI tab 自注册常驻（`PLUG_AI_TAB_EXISTS=true`，轮询采集）→ Chatbot 窗口；门控态反向断言（默认不点任何插件菜单） |
| 格式扩展 | `open-doc` / `open-xls` / `open-ppt` / `open-rtf` / `open-txt` / `open-csv`、`save-rtf` / `save-csv` / `save-doc` / `save-doc-auto` | 新格式打开链（样本名 + x2t 转换 + 各族就绪标签）+ 原地保存 + 不可原地保存格式的提示拦截（`save-doc` 反向断言 `SAVE_BIN_BACK`/`SAVE_BIN_URI` 必须不出现；`save-doc-auto` = autosave 语义 userFlag=0，断言 `SAVE_BIN_URI` 不出现而沙箱工作副本照更新——「源文件永不被异格式字节覆盖」不变量，与 userSaved 解耦） |
| 加密文档 | `open-enc-pwd` / `open-enc-badpwd` / `open-enc-nopwd`、`save-enc` | x2t 错误码分派：无密码 `0x8004135a` / 密码错 `0x8004135b` 均须弹密码框（后者 retry 文案、且**不得打开**），带密码 `rc=0x0` 且文档就绪。`save-enc` 断言密文产物过校验（`check=zip ok`，禁止 `BAD:ZIPBAD`——密文是 CFB 容器不是 zip）。**产物是否真为密文、编辑内容是否在**，自动层判不了（见 §2 盲区），须拉回文件用密码解密核对 |

**盲区（自动层判不了）**：**像素级**渲染结果（字形画出来是粗是细、布局是否错位——判据只到
"字体选中且字节在"这一层）、系统 UI 内的操作（picker/打印框/软键盘）、窗口与手势行为。→ §3。

## 3. 手工清单（自动层之外的必查项）

### 3.1 系统 UI 类（需手指；日志只能验到系统界面被调起）

| 项 | 步骤 | 看什么 |
|---|---|---|
| 打开本地文件 | 欢迎页「打开」→ 系统选择器 | 选 docx/xlsx/pptx 各一，能进编辑器；9 种支持后缀的文件可见、不支持后缀（如 exe/odt）不出现 |
| 打开方式（文件管理器） | 文件管理器长按文件 → 打开方式 | 候选列表出现 Pure Office；docx 选中直接进编辑器；odt 选中弹「暂不支持该格式：<名>」（不支持格式的唯一可达入口） |
| 另存为 / 导出 | 编辑页左下「导出」 | 系统保存框弹出、文件名带出、落盘可打开 |
| 打印 | 工具栏打印按钮（保存图标旁） | 系统打印界面弹出（无打印机＝"未发现打印机"也算通） |
| 加密文档 | 打开密码保护文档（自备样本：`enc.docx`，口令 `1234`） | 弹「文档受密码保护」框；**输错**提示「密码错误，请重新输入。」可重试；**输对**进编辑器；编辑后保存 → 拉回产物仍能用同密码打开（加密不降级为明文）。取消/蒙层关闭 = 不打开该文档 |

### 3.2 窗口 / 交互类

| 项 | 步骤 | 看什么 |
|---|---|---|
| 多 tab | 打开第二个文档 / 切 tab / 关 tab | tab 栏正确、状态（缩放/滚动）随切换保留 |
| 未保存守卫 | 编辑后关 tab 或按返回键 | 弹三按钮框；「保存」落盘、「不保存」丢弃、「取消」留在原地 |
| 返回键 | 文档页按返回 | 有未保存→守卫；无改动→回欢迎页 |
| PPT 放映全屏 | pptx 放映 → 退出 | PC 沉浸最大化 / Pad 收起 tab 条；退出后窗口状态精确还原 |
| 主题 / 语言 | 设置→主题、欢迎页语言 | 切换即时生效、重启后保留（主题默认经典浅色） |
| 新建三格式 | 欢迎页三卡片 | 空白文档干净打开（无范文残留） |
| recents | （面板已隐藏，2026-09-05 用户决策砍掉「最近使用」入口） | 暂不可测；`recents.ets` 与打开链代码保留，待持久文件位置机制恢复 |

### 3.3 目视类（判据是"画对了"）

- **字体**：`fonts-test.docx`（黑体/宋体/仿宋/楷体四段）、`fonts-sym-single.docx`（Wingdings 10 字符对照）、
  `fonts-symbol-test.docx`（Symbol/Wingdings 混合段）——打开截图逐行核对
- **CJK 回归**：任一中文文档，确认无方块、无静默变宋体
- **布局**：三格式的工具栏/菜单/右侧栏完整（cell/pptx 首开较慢，GUI 懒建）
- **格式扩展**：`sample.doc`/`sample.xls`/`sample.ppt`/`sample.rtf`/`sample.txt`/`sample.csv` 逐个打开核对渲染；
  `.doc/.xls/.ppt/.txt` 保存须弹「格式不支持保存」→ 确认后系统保存框默认名换新后缀（`.docx/.xlsx/.pptx/.docx`）

## 4. 加 case 的规矩

1. 先 `--record --case <id>` 跑一遍真实流程，**从 `out/<id>.log` 里核对标签**再写进 `cases.tsv`
   ——凭想象写标签 = 假 PASS 或假 FAIL
2. 判据优先用**链路自己打的点**（`LSO_*`/`SAVE_BIN_*`/`FONT_WARM_*`/`PLUG_*`）；确需新增探针时，
   必须做成 **smoke 门控的独立段**（范例 `desktop/src/09_fontpick.js`：仅 URL 带 `m7auto=1`
   时安装官方钩子，产品路径零行为差异）
3. 禁止项优先选"失败态标签"（`*_ERR`/`*_EMPTY`/`*_GIVEUP`）——比只断言成功标签更能抓回归
4. 超时给足（cell/pptx 首开 40-60s）；有明确终态标签的用终态做 `terminal`，能省一大截时间
5. **字体类新 case 记得断言装填**：装填清单漏字体不会报错，只会静默回退成宋体（出现过两次，
   见 `FONT_WARM_FILLED` 判据的设计意图）
