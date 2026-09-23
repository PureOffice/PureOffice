// ============================================================================
// ohos/fonts.js —— CJK 字体流保供（原 ascshim 09_fonts 段整体迁入，2026-09-21
// fork 化阶段 2-l；注册表三表已先行并入装配产物 AllFonts.js——2-j1，本文件只
// 负责**字节供给**：预取 rawfile/systemfonts/userfonts 字体 + 等 g_font_files
// 建表后装填 g_fonts_streams）。由装配链注入编辑器 main/index.html <head>
//（不注欢迎页：欢迎页无 sdkjs 引擎，装填永不发生——预取与轮询纯空转）。
// 判据日志 FONT_WARM_*（回归 font-cjk/font-symbol/open-* case 的装填判据）。
// ============================================================================
// ---- 0.94 字体文件加载取证（仅记录，原 10_engine 段首块随段拆解挪入：字体域归
//      此）——hook XHR onload，记录 /fonts/ 请求的状态码与字节数（LSO_FONT_XHR）。
//      2026-09-05 中文渲染排查：判断 CJK 字体是否真正进入引擎（成功应为
//      status=200 len≈字体大小）。随 09_fonts 迁移时统一决策去留（纯诊断，
//      候选外置 smoke）。
(function() {
  try {
    if (!window.__lsoXhrHook) {
      window.__lsoXhrHook = true;
      var _xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__lsoU = u;
        this.addEventListener('load', function() {
          try {
            if (String(u).indexOf('/fonts/') >= 0) {
              console.error('LSO_FONT_XHR ' + String(u).split('/').pop()
                + ' status=' + this.status
                + ' len=' + (this.response ? (this.response.byteLength || this.response.length || 0) : 0));
            }
          } catch (e) {}
        }, false);
        return _xo.apply(this, arguments);
      };
    }
  } catch (e) {}
})();

// ---- 0.5 CJK 字体流保供（2026-09-05 中文方块根因修复，方案 A：装填式）----
// 根因：文档 run eastAsia=SimSun → LoadFont('SimSun') → 引擎「字体字节加载」仅发生于
//   渲染期按需链（LoadDocumentFonts2 → CFontFileLoader.LoadFontAsync）——首帧渲染远早于
//   9.25MB XHR 完成 → renderface=null 方块（字节到后重绘即正常）。旧「相对路径预取」
//   与 LoadFontAsync 两条路均证伪（rawfile miss / 渲染链从没调它）——故走装填式。
// 方案 A（本次）：不动官方产物/链——页内 XHR 取 rawfile 字节，等 checkAllFonts() 建好
//   AscFonts.g_font_files 后把解码字节直接装填 g_fonts_streams + SetStreamIndex +
//   Status=0（+wasm 转 CreateNativeStreamByIndex，min 版 48958 定义）→ 任何 LoadFont
//   立即有流 → 首帧中文不 miss。装填点不依赖异步加载链（竞态免疫）。
// 兼容性：装填目标与官方 LoadFontAsync 的流位置同构（g_fonts_streams 尾部 +
//   SetStreamIndex），与桌面语义（LoadFontBase64 桥）互不冲突。
(function() {
  var GUID = [0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA, 0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48];
  // 装填清单 = 全部 CJK 字体（2026-09-05 宋体修复：单字体→清单；ID 与构建链
  // FONT_FILES final 名一致：黑体=NotoSansCJK-SC.ttf，真宋体=NotoSerifCJK-SC.ttf）
  // + 系统字体（2026-09-07 v2：ID=设备 /system/fonts 文件名，isSys=true → 请求
  //   systemfonts/ 前缀由 rawfileLoader→NAPI native 读（ArkTS fileIo 系统路径
  //   ENOENT，native 与 wine 同权）；native 返回前已 XOR 加密态（同 pre_xor_font
  //   前 32B），本处 xorDecode 统一还原——装填链零分支。
  // + 仿宋/楷体（2026-09-11）：Fandol 两字体此前漏在本清单外，只能走引擎按需链——
  //   该链在本环境拿不到字体字节（rawfile 不在其搜路径），渲染期无流 ⇒ 缺字形
  //   回退（__fonts_ranges 的 CJK 目标=宋体行）⇒ 仿宋/楷体整 run 显示为宋体。
  //   装填缺失是**持续存在**的，与保存无关。代价=每文档页多 12.4MB 预取
  //   （参照旗黑 21MB 已装填）。
  // + 符号字体（2026-09-11）：OpenSymbol 承载 Symbol/Wingdings（引擎 libfont/map.js
  //   的 ChangeGlyphsMap 把这两个符号字体的码位映射到该字体私用区）——同样必须在
  //   装填清单内，否则渲染期无流、映射后仍取不到字形（与仿宋/楷体同一失效模式）。
  //   字体仅 204KB，装填代价可忽略。
  var IDS = ['NotoSansCJK-SC.ttf', 'NotoSerifCJK-SC.ttf',
             'FandolFang.ttf', 'FandolKai.ttf',
             'OpenSymbol.ttf',
             'HYQiHeiL3.ttf',
             'NotoSansBengaliUI-Regular.ttf',
             'NotoSansDevanagariUI-Regular.ttf'];
  var IS_SYS = {'HYQiHeiL3.ttf': 1,
                'NotoSansBengaliUI-Regular.ttf': 1,
                'NotoSansDevanagariUI-Regular.ttf': 1};
  // 用户自导入字体（2026-09-18）：URL 参数 lsofonts 同时驱动本清单——注册行由
  //   20_bridge 追加（该段早于 sdk 加载执行，本段的装填在 g_font_files 建好后轮询
  //   触发，两段时序天然错开）。元素 [file, family, weight, italic]，装填按 file
  //   名（ID 即 __fonts_files 里的文件名）。
  //   **装填是刻意的**（同随包 CJK 的方块修复动机）：保证首帧即有字形。曾一度改为
  //   "不装填、走 sdkjs 原生按需加载"，理由是"装填置 Status=0 会短路加载链、致
  //   浏览器侧 @font-face 不建立"——真机实测下拉项**依旧空白**，证实空白与
  //   @font-face 无关（字体下拉每项显示的是构建期精灵格图片，运行时字体没有格子），
  //   已回归装填。下拉名字另由 46_fontimg 画（见该段）。
  //   **用户字体并入本清单、与随包字体同批装填**：曾试过不并入（只留引擎的按需
  //   加载链），真机表现为整段中文落回宋体——按需请求晚于选字。
  var USER_IDS = {};
  try {
    var _ufm = /[?&]lsofonts=([^&]+)/.exec(window.location.search || '');
    if (_ufm) {
      var _ufa = JSON.parse(decodeURIComponent(atob(decodeURIComponent(_ufm[1]))));
      for (var _ufi = 0; _ufi < _ufa.length; ++_ufi) {
        var _uff = String(_ufa[_ufi][0] || '');
        if (_uff && IDS.indexOf(_uff) < 0) { IDS.push(_uff); USER_IDS[_uff] = 1; }
      }
      console.error('LSO_UFONT_IDS n=' + IDS.length + ' user=' + _ufa.length);
    }
  } catch (_ufe) { console.error('LSO_UFONT_IDS_ERR ' + String(_ufe)); }
  function xorDecode(u8) {
    var n = Math.min(32, u8.length);
    for (var i = 0; i < n; ++i) u8[i] ^= GUID[i % 16];
    return u8;
  }
  IDS.forEach(function(ID) {
    var BYTES = null;   // XHR 成功后 = rawfile 字节（**仍是 pre_xor 加密态**，装填前解码）
    var filled = false;

    // —— ① 立即预取（ascshim eval 时：早于 app.js/sdk 加载与文档打开）——
    // rawfile 字体在构建时被 pre_xor_font 加密（前 32B XOR guidOdttf）——装填时还原。
    (function prefetch() {
      var urls = [
        // 用户字体必须走 userfonts/：该前缀拦截层按 xor=true 返回**加密态**，与本链的
        // xorDecode 配对。取成 fonts/（浏览器明文通道）会让字体头被再异或一次而报废，
        // 且日志上毫无异常（FONT_WARM_FILLED status=0 照常打印）。
        (USER_IDS[ID] ? 'http://localhost/onlyoffice/userfonts/'
          : (IS_SYS[ID] ? 'http://localhost/onlyoffice/systemfonts/'
            : 'http://localhost/onlyoffice/fonts/')) + ID,
        '../../../../fonts/' + ID                    // 相对兜底（仅 rawfile；系统字体 miss）
      ];
      (function tryNext(i) {
        if (i >= urls.length) { console.error('FONT_WARM_PF_GIVEUP ' + ID); return; }
        try {
          var x = new XMLHttpRequest();
          x.open('GET', urls[i], true);
          x.responseType = 'arraybuffer';
          x.onload = function() {
            if (x.status === 200 && x.response) {
              BYTES = new Uint8Array(x.response);
              console.error('FONT_WARM_BYTES id=' + ID + ' len=' + BYTES.length + ' url=' + urls[i]);
              try_fill();
              return;
            }
            console.error('FONT_WARM_PF_404 ' + urls[i] + ' st=' + x.status);
            tryNext(i + 1);
          };
          x.onerror = function() { console.error('FONT_WARM_PF_ERR ' + urls[i]); tryNext(i + 1); };
          x.send(null);
        } catch (e) { console.error('FONT_WARM_PF_EXC ' + String(e)); tryNext(i + 1); }
      })(0);
    })();

    // —— ② 装填（字节+表都就绪后执行一次）——
    function try_fill() {
      if (filled || !BYTES) return;                 // 字节未到 → 等 prefetch 回调再试
      var F = window.AscFonts;
      if (!F) return;                               // AscFonts 未建（min 版 IIFE 时）
      if (!F.FontStream || !F.g_font_files) return; // 28MB checkAllFonts 未跑（建表+导出错后）
      var ff = null;
      for (var i = 0; i < F.g_font_files.length; ++i) {
        if (F.g_font_files[i].Id === ID) { ff = F.g_font_files[i]; break; }
      }
      if (!ff) { console.error('FONT_WARM_NOFILE id=' + ID + ' gff=' + F.g_font_files.length); return; }
      try {
        var bytes = xorDecode(BYTES);
        var streams = F.g_fonts_streams = F.g_fonts_streams || [];
        var s = new F.FontStream(bytes, bytes.length);
        streams.push(s);
        ff.SetStreamIndex(streams.length - 1);
        ff.Status = 0;                              // 0=loaded（CheckLoaded:=0||1）
        if (typeof F.CreateNativeStreamByIndex === 'function') {
          F.CreateNativeStreamByIndex(streams.length - 1); // wasm 语义需转 wasm 内存
        }
        filled = true;
        console.error('FONT_WARM_FILLED id=' + ID + ' idx=' + (streams.length - 1)
          + ' bytes=' + bytes.length + ' status=' + ff.Status);
        // 自检登记（多字体循环各 push 一次，读侧 indexOf 判存在，重复无害）
        (window.__lsoShim = window.__lsoShim || []).push('fonts');
      } catch (e) { console.error('FONT_WARM_FILL_ERR id=' + ID + ' ' + String(e)); }
    }
    (function poll() {
      if (filled) return;
      try_fill();
      if (!filled) setTimeout(poll, 200);
    })();
  });
})();
