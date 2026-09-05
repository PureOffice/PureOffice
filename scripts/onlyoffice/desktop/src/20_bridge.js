  // ---- 0. 字体注册表注入（早于 sdk-all.js 加载；Externals.js:636 checkAllFonts 唯一入口） ----
  //      __fonts_files/__fonts_infos 契约（POC 实证）：Emumerator checkAllFonts 读
  //      window["__fonts_files"]（undefined → 无字体 → 无法渲染）；官方 AllFonts.js 只
  //      提供 g_fonts_selection_bin（apiBase.js:1535 消费），不提供 __fonts_files。
  //      web 路径 LoadFontAsync → LoadFontArrayBuffer(basePath) XHR fontFilesPath
  //      （GlobalLoaders.js:53 = ../../../../fonts/ = http://localhost/onlyoffice/fonts/）。
  //      字体顺序须 R,I,B,BI（FONT_INFOS 中 indexI=1/indexB=2 即数组下标）。
  window["__fonts_files"] = @@FONT_FILES_JSON@@;
  window["__fonts_infos"] = @@FONT_INFOS_JSON@@;
  // 第三张表：字符范围回退注册表（libfont character.js init 消费；[start, end,
  // FONT_INFOS 行号] 展平三元组）。无它 → CFontByCharacter.Ranges 空 → 中文等
  // 无字形字符的 fallback 永远失败 → 方块（2026-09-05 最后根因，见
  // build_editors_ohos.py FONT_RANGES 注释）。
  window["__fonts_ranges"] = @@FONT_RANGES_JSON@@;
  // （0.3 已回滚，2026-09-05）字族下拉「精灵缺失」修复走**资源侧**：官方 web 语义
  // （Common.Controllers.Desktop.isActive=false → CThumbnailLoader XHR
  //    sdkjs/common/Images/fonts_thumbnail_ea@*.png.bin）由构建链生成精灵产物
  //   （build_editors_ohos.make_fonts_sprites，官方 RLE 格式）——不注入/覆盖
  //   Desktop 控制器（曾试用桩：官方 Desktop.js:786 在 requirejs 模块晚于本页
  //   定义会覆盖桩；且 window.native 语义会使引擎 AscFonts.load 走 native 分支
  //   （sdk-all-min.js 49957）——弃，谨记勿回退）。

  // sdk-all.js（common 清单 = 引擎的另一半：Serialize2/Document/History/GlobalLoaders）
  // 由官方链自动加载：api.js Init → apiBase.js:293 AscCommon.loadSdk(editorName)
  // → editorscommon.js loadScript('../../../../sdkjs/<name>/sdk-all.js') 注入 script 标签。
  // 不得人工预载：loadScript 的本地链只在 window.AscDesktopEditor && local_load_add(未定义)
  // 时跳过 —— 本 shim 天然走普通 script 注入，官方时序（引擎 init 时先于文档打开）。

  var installed = false;

  var INSTALL = function() {
    if (installed) return; installed = true;

    // ---- 1. CEF 202 方法 → AscNative（ArkTS proxy 同步桥） ----
    window.__ascDesktopEditorMethods = {};
@@METHOD_JS@@

    // 对象构造（每方法 own 属性，独立副本）
    var obj = {};
    for (var k in window.__ascDesktopEditorMethods) { obj[k] = window.__ascDesktopEditorMethods[k]; }

    // CEF（desktopinit.js 假设 RendererProcessVariable 已由 C++ 注入）——默认本地主题：
    // ArkWeb 场景无 C++ 注入面，给予默认定值（B 架构 native 主题注入就绪后可移除本节）
    if (!window.RendererProcessVariable) {
      window.RendererProcessVariable = {
        theme: { id: 'default-light', type: 'light', system: 'light' },
        localthemes: [],   // panelsettings.js 用 for..of 迭代 → 必须数组
        rtl: false
      };
    }

    // ---- 2. window.AscDesktopEditor 就绪（引用已由 0.2 占位固化；此处维持原引用） ----
    window.AscDesktopEditor = obj;
    window.desktop = obj;

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

