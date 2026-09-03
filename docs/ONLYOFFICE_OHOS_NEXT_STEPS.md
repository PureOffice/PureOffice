# ONLYOFFICE OHOS 移植 —— 后续工作计划（2026-09-03 定稿）

> 背景：迭代 2（xlsx/pptx 打开链）已于 2026-09-03 真机闭环：
> **docx / xlsx / pptx 三格式「打开 → 渲染 → 编辑（mark）→ 保存」全部验证通过**
> （xlsx cells 渲染三连修见 docs/KEYPOINTS §10 与 memory/onlyoffice-open-chain-v12）。
> 本文档为下一步工作路线与优先级（推荐顺序 1 → 2 → 3 → 4）。

---

## 1. 固化成果（最优先，防丢）

**状态**：迭代 1+2 的全部改动都在工作区未提交（git 仅 `a759995 poc1` 一个 commit）。
rawfile/webapps/sdkjs 目录不受 git 跟踪，改动极易丢失。

**要做**：

- [ ] 整理提交（按主题分批）：
  - 打开链 v12 全部修复：`pack_web.py`（LBIN 拦截 / __oobDocy 踢闸 + wb.resize / asc_setZoom(1) / PDF 过滤 / 诊断打点）、`EditorPage.ets`（探针 cell: 字段、forcePaint zoom=1）、`rawfileLoader.ets`（wasm MIME）、`ascBridge.ets`/`x2t.ets`（转换桥）
  - 文档：README.md 更新迭代 2 状态（当前仍写"xlsx grid✅ cells 未画"的旧结论）
- [ ] README「当前任务状态」同步：迭代 2 ✅ 完成（三格式打开链）+ 三格式保存链状态（见 §2）
- [ ] KEYPOINTS §10 追加：xlsx cells 三根因与修复（PK 绕过 LBIN / 视图未重绘 / asc_setZoom factor 语义）
- [ ] 决策项（用户拍板）：**index.html 诊断打点**（odT/odS/hpX/hpC/edT/edF/PFLIM=15000/fonts 打点）留作调试通道，还是本轮瘦身
- [ ] 提交信息按工程惯例（无 co-author 尾注）

**验收**：
- 提交后可 `git stash && git log` 回放打开链进展；真机三格式截图归档进 docs/ 或 release notes

---

## 2. 补 xlsx / pptx 保存链（自然延伸，完整闭环）

**现状**：`OOHost.mark/save` 只对 docx 生效——`getModel()` 以 `WordControl` 判断，
cell（无 WordControl）恒返回 null → `OOH_MARK_NOMODEL / OOH_SAVE_NOMODEL`（探针假阴性）。

**要做**：

- [ ] `OOHost.getModel()` 按编辑器识别模型：
  - docx：`WordControl.m_oLogicDocument`（现有）
  - xlsx：`e.wbModel`（cell API 属性，已确认存在 `ws=3`）
  - pptx：`WordControl.m_oLogicDocument`（slide 同 word 结构，先验证）
- [ ] `OOHost.mark()`：`asc_AddText` 对 cell 用 `asc_setCellValue` 或等价 API（确认 cell API 的操作入口），pptx 用 `Asc.NativeTextApi` 或文本框 API（先做「仅 docx/xlsx mark」也可接受）
- [ ] `OOHost.save()` 分派：
  - xlsx → `AscCommonExcel.BinaryFileWriter(m).Write(false)` → `AscSaveBridge.save()` → ArkTS x2t `xlst_bin2xlsx` → save.xlsx
  - pptx → `BinaryPPTYWriter`（如存在；无则用 `saveDocumentToZip` 评审或降级为「导出 PPTY 原始包」实验）
  - docx 保持现状（doct_bin2docx）
- [ ] 真机验证：三格式保存产物解包验指纹（xlsx: `xl/workbook.xml`/`sharedStrings.xml` 含编辑标记；pptx: `ppt/slides/slide1.xml`）
- [ ] 探针 `OOH_SAVE_NOMODEL` 假阴性处置：改为按编辑器分派错误信息

**验收**：
- 三格式按钮路径：打开 → mark → save → 拉回产物解包 → 编辑标记在 XML 中可见
- docx 保存链行为不回归（1017 w:t 增量测试）

---

## 3. 正式化清理（小项，可与 §2 并行）

- [ ] 诊断打点瘦身：`pack_web.py` 内 POC 打点（odT/odS/hpX/hpC/edT/edF/web_console 全量落盘）→ 保留 `__pf` 骨架、`LBIN/DEOC` 可留作 release 后故障定位
- [ ] 探针 field 精简：`cell:`/`drk:`/`dom:` 等仅开发用，正式壳关闭（autoTest 开关已存在，可加 `debugProbe` 开关）
- [ ] PFLIM 15000 → 正式值（如 2000）与 `pfTail` 分段保留
- [ ] `docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md` 补齐 v12（§10 追加）

---

## 4. 迭代 3（大项，另行排期）

候选课题（按收益排序，建议逐一立项再实施）：

- [ ] **生命周期**：app 后台/前台恢复、横竖屏切换（系统 ArkWeb resize）、内存阈值监控
- [ ] **大文档阈值**：≥10MB 样本 base64 过桥压测（当前 27KB sample 无压力；定阈值与降级策略）
- [ ] **原生文件打开**：文件管理器/沙箱入口 → 打开链（现有 `OOHost.open(url)` 已可用，缺 UI 入口与沙箱间复制）
- [ ] **原生对话框**：系统级 打开/另存为/错误 对话框替换 web 内嵌
- [ ] **多实例/多标签**：暂缓（收益低）

**排期建议**：§1（当天）→ §2（1-2 天）→ §3（半天）→ §4（迭代 3 专项）。

---

## 相关文档

- `docs/ONLYOFFICE_OHOS_PORT_DESIGN.md` — 总设计
- `docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md` — 不可变决策与实测数据流（§10 迭代 2 沉淀）
- `docs/ONLYOFFICE_SAVE_CHAIN_REVISED.md` — 保存链全源码考古
- `README.md` — 任务状态速览
