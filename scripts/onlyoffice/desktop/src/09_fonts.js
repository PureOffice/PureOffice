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
  // FONT_FILES final 名一致：黑体=HarmonyOS_Sans_SC.ttf，真宋体=NotoSerifCJK-SC.ttf）
  // + 系统字体（2026-09-07 v2：ID=设备 /system/fonts 文件名，isSys=true → 请求
  //   systemfonts/ 前缀由 rawfileLoader→NAPI native 读（ArkTS fileIo 系统路径
  //   ENOENT，native 与 wine 同权）；native 返回前已 XOR 加密态（同 pre_xor_font
  //   前 32B），本处 xorDecode 统一还原——装填链零分支。
  // + 仿宋/楷体（2026-09-11）：Fandol 两字体此前漏在本清单外，只能走引擎按需链——
  //   该链在本环境拿不到字体字节（rawfile 不在其搜路径），渲染期无流 ⇒ 缺字形
  //   回退（__fonts_ranges 的 CJK 目标=宋体行）⇒ 仿宋/楷体整 run 显示为宋体。
  //   装填缺失是**持续存在**的，与保存无关。代价=每文档页多 12.4MB 预取
  //   （参照旗黑 21MB 已装填）。
  var IDS = ['HarmonyOS_Sans_SC.ttf', 'NotoSerifCJK-SC.ttf',
             'FandolFang.ttf', 'FandolKai.ttf',
             'HYQiHeiL3.ttf',
             'NotoSansBengaliUI-Regular.ttf',
             'NotoSansDevanagariUI-Regular.ttf'];
  var IS_SYS = {'HYQiHeiL3.ttf': 1,
                'NotoSansBengaliUI-Regular.ttf': 1,
                'NotoSansDevanagariUI-Regular.ttf': 1};
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
        (IS_SYS[ID] ? 'http://localhost/onlyoffice/systemfonts/' : 'http://localhost/onlyoffice/fonts/') + ID,
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
