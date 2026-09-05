# OPENSOURCE 合规修改方案（ONLYOFFICE OHOS 移植）

> 目标档位：**对外分发 / 上架华为应用市场**为基准的完成态方案（自用/内测档义务
> 极小，见 §2 矩阵；本方案按最重档执行，低档自动收敛）。
> 状态：方案（2026-09-06 制定，依据本仓库实测盘点，非法律意见——执行前法务
> 复核为佳，特别是 §4 字体与 §5 边界）。

---

## 1. 现状盘点（实测，2026-09-06）

| # | 组件 | 许可 | 我方状态 |
|---|---|---|---|
| 1 | `third_party/{core,sdkjs,web-apps,desktop-apps,build_tools}` 五子模块 | AGPL-3.0（LICENSE 已核，均为 GNU AGPL v3 文本） | 基线官方 `release/v9.4.0`；**core 有 OHOS 平台适配提交、sdkjs 有 desktop 适配提交（修改版）**；web-apps/desktop-apps/build_tools 视为原样 |
| 2 | 修改痕迹：`scripts/onlyoffice/patches/core-ohos/`、core `d96b186d`、sdkjs `562fdc2` | 我方对 AGPL 代码的修改 | **必须连同修改版源码公开** |
| 3 | ascshim 注入层（`make_ascshim.py` + `src/*.js`）、`EditorPage.ets`/`ascBridge.ets`/`x2t.ets`、构建链（`build_editors_ohos.py`/`deploy_ohos.sh`/`grunt-build.sh`） | 自有代码（作者所有） | 与 AGPL 程序组合分发，按 §5 边界处理 |
| 4 | 字体 HarmonyOS Sans SC（`HarmonyOS_Sans_SC.ttf` 及 subset） | **华为字体许可**（非开源；仅限 HarmonyOS 签名应用内使用——分销另有条款需书面确认） | 随 HAP 分发 → 唯一有实际回收风险资产 |
| 5 | 字体 Noto Serif CJK（`NotoSerifCJK-SC.subset.ttf`） | **SIL OFL 1.1** | 随包分发合规（保留 OFL 声明即可；不得单独转卖字体） |
| 6 | webapps 内置 jQuery / Bootstrap 等 | MIT（随官方 webapps 打包） | 随 AGPL 主链披露即可（NOTICE 列名） |
| 7 | 本仓库 | **无 LICENSE** | 作者未定权（组合后建议 AGPL-3.0 整体授权，见 §5） |

## 2. 义务矩阵（档位判定）

| 场景 | 触发义务 | 本方案是否必做 |
|---|---|---|
| 仅自己设备自用 | 无（保留版权/许可文本为口碑项） | §3-L1 中「保留声明」部分 |
| 装到他人设备 / 免费发布 | AGPL §4 发行义务：完整源码（含修改版）随**可得**；版权/许可/非担保声明完整 | 全部必做 |
| 网络服务（B 架构 web 页面组合同样适用 §13 网络用户语义） | 网络用户**应能从应用直接获取源码**（不只是「第三方链接」——应用内提供来源是弱合规线；强合规=应用内可获取程序源码） | §3-L3 必做 |
| 商业/闭源分发 | 与 ONLYOFFICE 签商业许可（Enterprise EULA / OEM）后才可脱离 AGPL 义务；**AGPL 无自动商用回购通道** | 另一条路，不在本方案展开 |

## 3. 整改清单（按优先级；每项含交付物与验收）

### L1 仓库合规化（代码活，可立即执行）——验收：git 检查全绿
1. 根仓加 `LICENSE` = AGPL-3.0 **全文**（官方文本，非引用）；`docs/` 加 `NOTICE`：
   - 上游 ONLYOFFICE 各组件名+许可+来源 URL+`release/v9.4.0` 基线；
   - 我方修改清单（core/sdkjs 自定义 commit 摘要、patches 目录、ascshim 注入说明）；
   - 字体：Noto（OFL 声明、版权行）、HarmonyOS Sans（华为许可引用，见 §4 处置）；
   - MIT 清单（jQuery/Bootstrap 等）；**不得删改子模块内 LICENSE（保留原版权头）**。
2. 采纳动作：根 LICENSE 置于依据 §5 选定的授权模式（默认 AGPL-3.0）。

### L2 源码可得性公开（交付物型）——验收：第三方可重放
1. **公开仓库**（GitHub 等）：全仓库含子模块（子模块 URL 已指向官方 GitHub，可直接公开）；
   首次公开前把 `third_party/*` 固定为精确 commit（**已经固定**——submodule 即 pin，注意 `git submodule update --init` 会取 HEAD 已 pin 值）。
2. **patch 重放路径**：公开后任何人有 `core`/`sdkjs` 官方 v9.4.0 代码 + `patches/` + 各 custom commit 的 `git format-patch` 即可重建我方修改版——需要在仓库 docs 写明「重建步骤 + 产物 hash 对应表」（衔接 build-reproducibility：每个 HAP 版本记录 `├ upstream commit → 产出 ascshim/HAP sha256` 到 `docs/REPRO_MAP.md`）。
3. 建议 repo 内 `scripts/onlyoffice/compliance/gen_source_map.py`：一键生成「上游 commit ↔ 修改 commit ↔ 产物 hash」机器可读表（承接构建链已有的版本自动生成）。

### L3 应用内「开源许可 / 关于源码」入口（代码活）——验收：1.4 真机点开可见
1. 新建 `entry/src/main/ets/pages/AboutPage.ets`（或轻量弹窗）：许可证列表（每项：名称/版本/许可/来源链接）+ 顶部一句话去向：「本应用基于 ONLYOFFICE DesktopEditors v9.4.0（AGPL-3.0）移植；完整源码获取：<公开仓库 URL + 对应版本 tag 的源码包>」。
2. 入口：文档页右上 `U/X` 附近 or 主界面左上 logo 附近放「关于」；**或**官方 `customization.about:false`。官方已关（记忆 #68 有隐藏 logo/菜单自定义），**入口位置建议**：欢迎页左下角「设置」已藏 → 放右上 `?`/`关于` 图标（参考官方 AboutDialog）。
3. 内容数据化：`src/main/resources/rawfile/onlyoffice/LICENSE_NOTICE.json`（L1 的机器可读摘要），页面渲染消费——**避免页面硬编码，演进可持续**。

### L4 字体处置（两个决策点）——风险最高项
- **默认（推荐）**：将 `HarmonyOS Sans SC` 替换为 **思源黑体 Noto Sans SC（OFL 1.1）** 构建链子集化（与现有 NotoSerifCJK subset 管道同构——`make_cjk_subset` 已支持）；代价：字形观感微变（鸿蒙黑体→思源黑体，视觉差异很小）+ 需要回归中文字体链路（FONT_INFOS 注入、`__fonts_files` 表、渲染验证三格式）。
- **备选**：保留 HarmonyOS Sans，但执行华为字体许可书面确认（保留「场景仅限 HarmonyOS 签名应用内使用」证据链；**若仅上架华为 AppGallery 且自用签名**，多数条款场景默认可行——仍以书面确认为准）。
- 验收：替换后 docx/xlsx/pptx 中文渲染无方块（复用既有真机验证矩阵）。

### L5 版本纪律（交付物）——验收：一次发布全链可回溯
- 每次发版：打 tag `v9.4.0-ohos-<n>`；附 `REPRO_MAP.md` 行；打包时 HAP 内含 `LICENSE`/`NOTICE`→ 于 `resources/rawfile/onlyoffice/compliance/`（**随包发布**，AGPL 文本随分发物）。

### L6 上架材料清单（非代码）
- 软件著作权登记（自有代码+组合代码，建议按整体申请）；
- 隐私政策 + 用户协议（含第三方开源许可章节——指向 L3 页面）；
- 应用权限说明（picker 文件读取等）；
- 开源许可页截图（AppGallery 审核用）；
- 应用市场「开源」相关问卷：填 AGPL-3.0 + 源码地址（L2）。

## 4. 风险与待办决策点

| 决策点 | 选项 | 建议 |
|---|---|---|
| D1 目标档位 | 纯自用 / 免费分发 / 商业 | **免费分发**为基准执行本方案 |
| D2 字体 | 保留 HarmonyOS（书面确认） vs 换 Noto Sans SC | **换**（零条款风险；视觉差异小）与保留的可观（愿意书面确认华为条款则保留 + 仅限 HarmonyOS 签名场景备注） |
| D3 仓库公开位置 | GitHub（推荐）/ Gitee 镜像 | GitHub public repo + 源码包归档 |
| D4 自有代码授权 | 整体 AGPL-3.0（推荐，组合后最自洽） | AGPL-3.0 |

## 5. 边界说明（法务上要站住的话术）
- AGPL 组合作品边界：壳代码（ArkTS/ascshim/构建链）被提升为 AGPL 作品**组成部分**的可能——我方案不主张「壳不算修改」的强边界，**采用整体 AGPL-3.0 公开**（匹配 D4），避免代理争议；
- ascshim 属「运行时注入」而非源码级修改：披露一律按「修改版」处理（超集披露，无争议损失）；
- 网络服务（后续把编辑器部署到网关/服务端才触发 §13 严格责任；本现状本地 app 内注入链按 §4 发行义务处理已覆盖）。

## 6. 执行序（可分批交付）
1. **S1**：L1（LICENSE/NOTICE/许可文件）→ 提交；
2. **S2**：L3 应用内关于/开源许可入口（页面数据化）→ 1.4 真机验收；
3. **S3**：D2 字体决策 → L4（替换/确认）→ 中文渲染回归；
4. **S4**：L2/L5（公开仓库 + 源码地图 + tag 纪律）→ 一次性发布验证；
5. **S5**：L6 上架材料（按发布时间窗口）。

> 每次交付遵守 build-reproducibility 原则（脚本化、pipefail、验收断言、演练通过
> 再宣布）；本方案涉及的所有页面/资源改动均入 `scripts/onlyoffice/` 链，不手改产物。
