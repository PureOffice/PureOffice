  // ---- 0. 字体注册表注入（早于 sdk-all.js 加载；Externals.js:636 checkAllFonts 唯一入口） ----
  //      __fonts_files/__fonts_infos 契约（POC 实证）：Emumerator checkAllFonts 读
  //      window["__fonts_files"]（undefined → 无字体 → 无法渲染）；官方 AllFonts.js 只
  //      提供 g_fonts_selection_bin（apiBase.js:1535 消费），不提供 __fonts_files。
  //      web 路径 LoadFontAsync → LoadFontArrayBuffer(basePath) XHR fontFilesPath
  //      （GlobalLoaders.js:53 = ../../../../fonts/ = http://localhost/onlyoffice/fonts/）。
  //      字体顺序须 R,I,B,BI（FONT_INFOS 中 indexI=1/indexB=2 即数组下标）。
  window["__fonts_files"] = @@FONT_FILES_JSON@@;
  window["__fonts_infos"] = @@FONT_INFOS_JSON@@;

  // sdk-all.js（common 清单 = 引擎的另一半：Serialize2/Document/History/GlobalLoaders）
  // 由官方链自动加载：api.js Init → apiBase.js:293 AscCommon.loadSdk(editorName)
  // → editorscommon.js loadScript('../../../../sdkjs/<name>/sdk-all.js') 注入 script 标签。
  // 不得人工预载：loadScript 的本地链只在 window.AscDesktopEditor && local_load_add(未定义)
  // 时跳过 —— 本 shim 天然走普通 script 注入，官方时序（引擎 init 时先于文档打开）。

  var installed = false;

  var INSTALL = function() {
    if (installed) return; installed = true;
    try { console.error('ASC_INSTALL path=' + window.location.pathname); } catch (bx) {}

    // ---- 1. CEF 202 方法 → AscNative（ArkTS proxy 同步桥） ----
    window.__ascDesktopEditorMethods = {};
@@METHOD_JS@@

    // 对象构造（每方法 own 属性，独立副本）
    var obj = {};
    for (var k in window.__ascDesktopEditorMethods) { obj[k] = window.__ascDesktopEditorMethods[k]; }

    // CEF（desktopinit.js 假设 RendererProcessVariable 已由 C++ 注入）——默认本地主题
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

    // ---- 2.33 桌面打开链注入桥：顶层 postMessage {command:'doffline:loadend', url, b64, len}
    //      → 本页(编辑器 iframe)调用 DesktopOfflineAppDocumentEndLoad(url, b64, len)
    //      —— 等价官方 CEF LocalFile_End 注入（字节只此一入口；asc_openDocumentFromBytes
    //      Web 链会被 common/Local/common.js onEndLoadFile 覆写截胡，不得使用）
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
            console.error('E1 ed=' + (!!_ed2));
            try { if (AscCommon.g_oDocumentUrls) { AscCommon.g_oDocumentUrls.documentUrl = d.url; } } catch (e1) { console.error('E2 ' + String(e1)); }
            try { _ed2.setOpenedAt(Date.now()); } catch (e3) { console.error('E3 ' + String(e3)); }
            try { AscCommon.g_oIdCounter.m_sUserId = window.AscDesktopEditor.CheckUserId(); } catch (e4) { console.error('E4 ' + String(e4)); }
            var _bin = AscCommon.Base64.decode(d.b64, false, d.len);
            console.error('E5 bin=' + (!!_bin) + ' len=' + (_bin && _bin.length));
            var _f2 = new AscCommon.OpenFileResult();
            _f2.data = _bin;
            _f2.bSerFormat = AscCommon.checkStreamSignature(_bin, AscCommon.c_oSerFormat.Signature);
            _f2.url = d.url;
            console.error('E5b ser=' + _f2.bSerFormat);
            try {
              var _ldm0 = _ed2.WordControl && _ed2.WordControl.m_oLogicDocument;
              console.error('E8 ldm=' + (!!_ldm0) + ' ctor=' + (_ldm0 && _ldm0.constructor && _ldm0.constructor.name)
                + ' styles=' + (!!(_ldm0 && _ldm0.Styles))
                + ' ext=' + (!!(_ldm0 && _ldm0.Ext)) + ' root=' + (!!(_ldm0 && _ldm0.Root)));
            } catch (e8) {
              console.error('E8_ERR ' + String(e8));
            }
            try {
              var _BR2 = AscCommonWord && AscCommonWord.BinaryFileReader;
              if (_BR2 && !_BR2.prototype.__brHooked2) {
                _BR2.prototype.__brHooked2 = true;
                var _origRead2 = _BR2.prototype.Read;
                _BR2.prototype.Read = function(data) {
                  console.error('BR_READ_START len=' + (data && data.length));
                  try {
                    var r = _origRead2.call(this, data);
                    console.error('BR_READ_END r=' + r);
                    return r;
                  } catch (e) {
                    console.error('BR_READ_EXC ' + String(e));
                    throw e;
                  }
                };
                console.error('BR_HOOKED2');
              }
            } catch (hb) { console.error('BR_HOOK_ERR2 ' + String(hb)); }
            try {
              if (_ed2.asc_openDocumentFromBytes) {
                _ed2.asc_openDocumentFromBytes(_f2.data);
                console.error('E6 OPENED (asc_oDFB)');
              } else {
                _ed2.openDocument(_f2);
                console.error('E6 OPENED');
              }
            } catch (e7) {
              console.error('E7 ' + String(e7));
            }
          } catch (x) {
            console.error('LSO_OFFLINE_ERR ' + String(x));
          }
        }, false);
      } catch (x) {}
    }

    // ---- 2.35 打开链 hook（诊断：loadBinary → asc_openDocumentFromBytes 输入确认；确认后移除） ----
    window.__hookOdFB = function() {
      try {
        var e = window.Asc && (window.Asc.editor || window.editor);
        if (!e || !e.asc_openDocumentFromBytes) return false;
        if (!e.__ohooked) {
          e.__ohooked = true;
          var orig = e.asc_openDocumentFromBytes;
          e.asc_openDocumentFromBytes = function(data) {
            var sig = '-';
            try {
              sig = String.fromCharCode(data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7]);
            } catch (x) {}
            console.error('HBB_START len=' + (data && data.length) + ' sig=' + sig);
            var r = orig.call(this, data);
            console.error('HBB_END ret=' + r);
            // cell（XLSY）打开末端：服务器链用 asyncServerIdEndLoaded 完成 serverId 装载，
            // web 空/离线链无人 kick → workbook 读入后永远停在 loading（POC v12 同坑）：
            // 打开完成后补 kick + wb.resize/asc_setZoom(1)（POC 实证 factor 必须 1.0）。
            // 仅限 XLSY（word 的 asc_setZoom 语义不同，不得触及）。
            if (sig.indexOf('XLSY') === 0 || sig.indexOf('PPTY') === 0) {
              var _isCell = sig.indexOf('XLSY') === 0;
              // cell/slide 打开末端：服务器链用 async*EndLoaded 完成 serverId/images 装载，
              // web 空/离线链无人 kick → 模型读入后停在 loading（POC v12 cell 同坑）。
              // 各步独立兜底：内层可能抛 UI 状态异常（如 isEditOle），不应中断整体。
              try {
                if (this && typeof this.asyncServerIdEndLoaded === 'function') {
                  this.asyncServerIdEndLoaded();
                  console.error('HBB_OPEN_KICK serverId');
                }
              } catch (kc1) { console.error('HBB_OPEN_KICK_SID_ERR ' + String(kc1)); }
              if (!_isCell) {
                // slide 还需 ServerImagesWaitComplete（asyncImagesDocumentEndLoaded）
                try {
                  if (this && typeof this.asyncImagesDocumentEndLoaded === 'function') {
                    this.asyncImagesDocumentEndLoaded();
                    console.error('HBB_OPEN_KICK images');
                  }
                } catch (kc4) { console.error('HBB_OPEN_KICK_IMG_ERR ' + String(kc4)); }
              }
              try {
                if (_isCell && this && this.wbModel && typeof this.wbModel.resize === 'function') { this.wbModel.resize(null); console.error('HBB_OPEN_KICK resize'); }
              } catch (kc2) { console.error('HBB_OPEN_KICK_RESIZE_ERR ' + String(kc2)); }
              try {
                if (this && typeof this.asc_setZoom === 'function') { this.asc_setZoom(1); console.error('HBB_OPEN_KICK zoom'); }
              } catch (kc3) { console.error('HBB_OPEN_KICK_ZOOM_ERR ' + String(kc3)); }
            }
            return r;
          };
          // OpenDocumentFromBin 级 hook（BinaryFileReader.Read 结果）
          if (!e.__ohooked2) {
            e.__ohooked2 = true;
            var origBin = e.OpenDocumentFromBin;
            if (origBin) {
              e.OpenDocumentFromBin = function(url, gObject) {
                console.error('HBB_BIN_START url=' + url + ' gObj=' + (gObject && gObject.constructor && gObject.constructor.name)
                  + ' len=' + (gObject && gObject.length));
                var r = origBin.call(this, url, gObject);
                console.error('HBB_BIN_END ret=' + r);
                return r;
              };
            }
          }
          console.error('HBB_HOOKED');
        }
        return true;
      } catch (x) {
        console.error('HBB_ERR ' + String(x));
        return false;
      }
    };

    // ---- 2.4 postMessage 可见性探针（诊断 LSO 字节链；确认后移除） ----
    if (!window.__ascMsgLog) {
      window.__ascMsgLog = true;
      try {
        window.addEventListener('message', function(e) {
          try {
            var d = e.data;
            if (d && typeof d === 'object' && d.command) {
              var ab = d.data;
              console.error('ASC_MSG ' + d.command + ' len='
                + (ab && ab.byteLength !== undefined ? ab.byteLength : String(ab).slice(0, 60)));
            }
          } catch (x) {}
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

    // ---- 3. 官方 InitJSContext shim（原始 Extract） ----
@@SHIM@@

    // ---- 3.5 web 构建引擎就绪探针（官方 LocalStartOpen 触发；web sdkjs 无 Local 段时
    //      仅靠 isLoadFullApi 轮询，到点调 AscDesktopEditor.LocalStartOpen() 送注入时机） ----
    if (!window.__lsoWaitInstalled) {
      window.__lsoWaitInstalled = true;
      (function waitFull() {
        try {
          var e = window.Asc && (window.Asc.editor || window.editor);
          if (e && e.isLoadFullApi && !window.__lsoDispatched) {
            window.__lsoDispatched = true;
            console.error('LSO_WAITFULL -> LocalStartOpen dispatched');
            if (window.AscNative && window.AscNative._call) {
              try { window.AscNative._call('LocalStartOpen', []); } catch (wx) {}
            }
            return;
          }
        } catch (x) {}
        setTimeout(waitFull, 300);
      })();
    }

