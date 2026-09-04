      // ---- 3.8.1 引擎级诊点（cell loadDocument 'lang' 定位；确认后移除） ----
    try {
      setTimeout(function() {
        try {
          var _CD = (window.Asc && window.Asc.asc_CDocInfo) || (window.AscCommon && window.AscCommon.asc_CDocInfo);
          if (_CD && _CD.prototype && !_CD.prototype.__lhLang) {
            var _op = _CD.prototype.put_Lang;
            _CD.prototype.__lhLang = true;
            _CD.prototype.put_Lang = function(l) {
              console.error('LSO_PUTLANG arg=' + String(l) + ' selfLang=' + this.lang + ' selfUrl=' + this.url);
              return _op.call(this, l);
            };
          }
          var _ea = (window.Asc && window.Asc.editor) || (window.AscCommon && window.AscCommon.editor);
          if (_ea && !_ea.__ehSDI) {
            _ea.__ehSDI = true;
            var _os = _ea.asc_setDocInfo;
            if (_os) {
              _ea.asc_setDocInfo = function(oi) {
                console.error('LSO_SDI has=' + (!!oi));
                var r = _os.call(this, oi);
                console.error('LSO_SDI_DONE');
                return r;
              };
            }
          }
        } catch (sx) { console.error('LSO_ENG_HOOK_ERR ' + String(sx)); }
      }, 1200);
    } catch (hx) {}

    // ---- 3.8.4 保存链管控（M4）：web/apiBase 的 asc_Save 依赖 AscCommon.History（其类
    //      定义在 common 清单文件里，min 构建不加载 → _haveChanges 抛错），且 else 分支走
    //      服务器下载死路。按官方桌面 Local/api.js 的协议骨架重写 asc_Save（原型级，
    //      实例更换/重建均生效；官方 Local/api.js 同样是原型覆写）：guard 检查
    //      （canSave/isSaveAs/isResaveAttack）→ askSaveChanges（官方 UI 保存态）→
    //      asc_nativeGetFileData（BinaryFileWriter 序列化当前模型 → DOCY;v10 原始字节，
    //      与打开链 in.bin 同格式）→ base64 → execCommand('save:bin') → ArkTS x2t
    //      doct_bin2docx → save.docx + 回写源文件。轮询等待原型就绪。 ----
    (function _hookSave() {
      try {
        if (!window.Asc || !window.Asc.asc_docs_api) { setTimeout(_hookSave, 200); return; }
        var _proto = window.Asc.asc_docs_api.prototype;
        if (!_proto || typeof _proto.asc_Save !== 'function' || typeof _proto.asc_nativeGetFileData !== 'function') {
          setTimeout(_hookSave, 200); return;
        }
        if (_proto.__lsoSaveWrap) return; _proto.__lsoSaveWrap = true;
        var _s0 = _proto.asc_Save;
        _proto.asc_Save = function(isNoUserSave, isSaveAs, isResaveAttack, options) {
          var _cur = window.Asc && (window.Asc.editor || window.editor);
          var _t = this;
          try {
            // 官方 Local/api.js:158 守卫（省略 History 依赖项）
            if (isResaveAttack === true || isSaveAs === true) { console.error('LSO_SAVE_GUARD resave/saveas'); return; }
            if (true !== isNoUserSave) { this.IsUserSave = true; }
            if (!(this.canSave && !this.isLongAction() && !this.isGroupActions())) {
              console.error('LSO_SAVE_GUARD canSave=' + this.canSave + ' long=' + this.isLongAction()
                + ' group=' + this.isGroupActions());
              return;
            }
            this.canSave = false;
            try {
              if (this.CoAuthoringApi && typeof this.CoAuthoringApi.askSaveChanges === 'function') {
                this.CoAuthoringApi.askSaveChanges(function(e) { _t._onSaveCallback(e); });
              }
              // asc_nativeGetFileData 末尾回调 window["native"]["Save_End"] —— 官方桌面壳的
              // native 对象。全局挂 stub 会让 editorscommon loadScript 走"本地加载已成功"
              // 假分支（onSuccess 直接返回 → 模块缺失 → 文档打不开）——故仅在本调用期间
              // 临时挂 Save_End（序列化路径只用 Save_End 一处）。
              var _oldNative = window.native;
              window.native = { Save_End: function() {} };
              var _nbin;
              try {
                _nbin = this.asc_nativeGetFileData();
              } finally {
                window.native = _oldNative;
              }
              var _r2 = '';
              if (_nbin && _nbin.byteLength) {
                var _b64 = '';
                for (var _i = 0; _i < _nbin.length; _i += 0x8000) {
                  _b64 += String.fromCharCode.apply(null, _nbin.slice(_i, _i + 0x8000));
                }
                _b64 = btoa(_b64);
                _r2 = String(window.AscNative && window.AscNative._call('execCommand', ['save:bin', _b64]));
                console.error('LSO_NATIVE_SAVE len=' + _nbin.byteLength + ' ret=' + _r2);
              } else {
                console.error('LSO_NATIVE_SAVE_EMPTY');
              }
            } catch (nsv) {
              console.error('LSO_NATIVE_SAVE_ERR ' + String(nsv));
              this.canSave = true;
              return;
            }
            this.canSave = true;
          } catch (gv) {
            console.error('LSO_SAVE_WRAP_ERR ' + String(gv));
            return _s0.apply(this, arguments);
          }
        };
        console.error('LSO_SAVE_HOOKED');
      } catch (cbx) { console.error('LSO_SAVE_HOOK_ERR ' + String(cbx)); }
    })();

    // ---- 3.8.2b Gateway.requestClose 覆写（M5 方案 C「关闭」）：官方 web 链 onRequestClose
    //      （文档已修改时先弹「放弃修改并离开」框）→ Common.Gateway.requestClose() —— web
    //      语义为上报宿主壳关闭；本页即宿主 → 直接回官方欢迎页（与 goback 同构；不依赖
    //      window.AscDesktopEditor，web 语义可用）。 ----
    (function _hookGW() {
      try {
        var _g = window.Common && window.Common.Gateway;
        if (!_g || typeof _g.requestClose !== 'function') { setTimeout(_hookGW, 200); return; }
        if (!window.__lsoReqClose) {
          window.__lsoReqClose = true;
          _g.requestClose = function() {
            console.error('LSO_REQUEST_CLOSE -> welcome');
            try { window.location.href = 'http://localhost/onlyoffice/index.html'; } catch (e) { console.error('LSO_RC_ERR ' + String(e)); }
          };
          console.error('LSO_RC_HOOKED');
        }
      } catch (gx) { console.error('LSO_RC_HOOK_ERR ' + String(gx)); }
    })();

    // ---- 3.8.3 Gateway.saveDocument 落盘（保存链 M4）：官方 asc_onSaveDocument →
    //      Common.Gateway.saveDocument(data) （web 服务器链=上传）—— 无服务器下覆写为
    //      base64 → AscNative._call('LocalFileSaveBin') → ArkTS 写沙箱 + 回写源文件。 ----
    try {
      if (window.Common && window.Common.Gateway && window.Common.Gateway.saveDocument && !window.__lsoSaveDoc) {
        window.__lsoSaveDoc = true;
        var _sd0 = window.Common.Gateway.saveDocument;
        window.Common.Gateway.saveDocument = function(data) {
          console.error('LSO_SAVEDOC len=' + (data && (data.byteLength || data.length)));
          try {
            var _u8 = data instanceof Uint8Array ? data : new Uint8Array(data);
            if (_u8.length > 200 * 1024 * 1024) { console.error('LSO_SAVEDOC_TOOBIG ' + _u8.length); return; }
            var _bin = '';
            for (var _i = 0; _i < _u8.length; _i += 0x8000) {
              _bin += String.fromCharCode.apply(null, _u8.slice(_i, _i + 0x8000));
            }
            var _b64 = btoa(_bin);
            var _r = window.AscNative && window.AscNative._call('LocalFileSaveBin', [_b64]);
            console.error('LSO_SAVEDOC_CALL ret=' + String(_r).slice(0, 60));
          } catch (se) { console.error('LSO_SAVEDOC_ERR ' + String(se)); }
          return _sd0 ? _sd0.call(this, data) : undefined;
        };
      }
    } catch (sdx) { console.error('LSO_SAVEDOC_HOOK_ERR ' + String(sdx)); }

    // ---- 3.8.2 引擎级 -25(EditingError) 拦截：在 asc_onError 分发前吞掉 —— Main.onError
    //      hook 注册时机晚于 sdk 加载期 unhandled-rejection → 弹窗仍出。sendEvent 层拦截
    //      在任何 handler 触达前生效。 ----
    (function _hookSendEv() {
      try {
        var _e = window.Asc && (window.Asc.editor || window.editor);
        if (!_e || !_e.sendEvent) { setTimeout(_hookSendEv, 200); return; }
        if (!_e.__seHooked) {
          _e.__seHooked = true;
          var _se = _e.sendEvent;
          _e.sendEvent = function(evt, a1, a2, a3, a4) {
            if (evt === 'asc_onError' && (a1 === -25 || a1 === undefined && false)) {
              console.error('LSO_SE_IGN EditingError(-25)');
              return;
            }
            return _se.apply(this, arguments);
          };
          console.error('LSO_SE_HOOKED');
        }
      } catch (nx) {}
    })();

    // ---- 3.8 全局 uncaught 捕获（诊断 onLaunch 中断位置） ----
    try {
      if (!window.__lsoJSE) {
        window.__lsoJSE = true;
        window.addEventListener('error', function(ev) {
          try {
            console.error('JSE ' + String(ev && ev.message).slice(0, 200)
              + ' @' + (ev && ev.filename ? String(ev.filename).slice(-56) : '?') + ':' + (ev && ev.lineno));
          } catch (x) {}
        }, true);
      }
    } catch (jx) {}

    // ---- 3.7 编辑器页（/main/index.html）web 语义开关：删除 AscDesktopEditor → sdkjs/
    //      webapps 不进入 isDesktopApp 桌面分支（桌面分支把字体 wasm/字体选择表切到
    //      native 通路，g_fonts_selection_bin 类缺失 → Base64.decode(undefined) 崩 →
    //      "打开文件时发生错误"）。桌语义启用=三条件（native 字体供给 + LoadJS + allfonts
    //      桌面装载），现阶段未齐 —— 保持 web 语义。
    //      "关闭/返回"能力用官方 web 机制：editorConfig.customization.goback.url →
    //      Main.js canBack=true → 头部/文件菜单"返回"按钮 → goback → location.href 回欢迎页。
    try {
      if (window.location && window.location.pathname && window.location.pathname.indexOf('/main/index.html') >= 0) {
        try { delete window.AscDesktopEditor; } catch (d1) { window.AscDesktopEditor = undefined; }
        try { delete window.desktop; } catch (d2) { window.desktop = undefined; }
        console.error('LSO_WEB_SEMANTIC (editor page)');
      }
    } catch (nx) {}

