  // ---- 3.8.4 序列化公共工具：asc_nativeGetFileData 需要 window.native.Save_End 存在
  //      （官方 Local/api.js 依赖），但全局挂 stub 会让 editorscommon loadScript 走
  //      "本地加载已成功"假分支（onSuccess 直接返回 → 模块缺失 → 文档打不开）——
  //      仅调用期间临时挂、finally 还原。30_open m7auto 与本节共用此口。 ----
  window.__lsoNativeSaveEnd = function(fn) {
    var _old = window.native;
    window.native = { Save_End: function() {} };
    try { return fn(); } finally { window.native = _old; }
  };

  // ---- 3.8.4 保存链管控（M4）：web/apiBase 的 asc_Save 依赖 AscCommon.History（其类
  //      定义在 common 清单文件里，min 构建不加载 → _haveChanges 抛错），且 else 分支走
  //      服务器下载死路。按官方桌面 Local/api.js 的协议骨架重写 asc_Save（原型级，
  //      实例更换/重建均生效；官方 Local/api.js 同样是原型覆写）：guard 检查
  //      （canSave/isSaveAs/isResaveAttack）→ askSaveChanges（官方 UI 保存态）→
  //      asc_nativeGetFileData（BinaryFileWriter 序列化当前模型 → DOCY;v10 原始字节，
  //      与打开链 in.bin 同格式）→ base64 → execCommand('save:bin') → ArkTS x2t
  //      doct_bin2docx → save.<ext> + 回写源文件。轮询等待原型就绪。 ----
  (function _hookSave() {
    try {
      // 页门控：仅编辑器页（欢迎页无 Asc 对象，空转无意义）；重试上限 300 次（60s）
      // —— 2026-09-05 审查：原实现无上限且只等 asc_docs_api（cell 页无此构造，
      // cell 的 api 原型在 spreadsheet_api 上）——cell 页永久空转。
      var _pp = (window.location || {}).pathname || '';
      if (_pp.indexOf('/main/index.html') < 0) { return; }
      if (!window.Asc || !(window.Asc.asc_docs_api || window.Asc.spreadsheet_api || window.Asc.presentation_api)) {
        if ((window.__lsoSaveWaitN = (window.__lsoSaveWaitN || 0) + 1) < 300) setTimeout(_hookSave, 200);
        return;
      }
      var _proto = (window.Asc.asc_docs_api || window.Asc.spreadsheet_api || window.Asc.presentation_api).prototype;
      if (!_proto || typeof _proto.asc_Save !== 'function' || typeof _proto.asc_nativeGetFileData !== 'function') {
        if ((window.__lsoSaveWaitN = (window.__lsoSaveWaitN || 0) + 1) < 300) setTimeout(_hookSave, 200);
        return;
      }
      if (_proto.__lsoSaveWrap) return; _proto.__lsoSaveWrap = true;
      var _s0 = _proto.asc_Save;
      _proto.asc_Save = function(isNoUserSave, isSaveAs, isResaveAttack, options) {
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
            // 偏差声明（2026-09-05）：askSaveChanges 回调不等待——离线单机同文件覆盖
            // 保存无取消语义；官方 _onSaveCallback（apiBase.js:1657）会复位 canSave，
            // 本适配在序列化完成后自行复位（LSO_NATIVE_SAVE_ERR 路径亦复位）。
            if (this.CoAuthoringApi && typeof this.CoAuthoringApi.askSaveChanges === 'function') {
              this.CoAuthoringApi.askSaveChanges(function(e) { _t._onSaveCallback(e); });
            }
            var _nbin = window.__lsoNativeSaveEnd(function() {
              return _t.asc_nativeGetFileData();
            });
            var _r2 = '';
            if (_nbin && _nbin.byteLength) {
              _r2 = String(window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_nbin)]));
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
      // 页门控+重试上限（同 _hookSave：欢迎页空转处理，2026-09-05）
      var _ppw = (window.location || {}).pathname || '';
      if (_ppw.indexOf('/main/index.html') < 0) { return; }
      var _g = window.Common && window.Common.Gateway;
      if (!_g || typeof _g.requestClose !== 'function') {
        if ((window.__lsoGWWaitN = (window.__lsoGWWaitN || 0) + 1) < 300) setTimeout(_hookGW, 200);
        return;
      }
      if (!window.__lsoReqClose) {
        window.__lsoReqClose = true;
        _g.requestClose = function() {
          console.error('LSO_REQUEST_CLOSE -> welcome');
          // 欢迎页语言=URL lang 参数（缺省 en）——与 goback/homeUrl 同参，保持中文
          try { window.location.href = 'http://localhost/onlyoffice/index.html?lang=zh-CN'; } catch (e) { console.error('LSO_RC_ERR ' + String(e)); }
        };
        console.error('LSO_RC_HOOKED');
      }
    } catch (gx) { console.error('LSO_RC_HOOK_ERR ' + String(gx)); }
  })();

  // ---- 3.8.3 Gateway.saveDocument 落盘（保存链 M4）：官方 asc_onSaveDocument →
  //      Common.Gateway.saveDocument(data) （web 服务器链=上传）—— 无服务器下覆写为
  //      base64 → 走与 asc_Save 覆写同一条链（execCommand('save:bin') → ArkTS x2t 落盘），
  //      **不再调回原 saveDocument**（官方实现 postMessage 到父帧，顶层页无接收者；
  //      调回=双通道，与注释"避免双通道"矛盾——2026-09-05 审查修复）。
  //      上限 200MB 为不落盘的防护线（单机文档远小于此；超限仅日志，后续可加 UI 反馈）。
  try {
    if (window.Common && window.Common.Gateway && window.Common.Gateway.saveDocument && !window.__lsoSaveDoc) {
      window.__lsoSaveDoc = true;
      window.Common.Gateway.saveDocument = function(data) {
        console.error('LSO_SAVEDOC len=' + (data && (data.byteLength || data.length)));
        try {
          var _u8 = data instanceof Uint8Array ? data : new Uint8Array(data);
          if (_u8.length > 200 * 1024 * 1024) { console.error('LSO_SAVEDOC_TOOBIG ' + _u8.length); return; }
          var _r = window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_u8)]);
          console.error('LSO_SAVEDOC_CALL ret=' + String(_r).slice(0, 60));
        } catch (se) { console.error('LSO_SAVEDOC_ERR ' + String(se)); }
      };
    }
  } catch (sdx) { console.error('LSO_SAVEDOC_HOOK_ERR ' + String(sdx)); }

  // ---- 3.8.2 引擎级 -25(EditingError) 拦截：在 asc_onError 分发前吞掉 —— Main.onError
  //      hook 注册时机晚于 sdk 加载期 unhandled-rejection → 弹窗仍出。sendEvent 层拦截
  //      在任何 handler 触达前生效（30_open 的 onError 级重复拦截已于 2026-09-05 移除，
  //      本处为唯一单点）。 ----
  (function _hookSendEv() {
    try {
      // 页门控+重试上限（同 _hookSave；欢迎页空转处理，2026-09-05）
      var _pps = (window.location || {}).pathname || '';
      if (_pps.indexOf('/main/index.html') < 0) { return; }
      var _e = window.Asc && (window.Asc.editor || window.editor);
      if (!_e || !_e.sendEvent) {
        if ((window.__lsoSEWaitN = (window.__lsoSEWaitN || 0) + 1) < 300) setTimeout(_hookSendEv, 200);
        return;
      }
      if (!_e.__seHooked) {
        _e.__seHooked = true;
        var _se = _e.sendEvent;
        _e.sendEvent = function(evt, a1, a2, a3, a4) {
          // 仅拦截 -25（EditingError 弹窗在无服务器链持续误报）；其余原样分发
          if (evt === 'asc_onError' && a1 === -25) {
            return;
          }
          return _se.apply(this, arguments);
        };
        console.error('LSO_SE_HOOKED');
      }
    } catch (nx) {}
  })();

  // ---- 3.7 编辑器页（/main/index.html）web 语义开关：删除 AscDesktopEditor → sdkjs/
  //      webapps 不进入 isDesktopApp 桌面分支（桌面分支把字体 wasm/字体选择表切到
  //      native 通路，g_fonts_selection_bin 类缺失 → Base64.decode(undefined) 崩 →
  //      "打开文件时发生错误"）。桌面语义启用=三条件（native 字体供给 + LoadJS + allfonts
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

