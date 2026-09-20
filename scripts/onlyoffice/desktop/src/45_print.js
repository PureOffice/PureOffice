  // ---- 打印链（2026-09-10）：官方 asc_Print → 元文件流 → x2t bin2pdf → 系统打印 ----
  // 【迁移注记】本段原含 asc_Print 覆写（元文件流+Save_End 截断+print:bin），已于
  // 2026-09-21 fork 化源码化进 sdkjs fork apiBase.js asc_Print 头部 [OHOS: print]
  // 分支（三编辑器单点）。本段仅余两块 web-apps 侧适配，待随后迁移后整段退役：
  //   ① 打印面板打印机列表注入（cell 打印面板按钮解禁）
  //   ② 快速打印入口修复（onPrintQuick 死按钮）

  // ---- 打印面板打印机列表注入（2026-09-10）----
  // 官方语义（common/lib/controller/Desktop.js:46 + 204-221）：壳层发 printer:config
  // 事件 → webapp.getController('Print').setPrintersInfo(current, printers) 填面板下拉。
  // 该段写在官方 index.html 的 if(!!native) 内，而编辑器页 native 已被 40_save.js 清掉
  // → 下拉恒空 → 官方 onPrinterSelected 的 btnsPrint.forEach(btn=>btn.setDisabled(!record))
  // 使 cell 打印面板的「打印」按钮恒灰（word/slide 直通 asc_Print，不经面板，故只有
  // cell 受影响）。我们作为壳层补发这份配置：HarmonyOS 上打印统一由系统对话框呈现
  // （@ohos.print），无法枚举具体型号，故只报一项「系统打印」占位——选中即解禁按钮，
  // 点击仍汇入 asc_Print（fork 分支）→ 系统打印框。webapp 取值与官方同源
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
              this.api.asc_Print(opts);   // → asc_Print（fork [OHOS: print] 分支）→ 系统打印框
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
