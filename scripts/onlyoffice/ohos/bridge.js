// ============================================================================
// ohos/bridge.js —— AscDesktopEditor 桥装配（原 ascshim 20_bridge INSTALL 主体
// + 50_init AscNative 等待 + 40_save 3.7/3.7.1 web 语义开关/放映全屏，2026-09-21
// fork 化阶段 2-j2 源码化：宿主装配域定制模块模板，装配链（build_editors_
// ohos.py）复制时展开两占位符（方法表 METHOD_JS 与官方 shim SHIM，生成逻辑
// 同源自 asc_methods.txt / ascdesktop_shim_raw.js；注：注释内勿写占位符原文，
// 装配替换按子串全局匹配——注释里的提及同样会被展开）。
//
// 加载模型：本文件由编辑器 main/index.html <head> 注入（早于编辑器 app）；
// INSTALL 在 AscNative（ArkWeb registerJavaScriptProxy）注入后执行——等待
// 循环内置（ASC_BOOT/ASC_FOUND 区分「未加载」与「未注入」两种失败）。
// INSTALL 体内尾部（_onReady 前）执行 3.7 编辑器页删除：AscDesktopEditor
// 装上后立即删——引擎字体链检测窗口（sdk-all.js 加载/初始化期）内对象不
// 存在 → web 分支（旧 ascshim 同语义：3.7 在 INSTALL 函数体内、闭合 }; 由
// 50_init 提供；**INSTALL 的闭合边界必须包住 3.7**——切在它之前=装上无人删）。
// ============================================================================
(function() {
  var installed = false;

  var INSTALL = function() {
    if (installed) return; installed = true;

    // ---- 1. CEF 202 方法 → AscNative（ArkTS proxy 同步桥） ----
    window.__ascDesktopEditorMethods = {};
@@METHOD_JS@@

    // 对象构造（每方法 own 属性，独立副本）
    var obj = {};
    for (var k in window.__ascDesktopEditorMethods) { obj[k] = window.__ascDesktopEditorMethods[k]; }

    // 主题注入不在本段（2026-09-08 教训：INSTALL 在 AscNative 就绪后才执行——官方
    // desktopinit 内联段同步一次性消费 RPV，那时官方兜底 theme-system 已走完且无人
    // 重放→注入执行≠生效）。原 ascshim 头部段已于 fork 化阶段退役：默认值/RPV 兜底
    // 进 web-apps fork themeinit.js（1-i），tab 主题色上报进 controller/Themes.js
    // [OHOS: theme]（2-b）。
    // ---- 2. window.AscDesktopEditor 就绪（引用已由 0.2 占位固化；此处维持原引用） ----
    window.AscDesktopEditor = obj;
    window.desktop = obj;
    // 2.05 装配对象缓存（2026-09-11）：3.7 为字体链 web 语义会删除
    //   window.AscDesktopEditor，而 sdkjs 放映引擎只在它存在时才调 SetFullscreen
    //   （Transitions.js:4075）→ 3.7.1 在放映期用本缓存临时恢复、退出再删。勿删。
    window.__lsoAscDE = obj;

    // ---- 2.1 LoadFontBase64 特化（2026-09-05 中文方块根因修复）----
    // 官方语义（Externals.js LoadFontAsync 桌面分支）：AscDesktopEditor.LoadFontBase64(id)
    // 后引擎取 window[id] → AscFonts.CreateFontData4 → 字体流（base64 前缀格式
    // "<size>;<b64>"，sdkjs stringserialize.js Base64.decode(input, true) 消费）。
    // 通用包装（方法表占位行展开）只 _call + 解 JSON 返回，从不写 window[id]——
    // 而 CEF 桌面版是由 C++ 直接写 window[id]。B 架构下桥返回串必须自己回填：
    try {
      window.AscDesktopEditor["LoadFontBase64"] = function(id) {
        var r = window.AscNative && window.AscNative._call("LoadFontBase64", [id]);
        if (r) {
          var v = r;
          try { v = JSON.parse(r); } catch (e3) { v = r; }
          if (v) { try { window[id] = v; } catch (e3) { console.error('LSO_FB64_SET ' + String(e3)); } }
        }
      };
      console.error('LSO_FB64_OVERRIDDEN');
    } catch (e) { console.error('LSO_FB64_ERR ' + String(e)); }

    // ---- 2.33 桌面打开链注入桥：顶层 postMessage {command:'doffline:loadend', url, b64, len}
    //      → 本页(编辑器 iframe)调用 DesktopOfflineAppDocumentEndLoad(url, b64, len)
    //      —— 等价官方 CEF LocalFile_End 注入（字节只此一入口；asc_openDocumentFromBytes
    //      Web 链会被 common/Local/common.js onEndLoadFile 覆写截胡，不得使用）。
    //      当前 ArkTS 侧走 openDocumentFromBinary（EditorPage 注入）——本桥为“桌面三件套”
    //      （native 字体/loadjs/allfonts）就绪后的官方通道，暂休眠（保留协议注释）。
    //      休眠期安全注（2026-09-05 审查）：启用前必须补 message 源校验（官方 Gateway.js
    //      _onMessage 有 origin 检查，Gateway.js:183-184；本监听接受任意帧消息）。
    if (!window.__lsoBridgeInstalled) {
      window.__lsoBridgeInstalled = true;
      try {
        window.addEventListener('message', function(e) {
          var d = e.data;
          if (!d || typeof d !== 'object' || d.command !== 'doffline:loadend') return;
          try {
            console.error('LSO_OFFLINE_MSG url=' + d.url + ' b64len=' + (d.b64 ? d.b64.length : 'undefined')
              + ' len=' + d.len);
            var _ed2 = (window.Asc && window.Asc.editor) || window.editor;
            try { if (AscCommon.g_oDocumentUrls) { AscCommon.g_oDocumentUrls.documentUrl = d.url; } } catch (e1) { console.error('LSO_DFB_E2 ' + String(e1)); }
            try { _ed2.setOpenedAt(Date.now()); } catch (e3) { console.error('LSO_DFB_E3 ' + String(e3)); }
            try { AscCommon.g_oIdCounter.m_sUserId = window.AscDesktopEditor.CheckUserId(); } catch (e4) { console.error('LSO_DFB_E4 ' + String(e4)); }
            var _bin = AscCommon.Base64.decode(d.b64, false, d.len);
            var _f2 = new AscCommon.OpenFileResult();
            _f2.data = _bin;
            _f2.bSerFormat = AscCommon.checkStreamSignature(_bin, AscCommon.c_oSerFormat.Signature);
            _f2.url = d.url;
            try {
              if (_ed2.asc_openDocumentFromBytes) {
                _ed2.asc_openDocumentFromBytes(_f2.data);
              } else {
                _ed2.openDocument(_f2);
              }
            } catch (e7) {
              console.error('LSO_DFB_OPEN_ERR ' + String(e7));
            }
          } catch (x) {
            console.error('LSO_OFFLINE_ERR ' + String(x));
          }
        }, false);
      } catch (x) {}
    }

    // ---- 2.5 loginpage 面板刷新桥（官方 C++ 侧 Recents_Dump 注入 window.onupdaterecents；
    //        loginpage sdk.js 面板订阅 sdk.on('onupdaterecents') → sdk.fire 转发）
    if (!window.onupdaterecents) {
      window.onupdaterecents = function(arr) {
        if (window.sdk && window.sdk.fire) window.sdk.fire('onupdaterecents', arr);
      };
    }
    if (!window.onupdaterecovers) {
      window.onupdaterecovers = function(arr) {
        if (window.sdk && window.sdk.fire) window.sdk.fire('onupdaterecovers', arr);
      };
    }

    // ---- 2.6 recents 删除/清除后页面刷新（2026-09-05 fix「从列表中删除无效」）----
    // 官方面板动作链：Remove from list → sdk.LocalFileRemoveRecent(fileid)；Clear →
    //   sdk.LocalFileRemoveAllRecents()。官方桌面 C++ 删除成功后重灌 Recents_Dump
    //   （window.onupdaterecents）刷新面板；B 架构无 C++ → 本段在原生命令返回成功
    //   （ascBridge 真删 recents.json）后调 sdk.LocalFileRecents()（native 返回最新
    //   清单）→ window.onupdaterecents / sdk.fire → 官方面板刷新（2.5 桥转发链）。
    // 时机：sdk 由 loginpage 页面脚本创建（ascshim 先载）→ 轮询等待（60s 上限，超时
    //   静默 —— 功能本体（真删）不受影响，仅面板刷新缺席）。
    (function () {
      var _ppe = (window.location || {}).pathname || '';
      if (_ppe.indexOf('/onlyoffice/index.html') < 0) { return; }
      var _nre = 0;
      var _wrapSdkRec = function() {
        try {
          var _s = window.sdk;
          if (!_s || typeof _s.LocalFileRemoveRecent !== 'function' || typeof _s.LocalFileRecents !== 'function') {
            if ((_nre = (_nre || 0) + 1) < 300) { setTimeout(_wrapSdkRec, 200); return; }
            return;
          }
          if (window.__lsoSdkRecentsWrapped) { return; }
          window.__lsoSdkRecentsWrapped = true;
          var _refres = function() {
            try {
              var _d = _s.LocalFileRecents();
              var _arr = typeof _d === 'string' ? JSON.parse(_d) : (_d || []);
              if (window.onupdaterecents) { window.onupdaterecents(_arr); }
              else if (_s.fire) { _s.fire('onupdaterecents', _arr); }
            } catch (rf) { console.error('LSO_RECENTS_REFRESH_ERR ' + String(rf)); }
          };
          var _rmr = _s.LocalFileRemoveRecent;
          _s.LocalFileRemoveRecent = function(id) {
            var _r = _rmr.apply(this, arguments);
            if (_r === '1' || _r === 1 || _r === true) { _refres(); }
            return _r;
          };
          var _ral = _s.LocalFileRemoveAllRecents;
          if (typeof _ral === 'function') {
            _s.LocalFileRemoveAllRecents = function() {
              var _r2 = _ral.apply(this, arguments);
              if (_r2 === '1' || _r2 === 1 || _r2 === true) { _refres(); }
              return _r2;
            };
          }
          console.error('LSO_SDK_RECENTS_WRAPPED');
        } catch (sx) {}
      };
      _wrapSdkRec();
    })();

    // ---- 3. 官方 InitJSContext shim（原始 Extract） ----
@@SHIM@@

    // ---- 3.5 web 构建引擎就绪探针（官方 LocalStartOpen 触发；web sdkjs 无 Local 段时
    //      仅靠官方引擎状态位 isLoadFullApi 轮询，到点调 AscDesktopEditor.LocalStartOpen()
    //      送注入时机；isLoadFullApi ∈ 官方状态位（apiBase.js:296 loadSdk 完成回调内），
    //      非界面元素判断）。页门控（编辑器页才有 Asc 对象）+ 重试上限 300（90s）——
    //      欢迎页不再永久空转（2026-09-05 审查）。 ----
    if (!window.__lsoWaitInstalled) {
      window.__lsoWaitInstalled = true;
      (function waitFull() {
        var _pp = window.location && window.location.pathname || '';
        if (_pp.indexOf('/main/index.html') < 0) { return; }
        try {
          var e = window.Asc && (window.Asc.editor || window.editor);
          if (e && e.isLoadFullApi && !window.__lsoDispatched) {
            window.__lsoDispatched = true;
            if (window.AscNative && window.AscNative._call) {
              try { window.AscNative._call('LocalStartOpen', []); }
              catch (wx) {
                console.error('LSO_LOCALSTARTOPEN_ERR ' + String(wx));
                window.__lsoDispatched = false; // 注入机会丢失不得无痕迹：复位后随页面重启重试
              }
            }
            return;
          }
        } catch (x) {}
        if ((window.__lsoWaitN = (window.__lsoWaitN || 0) + 1) < 300) { setTimeout(waitFull, 300); }
        else { console.error('LSO_WAITFULL_GIVEUP'); }
      })();
    }

  // ---- 用户字体进「字体名字典」（2026-09-18）----
  // 引擎的字体名解析链是：g_fontApplication.GetFontFileWeb(name)
  //   → FD_FontDictionary.GetFontIndex(oSelect, g_fontSelections.List, ...)
  // **它根本不查 __fonts_infos**，而是遍历 g_fontSelections.List —— 那张表由
  // CFontSelectList.Init() 从构建期静态数据建立（类内嵌 base64 / g_fonts_selection_bin），
  // 用户字体名不在其中 → 请求名解析失败 → 静默落到默认 Arial。真机探针实证：
  //     FONT_PICK FontPicker: LXGW WenKai => Arial
  // 此时字体字节装填得再好也不会被用上：装填链只负责「按文件名喂字节」，而
  // 「名字 → 哪个文件」由这张字典决定（上面两条 push 只填了后半程）。
  // 修法：等表建好（IsInit）后把用户字体条目补进去，并清 FontPickerMap 缓存——
  // 解析结果按名缓存，首次失败（→Arial）会一直沿用，不清则整页都错。
  // 条目从表里现成对象复制、只改名字：GetPenalty 要读 Panose/CodePage 等字段，
  // 自造空对象会在那里出错。
  (function _userFontIntoDictionary() {
    var _tries = 0;
    (function _wait() {
      try {
        var _names = window.__lso_user_font_names || [];
        if (!_names.length) { return; }                 // 没导入过字体：本段不参与
        var _A = window.AscFonts;
        var _app = _A && _A.g_fontApplication;
        var _sel = _app && _app.g_fontSelections;
        if (!_sel || _sel.IsInit !== true || !_sel.List || !_sel.List.length) {
          if (++_tries < 600) { setTimeout(_wait, 200); }
          else { console.error('LSO_UFONT_DICT_GIVEUP'); }
          return;
        }
        var _list = _sel.List;
        var _tpl = _list[0];
        var _added = 0;
        for (var i = 0; i < _names.length; ++i) {
          var _nm = String(_names[i] || '');
          if (!_nm) { continue; }
          var _hit = false;
          for (var j = 0; j < _list.length; ++j) {
            if (_list[j] && _list[j].m_wsFontName === _nm) { _hit = true; break; }
          }
          if (_hit) { continue; }
          var _o = Object.create(Object.getPrototypeOf(_tpl));
          for (var _k in _tpl) { _o[_k] = _tpl[_k]; }
          _o.m_wsFontName = _nm;
          if (_o.m_names && _o.m_names.length) { _o.m_names = [_nm]; }
          _list.push(_o);
          if (_sel.ListMap) { _sel.ListMap[_nm] = _list.length - 1; }
          _added++;
        }
        if (_added > 0) { _app.FontPickerMap = {}; }    // 清缓存（见上）
        console.error('LSO_UFONT_DICT added=' + _added + ' total=' + _list.length);
      } catch (_e) { console.error('LSO_UFONT_DICT_ERR ' + String(_e)); }
    })();
  })();


    // ---- 3.7 编辑器页（/main/index.html）web 语义开关：删除 AscDesktopEditor ----
    // **必须在 INSTALL 体内、紧随装配执行**——删的是刚装上的对象。若挪到本文件
    // 同步体（IIFE 直下），执行时 INSTALL 尚未跑（wait 等 AscNative 异步触发），
    // 删除变 no-op；随后 INSTALL 装上对象再无人删 → sdkjs/webapps 检测到对象 →
    // isDesktopApp 桌面分支生效 → 字体 wasm/选择表切 native 通路（g_fonts_
    // selection_bin 类缺失 → Base64.decode(undefined) 崩）+ 引擎桌面字体装载链
    // 先行装满 g_fonts_streams（09_fonts 装填 idx 漂移）+ slide 域 m_pFaceInfo
    // null 渲染崩。删除后引擎保持 web 分支（桌面语义启用=三条件：native 字体
    // 供给 + LoadJS + allfonts 桌面装载，现阶段未齐）。
    // "关闭/返回"能力用官方 web 机制：editorConfig.customization.goback.url →
    // Main.js canBack=true → 头部/文件菜单"返回"按钮 → goback → location.href 回欢迎页。
    // 欢迎页（loginpage）不删：sdk 面板链（Recents/Recovers）依赖桌面语义方法表。
    try {
      if (window.location && window.location.pathname && window.location.pathname.indexOf('/main/index.html') >= 0) {
        try { delete window.AscDesktopEditor; } catch (d1) { window.AscDesktopEditor = undefined; }
        try { delete window.desktop; } catch (d2) { window.desktop = undefined; }
        console.error('LSO_WEB_SEMANTIC (editor page)');
      }
    } catch (nx) {}

    // ---- 3.7.1 放映全屏通道（2026-09-11，PPT 放映「只在 webview 内播」修复）----
    // 根因（真机 1.6 实证 + 时序日志）：sdkjs 放映引擎只在
    //   `undefined !== window["AscDesktopEditor"]` 时才调 SetFullscreen
    //   （Transitions.js:4075 开始 / :4555 结束）——官方桌面语义里放映全屏是 native 层
    //   的事（web-apps Viewport.js:312 对 isDesktopApp 又显式跳过浏览器 Fullscreen
    //   API，两条路只此一条）。而 3.7 为字体链 web 语义删除了该对象 → 放映时无任何
    //   壳层全屏动作（用户现象：tab 栏与窗口都不动，画面只在 webview 内铺）。
    // 修法=**放映期临时恢复**（web-apps 官方事件驱动；两事件都在 DocumentPreview 的
    //   show/hide 内同步触发——show 早于引擎 StartDemonstration、hide 晚于引擎 End）：
    //     preview:show → window.AscDesktopEditor = window.__lsoAscDE（上方装配的同份）
    //     preview:hide → 再删除（回到 3.7 的 web 语义）
    //   选"临时"而非"文档就绪后长期恢复"：3.7 注释警告的字体 native 分支按对象存在性
    //   判定，放映期（文档已打开、字体链早已走完）恢复可完全避开该风险面。
    // 判据日志：LSO_FS_BRIDGE on/off（HOOKED=钩子就位）。
    (function _hookShowFullscreen() {
      try {
        if ((window.location || {}).pathname.indexOf('/main/index.html') < 0) { return; }
        var _n = 0;
        var _tick = function() {
          _n++;
          var NC = window.Common && window.Common.NotificationCenter;
          if (NC && typeof NC.on === 'function' && !NC.__lsoFsBridge) {
            NC.__lsoFsBridge = true;
            NC.on('preview:show', function() {
              try {
                if (window.__lsoAscDE) {
                  window.AscDesktopEditor = window.__lsoAscDE;
                  console.error('LSO_FS_BRIDGE on');
                }
              } catch (e2) { console.error('LSO_FS_BRIDGE_ERR ' + String(e2)); }
            });
            NC.on('preview:hide', function() {
              try {
                delete window.AscDesktopEditor;
                console.error('LSO_FS_BRIDGE off');
              } catch (e3) {}
            });
            console.error('LSO_FS_BRIDGE_HOOKED');
            return;
          }
          if (_n < 900) { setTimeout(_tick, 200); }
        };
        setTimeout(_tick, 500);
      } catch (e) { console.error('LSO_FS_BRIDGE_ERR ' + String(e)); }
    })();

    if (window.AscNative && window.AscNative._onReady) window.AscNative._onReady();
    // 自检登记：INSTALL 仅在 AscNative 注入后调用 → 走到这里=页面侧壳桥已就绪
    (window.__lsoShim = window.__lsoShim || []).push('bridge');
  };

  //（3.7 web 语义删除 + 3.7.1 放映全屏钩子在 INSTALL 体内执行——见下方装配处）

  // AscNative 由 ArkWeb registerJavaScriptProxy('AscNative', ...) 注入；等待它出现
  //（等注入对象，非界面/时间判据——ArkWeb 注入时序所致）
  try { console.error('ASC_BOOT ' + (window.location.pathname || '')); } catch (bx) {}
  (function wait() {
    if (window.AscNative) { try { console.error('ASC_FOUND native=' + (typeof window.AscNative._call)); } catch (bx) {} INSTALL(); return; }
    if (!wait.__log && (window.__lsoWaitN = (window.__lsoWaitN || 0) + 1) === 20) {
      wait.__log = true;
      console.error('ASC_WAITING_ASC (1s, no AscNative)');
    }
    setTimeout(wait, 50);
  })();
})();
