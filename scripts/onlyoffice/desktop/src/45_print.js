  // ---- 3.8.5 打印链（2026-09-10）：官方 asc_Print → 元文件流 → x2t bin2pdf → 系统打印 ----
  //      官方桌面语义：引擎 asc_Print → 逐页把绘图指令（元文件流）交壳层原生侧落地。
  //      本壳的落地方式 = asc_nativeGetPDF（引擎内置 CDocumentRenderer，产出**多页
  //      拼接的元文件指令流**——注意不是 PDF 文件格式）+ x2t 的 bin2pdf 转换
  //      （纯 C++ 的 NSOnlineOfficeBinToPdf，**不依赖 doctrenderer/V8**）+ 系统打印
  //      （@ohos.print，ArkTS 侧 printBin）。
  //
  //      入口（三处全部汇入本覆写点）：工具栏打印按钮 / 文件菜单「打印」（→ 30_open
  //      置 canPreviewPrint=false 后 word/slide 直通 asc_Print，cell 经打印面板）。
  //      ArkTS 侧只认「元文件流」这一件事，不关心它从哪个入口来。
  //
  //      截断（关键）：CMemory 构造即预分配 5MB（sdkjs common/Drawings/Metafile.js
  //      532-545），asc_nativeGetPDF 返回的是**整块预分配数组**（尾部全 0），而 C++
  //      侧 bin2pdf 的解析器是 `while (oReader.Check())` 读到 buffer 末尾——零字节会
  //      落进 default 分支且游标不前进 → 死循环。官方 CEF 靠引擎在返回前调
  //      window.native.Save_End(header, len) 报告真实长度再截断（doctrenderer.cpp:
  //      459 同款语义），此处照做：调用期临时挂桩捕获 len，finally 还原（同 3.8.4
  //      的 __lsoNativeSaveEnd——但那个桩不回报长度，故打印链单独一份）。
  (function _hookPrint() {
    try {
      // 页门控：仅编辑器页（欢迎页无 Asc 对象）
      var _pp = (window.location || {}).pathname || '';
      if (_pp.indexOf('/main/index.html') < 0) { return; }
      if (!window.Asc || !(window.Asc.asc_docs_api || window.Asc.spreadsheet_api || window.Asc.presentation_api)) {
        if ((window.__lsoPrintWaitN = (window.__lsoPrintWaitN || 0) + 1) < 300) setTimeout(_hookPrint, 200);
        return;
      }
      var _proto = (window.Asc.asc_docs_api || window.Asc.spreadsheet_api || window.Asc.presentation_api).prototype;
      // 两个前置都在才可挂钩：asc_Print（覆写对象）+ asc_nativeGetPDF（word 内置
      // CDocumentRenderer；cell/slide 各自 api.js 同款实现）
      if (typeof _proto.asc_Print !== 'function' || typeof _proto.asc_nativeGetPDF !== 'function') {
        if ((window.__lsoPrintWaitN = (window.__lsoPrintWaitN || 0) + 1) < 300) setTimeout(_hookPrint, 200);
        return;
      }

      _proto.asc_Print = function(options) {
        try {
          // 取元文件流：临时挂 Save_End 桩捕获真实长度（参数 2；参数 1 是 header 不用）
          var _len = 0;
          var _oldNative = window.native;
          var _bin = null;
          window.native = { Save_End: function(header, l) { _len = l || 0; } };
          try {
            _bin = this.asc_nativeGetPDF(options);
          } finally {
            window.native = _oldNative;
          }
          if (!_bin || !_bin.byteLength) {
            console.error('LSO_PRINT_EMPTY');
            return;
          }
          // 截断到引擎报告的长度；len 异常（0 或超界）时退回全长——ArkTS 侧有兜底
          var _n = (_len > 0 && _len <= _bin.byteLength) ? _len : _bin.byteLength;
          var _cut = _bin.subarray(0, _n);   // subarray 零拷贝（后续只读）
          var _b64 = window.__lsoB64(_cut);
          var _ret = String(window.AscNative && window.AscNative._call(
            'execCommand', ['print:bin', _b64]) || '');
          console.error('LSO_PRINT_CALL len=' + _n + '/' + _bin.byteLength
            + ' b64=' + _b64.length + ' ret=' + _ret);
        } catch (e) {
          console.error('LSO_PRINT_HOOK_ERR ' + String(e));
        }
      };
      console.error('LSO_PRINT_HOOKED');
    } catch (cbx) { console.error('LSO_PRINT_HOOK_HOOK_ERR ' + String(cbx)); }
  })();

  // ---- 打印面板打印机列表注入（2026-09-10）----
  // 官方语义（common/lib/controller/Desktop.js:46 + 204-221）：壳层发 printer:config
  // 事件 → webapp.getController('Print').setPrintersInfo(current, printers) 填面板下拉。
  // 该段写在官方 index.html 的 if(!!native) 内，而编辑器页 native 已被 40_save.js 清掉
  // → 下拉恒空 → 官方 onPrinterSelected 的 btnsPrint.forEach(btn=>btn.setDisabled(!record))
  // 使 cell 打印面板的「打印」按钮恒灰（word/slide 直通 asc_Print，不经面板，故只有
  // cell 受影响）。我们作为壳层补发这份配置：HarmonyOS 上打印统一由系统对话框呈现
  // （@ohos.print），无法枚举具体型号，故只报一项「系统打印」占位——选中即解禁按钮，
  // 点击仍汇入上面的 asc_Print 覆写 → 系统打印框。webapp 取值与官方同源
  // （Desktop.js:46 window.DE||PE||SSE||PDFE||VE）。
  (function _hookPrinterConfig() {
    try {
      var _pp = (window.location || {}).pathname || '';
      if (_pp.indexOf('/main/index.html') < 0) { return; }
      var NAME = '系统打印';
      var _n = 0;
      function _tick() {
        _n++;
        var app = null;
        try { app = window.DE || window.PE || window.SSE || window.PDFE || window.VE || null; } catch (e1) { app = null; }
        var ctrl = null;
        try { ctrl = (app && app.getController) ? app.getController('Print') : null; } catch (e2) { ctrl = null; }
        // printSettings 视图在 controller.onPostLoadComplete（script:loaded 后）才建
        var view = ctrl ? ctrl.printSettings : null;
        if (ctrl && view && !view.__lsoPrinterHooked) {
          view.__lsoPrinterHooked = true;
          try {
            // 挂面板 show：此刻 printSettings.isVisible() 才为真，setPrintersInfo 内的
            // updateCmbPrinter 分支才会执行（否则只更新 _state，下拉不会刷新）
            view.on('show', function () {
              try {
                ctrl.setPrintersInfo(NAME, [{
                  name: NAME,
                  color_supported: true,
                  duplex_supported: true,
                  paper_supported: null
                }], false);
                console.error('LSO_PRINTER_INJECTED');
              } catch (e3) { console.error('LSO_PRINTER_INJECT_ERR ' + String(e3)); }
            });
            console.error('LSO_PRINTER_HOOKED');
          } catch (e4) { console.error('LSO_PRINTER_HOOK_ERR ' + String(e4)); }
          return;
        }
        if (_n < 600) { setTimeout(_tick, 200); } else { console.error('LSO_PRINTER_GIVEUP'); }
      }
      setTimeout(_tick, 1000);
    } catch (cbx) { console.error('LSO_PRINTER_CONFIG_HOOK_ERR ' + String(cbx)); }
  })();

  // ---- 快速打印入口修复（2026-09-10）----
  // 现象：Header 的「快速打印」按钮点击**无任何反应**（真机实证）。
  // 链路：Header.js:943 createTitleButton('#slot-hbtn-print-quick') → fireEvent
  //   'print-quick'（Header.js:471）→ controller/Toolbar.js 的 Header 监听 →
  //   Main.onPrintQuick()。
  // 根因：官方 onPrintQuick 首行 `if (!this.appOptions.canQuickPrint) return;`
  //   （documenteditor Main.js:3165），而 30_open 置 canQuickPrint=false
  //   （系统打印框必弹，"静默快速打印"语义不成立）。**按钮本身不会因此消失**——
  //   它的显隐由壳层 titlebuttons.quickprint.visible 经 webapps:features 事件控制
  //   （Desktop.js:318-329，整段在 if(!!native) 内），本壳无该通路 → 按钮照常显示
  //   → 点击正好落进那条 return，表现为「死按钮」。
  // 修法：覆写 onPrintQuick 直达 asc_Print（其语义本就是"不预览直接打印"）。官方
  //   那层 Common.UI.warning 确认框（文案"将使用上次选择的打印机"）在本壳不成立：
  //   系统打印框自己就是选择/确认步骤，多一层反而突兀。
  (function _hookQuickPrint() {
    try {
      var _pp = (window.location || {}).pathname || '';
      if (_pp.indexOf('/main/index.html') < 0) { return; }
      var _n = 0;
      function _tick() {
        _n++;
        var app = null;
        var main = null;
        try { app = window.DE || window.PE || window.SSE || window.PDFE || window.VE || null; } catch (e1) { app = null; }
        try { main = (app && app.getController) ? app.getController('Main') : null; } catch (e2) { main = null; }
        if (main && !main.__lsoQuickPrintPatched) {
          main.__lsoQuickPrintPatched = true;
          // 调用方均为 `_main.onPrintQuick()` 方法调用形式（controller/Toolbar.js），this 绑定成立
          main.onPrintQuick = function () {
            try {
              var printopt = new window.Asc.asc_CAdjustPrint();
              printopt.asc_setNativeOptions({ quickPrint: true });
              var opts = new window.Asc.asc_CDownloadOptions();
              opts.asc_setAdvancedOptions(printopt);
              this.api.asc_Print(opts);   // → 上面的 asc_Print 覆写 → 系统打印框
              console.error('LSO_QUICKPRINT_CALL');
            } catch (e5) { console.error('LSO_QUICKPRINT_ERR ' + String(e5)); }
          };
          console.error('LSO_QUICKPRINT_HOOKED');
          return;
        }
        if (_n < 600) { setTimeout(_tick, 200); } else { console.error('LSO_QUICKPRINT_GIVEUP'); }
      }
      setTimeout(_tick, 1000);
    } catch (cbx) { console.error('LSO_QUICKPRINT_HOOK_ERR ' + String(cbx)); }
  })();
