// ---- 0.5 CJK 字体流保供（2026-09-05 中文方块根因修复，方案 A：装填式）----
// 根因（全链实证，见 50_init 探针注释与 build_editors_ohos.py FONT_* 表）：
//   文档 run eastAsia=SimSun → GetFontSlot(EA)=SimSun → LoadFont('SimSun') →
//   g_font_infos[idx 12] 的字体文件 = fonts/HarmonyOS_Sans_SC.ttf（9.25MB）。
//   引擎「字体字节加载」只发生于渲染期按需链（FontPickerByCharacter.checkText/
//   asc_insertSymbol/watermark 等 → LoadDocumentFonts2 → CheckFontLoadStyles →
//   CFontFileLoader.LoadFontAsync）：文档首帧渲染远早于 9.25MB XHR 完成 →
//   首帧全部 renderface=null → 方块；字节到后（~15s）重绘即正常（PROF_LF
//   face=14231976 gid中=7517 实测）。日志实锤：
//     - 09_fonts 旧实现预取相对路径 'fonts/<id>' 解析到编辑页目录 → rawfile
//       miss（真机 web_console 行 35）→ WARM 恒空 → 喂字节约死未生效；
//     - LoadFontArrayBuffer/LoadFontBase64 全树零调用（LSO_FB64 桥 0 条、
//       FONT_WARM_FEED 0 条）：LoadFontAsync 在渲染链从没被调到。
// 方案 A（本次）：不改任何官方产物/链——页内主动把 HOS SC 字节取到手（XHR
//   localhost rawfile，与 30_open loadLocalFile 覆写同源），等 28MB sdk-all 的
//   checkAllFonts()(243879) 建好 AscFonts.g_font_files 后，把解码字节直接装填
//   g_fonts_streams + SetStreamIndex + Status=0（+wasm 需 CreateNativeStreamByIndex
//   转 wasm 内存，min 版 48958 定义）——此后任何 LoadFont 立即有流、FT_Open_Face
//   有效 → 首帧中文不 miss。装填点不依赖任何异步加载链（竞态免疫）。
// 兼容性：装填目标与官方 LoadFontAsync 桌面/ web 分支的流位置同构（g_fonts_streams
//   尾部 + SetStreamIndex），与后续桌面语义（LoadFontBase64 桥）互不冲突。
(function() {
  var GUID = [0xA0, 0x66, 0xD6, 0x20, 0x14, 0x96, 0x47, 0xFA, 0x95, 0x69, 0xB8, 0x50, 0xB0, 0x41, 0x49, 0x48];
  var ID = 'HarmonyOS_Sans_SC.ttf';
  var BYTES = null;   // XHR 成功后 = rawfile 字节（**仍是 pre_xor 加密态**，装填前解码）
  var filled = false;

  // —— ① 立即预取（ascshim eval 时：早于 app.js/sdk 加载与文档打开）——
  // rawfile 字体在构建时被 pre_xor_font 加密（前 32B XOR guidOdttf）——装填时还原。
  (function prefetch() {
    var urls = [
      'http://localhost/onlyoffice/fonts/' + ID,  // 绝对同源（页面 origin=http://localhost）
      '../../../../fonts/' + ID                    // 相对兜底（编辑页→onlyoffice/fonts/）
    ];
    (function tryNext(i) {
      if (i >= urls.length) { console.error('FONT_WARM_PF_GIVEUP'); return; }
      try {
        var x = new XMLHttpRequest();
        x.open('GET', urls[i], true);
        x.responseType = 'arraybuffer';
        x.onload = function() {
          if (x.status === 200 && x.response) {
            BYTES = new Uint8Array(x.response);
            console.error('FONT_WARM_BYTES len=' + BYTES.length + ' url=' + urls[i]);
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
  function xorDecode(u8) {
    var n = Math.min(32, u8.length);
    for (var i = 0; i < n; ++i) u8[i] ^= GUID[i % 16];
    return u8;
  }
  function try_fill() {
    if (filled || !BYTES) return;                 // 字节未到 → 等 prefetch 回调再试
    var F = window.AscFonts;
    if (!F) return;                               // AscFonts 未建（min 版 IIFE 时）
    if (!F.FontStream || !F.g_font_files) return; // 28MB checkAllFonts 未跑（建表+导出错后）
    var ff = null;
    for (var i = 0; i < F.g_font_files.length; ++i) {
      if (F.g_font_files[i].Id === ID) { ff = F.g_font_files[i]; break; }
    }
    if (!ff) { console.error('FONT_WARM_NOFILE gff=' + F.g_font_files.length); return; }
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
      console.error('FONT_WARM_FILLED idx=' + (streams.length - 1)
        + ' bytes=' + bytes.length + ' status=' + ff.Status);
    } catch (e) { console.error('FONT_WARM_FILL_ERR ' + String(e)); }
  }
  (function poll() {
    if (filled) return;
    try_fill();
    if (!filled) setTimeout(poll, 200);
  })();
})();
