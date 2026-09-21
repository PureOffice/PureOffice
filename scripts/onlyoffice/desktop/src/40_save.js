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
      // ---- 离线单机语义覆写（2026-09-08）：baseEditorsApi.asc_isOffline（apiBase.js:3217）
      //      默认 = protocol=='file' → B 架构 http://localhost 恒 false。官方文件菜单
      //      档位判定（Main.js:1709 isOffline 读取 → FileMenu.js:427-430 公式）需要
      //      true 才能切「桌面离线」档（「另存为」显示/「下载为」恒隐藏）；离线单机
      //      语义本身正确（chat/forcesave/签名等按离线降位）。FileMenu 每次打开菜单
      //      重算（函数体 :425-440），覆写时机在首次打开菜单前即生效。 ----
      try {
        var _p1 = _proto;
        if (typeof _p1.asc_isOffline === 'function' && !_p1.__lsoOffline) {
          _p1.__lsoOffline = true;
          _p1.asc_isOffline = function() { return true; };
          console.error('LSO_ISOFFLINE_HOOKED');
        }
      } catch (skx) { console.error('LSO_ISOFFLINE_ERR ' + String(skx)); }
      // ---- asc_DownloadAs → asc_Save(false, true) 重定向（2026-09-08 另存为）：桌面
      //      官方 Local/api.js:313-318 同款。「另存为」菜单点击的官方链 =
      //      asc_DownloadOrigin（word/api.js:2881）→ asc_DownloadAs(options, fileType=
      //      当前格式)——web 原版 asc_DownloadAs 走 _downloadAsUsingServer（服务器 URL
      //      链）→ B 架构无服务器死路（真机实证：点击另存为无任何 save:as 痕迹）。
      //      重定向到 asc_Save(false, true) → 本 shim 的 isSaveAs 分支 → execCommand
      //      ('save:as') → ArkTS 系统保存框（同格式另存为语义）。isNaturalDownload
      //      保留直通原版（官方语义位；未使用）。cell/slide 的 asc_DownloadAs 同样在
      //      各自 api 原型（同挂点模式）。 ----
      try {
        var _p2 = _proto;
        if (typeof _p2.asc_DownloadAs === 'function' && !_p2.__lsoDlAs) {
          _p2.__lsoDlAs = true;
          if (typeof _p2.asc_DownloadAsNatural !== 'function') {
            _p2.asc_DownloadAsNatural = _p2.asc_DownloadAs;
          }
          _p2.asc_DownloadAs = function(options) {
            if (options && options.isNaturalDownload) {
              return (this.asc_DownloadAsNatural || function() {}).apply(this, arguments);
            }
            console.error('LSO_DLAS_REDIRECT');
            this.asc_Save(false, true, undefined, options);
          };
          console.error('LSO_DLAS_HOOKED');
        }
      } catch (dcx) { console.error('LSO_DLAS_ERR ' + String(dcx)); }
      // ---- 文件菜单档位诊断（2026-09-08 另存为）：官方 FileMenu.js:425-435 显隐公式
      //      输入端 = appOptions 三态（isDesktopApp/isOffline/canDownload/canPrint）。
      //      公式钉死：miSaveAs=(canDownload||canDownloadOrigin)&&isDesktopApp&&isOffline；
      //      miDownload/miSaveCopyAs=...&&(!isDesktopApp||!isOffline)。一次性打点取真机
      //      三态（m7open 自动打开文档时也会产出，无需人点菜单——验收可取证）。 ----
      if (!window.__lsoMenuProbe) {
        window.__lsoMenuProbe = true;
        setTimeout(function() {
          try {
            var _mm = null;
            try { _mm = ((window.DE && window.DE.controllers && window.DE.controllers.Main) || {}).appOptions; } catch (pe) {}
            if (!_mm) { try { _mm = ((window.SSE && window.SSE.controllers && window.SSE.controllers.Main) || {}).appOptions; } catch (pe2) {}
              if (!_mm) { try { _mm = ((window.PE && window.PE.controllers && window.PE.controllers.Main) || {}).appOptions; } catch (pe3) {} } }
            if (!_mm) { console.error('LSO_MENUMODE NOMAIN'); return; }
            console.error('LSO_MENUMODE ' + JSON.stringify({
              isDesktopApp: !!_mm.isDesktopApp, isOffline: !!_mm.isOffline,
              canDownload: !!_mm.canDownload, canDownloadOrigin: !!_mm.canDownloadOrigin,
              canPrint: !!_mm.canPrint, canPreviewPrint: !!_mm.canPreviewPrint,
              saveAsVisible: !!((_mm.canDownload || _mm.canDownloadOrigin) && _mm.isDesktopApp && _mm.isOffline),
              downloadVisible: !!((_mm.canDownload || _mm.canDownloadOrigin) && (!_mm.isDesktopApp || !_mm.isOffline))
            }));
          } catch (mx) { console.error('LSO_MENUMODE_ERR ' + String(mx)); }
        }, 6000);
      }
      if (_proto.__lsoSaveWrap) return; _proto.__lsoSaveWrap = true;
      var _s0 = _proto.asc_Save;
      _proto.asc_Save = function(isNoUserSave, isSaveAs, isResaveAttack, options) {
        var _t = this;
        try {
          // 官方 Local/api.js:158 守卫（省略 History 依赖项）——isSaveAs 分支本段接管
          //（另存为语义=不动源文件，不能走保存回写链）
          if (isResaveAttack === true) { console.error('LSO_SAVE_GUARD resave'); return; }
          // ---- 另存为（官方 Save As 菜单/Ctrl+Shift+S → asc_Save(false, true)）----
          // 与桌面官方语义同构：与保存平行的一条链——序列化当前模型（DOCY，同保存链）
          // → execCommand('save:as') → ArkTS 系统保存框（DocumentViewPicker.save：用户选
          // 位置/文件名）→ 字节落盘 → saveTarget/savePath 身份演进（'none'/'sandbox'→'uri'）
          // + recents 补录。不写回源文件、不弹官方「保存中」UI（异步系统框，引擎状态
          // 不参入）；B 架构另存为=同格式（格式转换「下载为」未支持，菜单已隐藏）。 ----
          if (true === isSaveAs) {
            try {
              var _sbin = window.__lsoNativeSaveEnd(function() { return _t.asc_nativeGetFileData(); });
              if (!_sbin || !_sbin.byteLength) { console.error('LSO_SAVEAS_EMPTY'); return; }
              var _rr = String(window.AscNative && window.AscNative._call('execCommand', ['save:as', window.__lsoB64(_sbin)]) || '');
              console.error('LSO_SAVEAS_CALL len=' + _sbin.byteLength + ' ret=' + _rr);
              return;
            } catch (sax) {
              console.error('LSO_SAVEAS_ERR ' + String(sax));
              return;
            }
          }
          // 新建文档无保存目标（2026-09-05 用户语义确认）：autosave 直接短路——
          // 既不序列化（5MB 空转）也不回写（无 target）；用户保存（!isNoUserSave）
          // 走正常链（无身份 → ArkTS 弹另存为）。目标判定 = save:type 同步询问
          //（EditorPage 单点状态；页面无本地推断——避免两头状态不同步的失效窗口）。
          if (true === isNoUserSave) {
            var _st = 'sandbox';
            try { _st = String(window.AscNative && window.AscNative._call('save:type', []) || 'sandbox'); } catch (stx) {}
            if ('none' === _st) {
              console.error('LSO_AUTOSAVE_SKIP (no save target)');
              return;
            }
          }
          if (true !== isNoUserSave) { this.IsUserSave = true; }
          if (!(this.canSave && !this.isLongAction() && !this.isGroupActions())) {
            console.error('LSO_SAVE_GUARD canSave=' + this.canSave + ' long=' + this.isLongAction()
              + ' group=' + this.isGroupActions());
            return;
          }
          this.canSave = false;
          // 「正在保存」状态栏提示（官方协同语义文案 saveTextText；官方离线单机把
          // 文案置空即静默，这里按用户语义补上）。必须在序列化**之前**让出一帧
          //（setTimeout）——整条保存链是同步的（序列化与 x2t 转换都阻塞页面主线程，
          // 同步桥还阻塞宿主线程），不让出渲染机会提示一帧都出不来（官方原版
          // LongAction 提示在本地链上建立即销毁，同一根因）。autosave 不打扰。
          var _sb = null;
          var _userSave = true === isNoUserSave ? 0 : 1;
          if (0 !== _userSave) {
            try {
              _sb = (window.SSE || window.DE || window.PE);
              _sb = _sb && _sb.controllers && _sb.controllers.Statusbar;
              if (_sb && typeof _sb.setStatusCaption !== 'function') { _sb = null; }
            } catch (sbx) { _sb = null; }
          }
          var _saving = function(on) {
            try { if (_sb) { _sb.setStatusCaption(on ? '正在保存文档...' : '', true, 0); } } catch (scx) {}
          };
          var _t2 = this;
          // 偏差声明（2026-09-05）：askSaveChanges 回调不等待——离线单机同文件覆盖
          // 保存无取消语义；官方 _onSaveCallback（apiBase.js:1657）会复位 canSave，
          // 本适配在序列化完成后自行复位（LSO_NATIVE_SAVE_ERR 路径亦复位）。
          // （在 _saving(true) 之前执行：它内部 sync_StartAction 会以空文案刷一次
          // 状态栏，后调会把提示清掉。）
          if (_t2.CoAuthoringApi && typeof _t2.CoAuthoringApi.askSaveChanges === 'function') {
            _t2.CoAuthoringApi.askSaveChanges(function(e) { _t2._onSaveCallback(e); });
          }
          _saving(true);
          var _runSave = function() {
            try {
              var _nbin = window.__lsoNativeSaveEnd(function() {
                return _t2.asc_nativeGetFileData();
              });
              var _r2 = '';
              if (_nbin && _nbin.byteLength) {
                // 2026-09-05：第三参 = 用户保存标志（isNoUserSave 取反）——引擎桌面语义
                // autosave（打开/变更自动保存，isNoUserSave=true）不触发「最近使用」补录
                //（新建窗口未保存也从列表干净）；用户主动保存（Ctrl+S/保存按钮）才补录。
                _r2 = String(window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_nbin), _userSave]));
                console.error('LSO_NATIVE_SAVE len=' + _nbin.byteLength + ' user=' + _userSave + ' ret=' + _r2);
                // 复位官方「正在保存文档…」状态（2026-09-05 用户反馈：状态栏永久停留——
                // askSaveChanges 建立保存中状态，官方服务器链由 saveDocument 完成回调驱动
                // _onSaveCallback 复位；本地链无完成通道 → 同步落盘返回后直接复位）。
                try {
                  if (typeof _t2._onSaveCallback === 'function') { _t2._onSaveCallback(null); }
                } catch (scx) {}
              } else {
                console.error('LSO_NATIVE_SAVE_EMPTY');
              }
            } catch (nsv) {
              console.error('LSO_NATIVE_SAVE_ERR ' + String(nsv));
              _saving(false);
              _t2.canSave = true;
              return;
            }
            _saving(false);
            _t2.canSave = true;
          };
          if (0 !== _userSave) { setTimeout(_runSave, 50); } else { _runSave(); }
        } catch (gv) {
          console.error('LSO_SAVE_WRAP_ERR ' + String(gv));
          return _s0.apply(this, arguments);
        }
      };
      console.error('LSO_SAVE_HOOKED');
      (window.__lsoShim = window.__lsoShim || []).push('save');  // 自检登记
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
          var _r = window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_u8), 1]); // 用户保存语义（recents 补录，2026-09-05）
          console.error('LSO_SAVEDOC_CALL ret=' + String(_r).slice(0, 60));
          try {
            if (typeof window.editor && window.editor._onSaveCallback === 'function') { window.editor._onSaveCallback(null); }
          } catch (scx2) {}
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

  // ---- 3.7.1 放映全屏通道（2026-09-11，PPT 放映「只在 webview 内播」修复）----
  // 根因（真机 1.6 实证 + 时序日志）：sdkjs 放映引擎只在
  //   `undefined !== window["AscDesktopEditor"]` 时才调 SetFullscreen
  //   （Transitions.js:4075 开始 / :4555 结束）——官方桌面语义里放映全屏是 native 层
  //   的事（web-apps Viewport.js:312 对 isDesktopApp 又显式跳过浏览器 Fullscreen
  //   API，两条路只此一条）。而 3.7 为字体链 web 语义删除了该对象 → 放映时无任何
  //   壳层全屏动作（用户现象：tab 栏与窗口都不动，画面只在 webview 内铺）。
  // 修法=**放映期临时恢复**（web-apps 官方事件驱动；两事件都在 DocumentPreview 的
  //   show/hide 内同步触发——show 早于引擎 StartDemonstration、hide 晚于引擎 End）：
  //     preview:show → window.AscDesktopEditor = window.__lsoAscDE（INSTALL 装配的同份）
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

  // ---- 3.9 头部装饰定制（2026-09-05 用户：编辑器页右上角"用户头像 U + 关闭 X"去掉）----
  // 两元素官方均无**独立**显示开关，故按头部视觉定制在页适配层隐藏：
  //   - #slot-btn-close（Header.js:970/1076 btnClose）：显示条件 = canCloseEditor
  //     （Main.js:504 = customization.close.visible!==false && canRequestClose && !isDesktopApp）
  //     —— 若走官方 close.visible=false 会把"文件菜单→关闭"入口一并关掉（退出只剩
  //     左上角返回箭头），不符合"只去装饰、保留功能"意图。
  //   - .btn-current-user（Header.js:1074 用户头像圈）：官方 else 分支无条件渲染
  //     （guest+canRenameAnonymous 分支是改名按钮，非本场景），无配置可关。
  // 功能入口保留：左上角"返回"箭头（customization.goback → Main.js canBack）与
  // 文件菜单"关闭"。用 MutationObserver 等官方渲染后隐藏（事件驱动，非猜时机），
  // 持续监听防官方 re-render 弹回。
  (function _hideHeaderIcons() {
    try {
      if ((window.location || {}).pathname.indexOf('/main/index.html') < 0) { return; }
      var _hide = function() {
        var _c = document.getElementById('slot-btn-close');
        if (_c) { _c.style.display = 'none'; }
        var _u = document.querySelector('.btn-current-user');
        if (_u) { _u.style.display = 'none'; }
        // 左上 ONLYOFFICE logo：官方 branding 语义（bigger customization.logo.visible）
        // 只在 role=='left' 分支生效——docx 正常，cell/slide 的 customization 传递分支
        // 未达（2026-09-05 真机：xlsx/pptx 左上仍显示 logo）→ #header-logo 隐藏兜底
        // （同 3.9 模式，幂等；docx 已 hidden 再藏无影响；隐藏父 section.logo 防留空位）
        var _l = document.querySelector('#header-logo');
        if (_l && _l.closest) {
          var _ls = _l.closest('section.logo');
          if (_ls) { _ls.style.display = 'none'; }
        }
      };
      var _obs = new MutationObserver(_hide);
      if (document.body) {
        _obs.observe(document.body, {childList: true, subtree: true});
      } else {
        document.addEventListener('DOMContentLoaded', function() {
          _obs.observe(document.body, {childList: true, subtree: true});
        });
      }
      _hide();
      console.error('LSO_HEADER_ICONS_HIDDEN');
    } catch (hx) { console.error('LSO_HDR_HIDE_ERR ' + String(hx)); }
  })();

  // ---- 3.9.1 文件菜单「用模板创建」隐藏（2026-09-08 用户追问重复两条后查明）：桌面档
  //      Desktop.js:579 _extend_menu_file 注入 miNewFromTemplate（#fm-btn-create-fromtpl）
  //      ——点击走模板桥（LocalFileTemplates 离线恒空，无内容）；且该函数每次
  //      Desktop.init（Main.js:536，DI 链接触发）都会 new 注入一次、官方无防重 →
  //      **同 id 菜单项叠两条**（1.8 真机截图「用模板创建」×2 的直接根因）。
  //      与欢迎页「模板」入口隐藏（3.10）同一用户决策：空入口不显示。DOM 层
      //   隐藏（querySelectorAll 清所有重复项），MutationObserver 兜 re-inject。 ----
  (function _hideTplItem() {
    try {
      if ((window.location || {}).pathname.indexOf('/main/index.html') < 0) { return; }
      var _hidTpl = function() {
        try {
          var _els = document.querySelectorAll('#fm-btn-create-fromtpl');
          for (var i = 0; i < _els.length; i++) {
            // remove 而非 display:none：display:none 保留 li 间距（1.0.41 真机截图
            // 「新建」「保存」之间留空）——删除节点才真正无痕
            try {
              var _p = _els[i].parentNode;
              if (_p) { _p.removeChild(_els[i]); }
            } catch (se) {}
          }
        } catch (mh) {}
      };
      var _obsTpl = new MutationObserver(_hidTpl);
      if (document.body) {
        _obsTpl.observe(document.body, {childList: true, subtree: true});
      } else {
        document.addEventListener('DOMContentLoaded', function() {
          _obsTpl.observe(document.body, {childList: true, subtree: true});
        });
      }
      _hidTpl();
      console.error('LSO_TPLITEM_HIDDEN');
    } catch (te) { console.error('LSO_TPLITEM_ERR ' + String(te)); }
  })();

  // ---- 3.8.5 官方 Header X 重定向（未保存关闭守卫，2026-09-09）----
  //     官方链：Header.js:383 btnClose → NotificationCenter 'close' → Main.js:250
  //     closeEditor → onRequestClose（Main.js:693）——asc_isDocumentModified 时弹
  //     Common.UI.warning「放弃修改并离开/取消」**无「保存」项**（官方 web 语义假设
  //     服务器已自动保存；离线单机 autosave=false 此假设不成立，点「确定」即丢数据）。
  //     【UI 可达性实测（2026-09-09 真机）】本壳 targetApp='desktop'（isDesktopApp
  //     =true）→ Header.js:969 canCloseEditor = customization.close.visible &&
  //     canRequestClose && !isDesktopApp 为假 → **btnClose 不渲染**——UI 上无 X；
  //     「文件→退出」同受 Common.Controllers.Desktop.isActive() 门控（isActive=false
  //     → FileMenu.js:505 不注入 fm-btn-exit）——两个官方关闭入口当前 UI 均不可达，
  //     本段与 ArkTS close-request 分支是**未来恢复 web 关闭档时的守卫一致性**（零
  //     风险，UI 不触发即休眠）。当前真实可达关闭入口=tab ×（DocTabHost）+返回键
  //     （onBackPress），均已接守卫。
  //     【修正】覆写 app 主控制器实例的 closeEditor 方法：不再进官方弹框，转而向
  //     ArkTS 上报 editor:event close-request → EditorPage.requestCloseDoc 统一
  //     三按钮守卫（保存/不保存/取消——与 tab ×、文件菜单退出同框）。
  //     三编辑器主控制器全局：**运行时命名空间 = window.SSE/DE/PE.controllers（小写）**
  //     —— 词性关键坑（2026-09-09 实证）：源码写 `<NS>.Controllers.Main`（大写 C），
  //     但打包后挂载在 `<NS>.controllers`（小写——LSO_KICK_SERVERID 链 10_engine
  //     `window.SSE.controllers.Main.api` 真机打点证实为唯一可用句柄；用大写 C 的
  //     hook 空转 60s 静默）。closeEditor 是实例方法（app 初始化后挂载），首次出现
  //     即覆写——重试轮询模式同 _hookSave（offline 页空转可退避，不下死循环）。
  (function _hookCloseEditor() {
    try {
      var _qc = (window.location || {}).pathname || '';
      if (_qc.indexOf('/main/index.html') < 0) { return; }
      var _ns = window.SSE || window.DE || window.PE;
      var _m = _ns && _ns.controllers && _ns.controllers.Main;
      if (!_m || typeof _m.closeEditor !== 'function') {
        if ((window.__lsoCEWaitN = (window.__lsoCEWaitN || 0) + 1) < 300) { setTimeout(_hookCloseEditor, 200); }
        return;
      }
      if (!_m.__lsoCEHooked) {
        _m.__lsoCEHooked = true;
        var _reqClose = function() {
          try {
            console.error('LSO_CLOSE_EDITOR -> close-request');
            // AscNative 空值防御（页面注册于 onInstanceReady——注册前被点则丢弃+日志）
            if (window.AscNative && typeof window.AscNative._call === 'function') {
              window.AscNative._call('execCommand', ['editor:event', JSON.stringify({action: 'close-request'})]);
            } else {
              console.error('LSO_CLOSEREQ_NATIVE_MISSING');
            }
          } catch (e) { console.error('LSO_CLOSEREQ_ERR ' + String(e)); }
        };
        _m.closeEditor = _reqClose;
        console.error('LSO_CE_HOOKED');
      }
    } catch (e) { console.error('LSO_CE_HOOK_ERR ' + String(e)); }
  })();

  // ---- 3.8.6（诊断段，已删——2026-09-09 调查结论固化在 3.8.5 注释与 EditorPage
  //      requestCloseDoc 注释：接口句柄=window.<NS>.controllers.Main.api（小写
  //      controllers）、查询 API=asc_isDocumentCanSave（三引擎均有）、ArkWeb
  //      runJavaScript 返回值 JSON 编码、saveAborted 修复 canSave 复位缝隙）

