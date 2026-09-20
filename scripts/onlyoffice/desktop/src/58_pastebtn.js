
  // ==========================================================================
  // 5.8 工具栏「粘贴」宿主桥化（Button_Paste 覆写，2026-09-21）
  // ==========================================================================
  // 背景：官方 Button_Paste（clipboard_base.js:1471）三条路在本壳全断——
  //   ① 桌面分支 asc_desktop_copypaste 需 window.AscDesktopEditor（40_save 3.7 段
  //      为字体 web 语义已删该对象，不可为粘贴恢复）
  //   ② navigator.clipboard.read() 新路径被官方开关关死（isUseNewPaste =
  //      window.TestUseNewPaste，v9.4.0 默认 undefined），且 ArkWeb 无
  //      clipboard-read 授权设施（HarmonyOS 剪贴板隐私管控走系统侧）
  //   ③ document.execCommand('paste') 被 Chromium 安全策略禁止（web 页面恒 false，
  //      ArkWeb 同源内核；官方网页版同样只有 Ctrl+V）
  //   → return false → web-apps 弹「请用键盘快捷键」提示框。软键盘没有 Ctrl+V，
  //   工具栏按钮是 Pad/手机唯一粘贴入口，故必须修。
  // 修法：覆写 Button_Paste → execCommand('clip:paste') → 宿主 @ohos.pasteboard
  //   读系统剪贴板（htmlText 优先 / plainText 兜底）→ base64 回调本段
  //   __lsoPasteIn → html 走官方 CommonIframe_PasteStart（Button_Paste_New 同款
  //   iframe 解析路径）、纯文本走 Api.asc_PasteData(Text)。
  // 两条刻意决策：
  //   - 不做 LastCopyBinary 内部缓存优先——跨应用复制后该缓存已过期，优先用会
  //     贴出旧内容；本应用复制时官方代码也同步写系统剪贴板（html 在场），
  //     系统剪贴板恒为唯一真源（官方桌面语义同为读系统剪贴板）。
  //   - Ctrl+V 的 paste 事件链（_private_onpaste）不动——本段只接管按钮。
  // 覆写点选 g_clipboardBase.Button_Paste：三编辑器（word/cell/slide）api.Paste
  //   全部收敛到它（word/api.js:2301、cell/api.js:468、slide/api.js:1835 实证），
  //   一处覆写三格式生效；IsWorking 防抖守卫在 api.Paste 里、不受覆写影响。
  // 自包含段（无入站依赖；与 51/55/57 同型位于外层 IIFE 之外）。
  (function _hookPasteBtn() {
    try {
      // 页门控：仅编辑器页（欢迎页无 AscCommon，空转无意义）
      var _pp = (window.location || {}).pathname || '';
      if (_pp.indexOf('/main/index.html') < 0) { return; }
      var _n = 0;
      function _tick() {
        _n++;
        var AC = window.AscCommon;
        if (AC && AC.g_clipboardBase && typeof AC.g_clipboardBase.Button_Paste === 'function') {
          var _cb = AC.g_clipboardBase;
          // base64 → UTF-8 string：atob 得到的是 latin1（每字符一字节），中文
          // UTF-8 多字节必须经 TextDecoder 还原（直接 atob 会乱码）。
          function _b64s(b64) {
            if (!b64) { return ''; }
            try {
              var _bin = window.atob(b64);
              var _u8 = new Uint8Array(_bin.length);
              for (var i = 0; i < _bin.length; i++) { _u8[i] = _bin.charCodeAt(i); }
              return new TextDecoder('utf-8').decode(_u8);
            } catch (dx) { return ''; }
          }
          // 宿主回传入口（EditorPage pasteClipboard → ctx.js 调用）
          window.__lsoPasteIn = function (b64Html, b64Text) {
            try {
              var _html = _b64s(b64Html);
              var _text = _b64s(b64Text);
              console.error('LSO_PASTE_IN html=' + _html.length + ' text=' + _text.length);
              if (_html) {
                _cb.CommonIframe_PasteStart(_html, _text || '');
              } else if (_text) {
                _cb.Api.asc_PasteData(AscCommon.c_oAscClipboardDataFormat.Text, _text);
              } else {
                // 空剪贴板：状态栏短提示（40_save 保存提示同款句柄与用法）
                var _sb = (window.SSE || window.DE || window.PE);
                _sb = _sb && _sb.controllers && _sb.controllers.Statusbar;
                if (_sb && typeof _sb.setStatusCaption === 'function') {
                  _sb.setStatusCaption('剪贴板为空', true, 0);
                }
              }
            } catch (ex) { console.error('LSO_PASTE_IN_ERR ' + String(ex)); }
          };
          _cb.Button_Paste = function () {
            try {
              if (window.AscNative && typeof window.AscNative._call === 'function') {
                console.error('LSO_PASTE_BTN');
                window.AscNative._call('execCommand', ['clip:paste']);
                // 已受理（结果异步回调 __lsoPasteIn）——返回 true 不弹官方
                // 「请用键盘快捷键」提示框
                return true;
              }
              console.error('LSO_PASTE_NO_NATIVE');
            } catch (ex) { console.error('LSO_PASTE_BTN_ERR ' + String(ex)); }
            // 桥不在（异常态）：回落官方原路径（execCommand+提示框兜底）
            return false;
          };
          console.error('LSO_PASTE_HOOKED');
          (window.__lsoShim = window.__lsoShim || []).push('pastebtn');
          return;
        }
        if (_n < 300) { setTimeout(_tick, 200); } else { console.error('LSO_PASTE_GIVEUP'); }
      }
      setTimeout(_tick, 500);
    } catch (e) { console.error('LSO_PASTE_HOOK_ERR ' + String(e)); }
  })();
