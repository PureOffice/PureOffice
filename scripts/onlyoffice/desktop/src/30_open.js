    // ---- 3.55 M7 自动化验收工具（?m7auto=1 时编辑器就绪后自动插入文本并序列化保存；
    //      ?m7open=<name> 时欢迎页自动 open:recent 对应沙箱文件 —— 用于真机自动化验证
    //      打开/保存链（uitest 无法向 contenteditable 输字、无法注入系统 picker 列表交互）。
    //      产品路径不拼该参数 → 不生效；2026-09-04 已验证 docx：M7AUTO-EDIT-OK 进 save.docx
    //      word/document.xml，xlsx/pptx 同段（asc_PasteData Text=1 引擎常量） ----
    if (/[?&]m7auto=1(&|$)/.test(window.location.search) && !window.__m7auto) {
      window.__m7auto = true;
      (function() {
        var _n = 0;
        var _getApi = function() {
          // 优先 Main.api（asc_docs_api/spreadsheet_api/presentation_api 实例真实挂点；
          // word 经 Asc.editor 同物，cell 的 Asc.editor 不保证是 spreadsheet_api）
          try {
            var _p = window.location.pathname || '';
            var _ns = _p.indexOf('/spreadsheeteditor/') >= 0 ? 'SSE'
              : _p.indexOf('/presentationeditor/') >= 0 ? 'PE' : 'DE';
            var _m = window[_ns] && window[_ns].controllers && window[_ns].controllers.Main;
            if (_m && _m.api) { return _m.api; }
          } catch (x) {}
          var _e2 = window.Asc && window.Asc.editor ? window.Asc.editor : window.editor;
          if (_e2 && typeof _e2 === 'object') { return _e2; }
          return null;
        };
        var _doSave = function() {
          // 直接序列化（等同 asc_Save 覆写后半程；绕开守卫的 isLongAction —— 文档加载
          // 长事务不结束（模型已就绪可读可写），守卫式保存永远打不穿）。
          // 事件到达（asc_onDocumentContentReady）即加载终了 → 不再延时（旧 2500ms 是
          // 配合轮询判据的缓冲，事件语义下不需要）。
          try {
            var _ap2 = _getApi();
            // 与 40_save 共用 __lsoNativeSaveEnd（临时挂 Native.Save_End 换挂逻辑的单一点；
            // 2026-09-05 审查：原内联换成 window.native 与其重复）
            var _nb2 = window.__lsoNativeSaveEnd(function() {
              return _ap2.asc_nativeGetFileData();
            });
            if (_nb2 && _nb2.byteLength) {
              var _rr = String(window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_nb2)]));
              console.error('M7AUTO_DIRECT_SAVE len=' + _nb2.byteLength + ' ret=' + _rr);
            } else {
              console.error('M7AUTO_DIRECT_EMPTY');
            }
          } catch (x) { console.error('M7AUTO_DIRECT_ERR ' + String(x)); }
        };
        var _onDocReady = function() {
          try {
            var _ap = _getApi();
            // 官方事件 asc_onDocumentContentReady（apiBase.js:1519）已证文档加载完成
            // （=旧轮询判据 private_GetLogicDocument/wbModel 的等价且更权威时机）
            var _ftq = (String(window.location.search).match(/[?&]fileType=([^&]+)/) || [])[1] || 'docx';
            var _insOk = false;
            if (_ftq === 'docx' && _ap && typeof _ap.asc_AddText === 'function') {
              // docx：插入文本+保存（验证编辑内容进保存产物）
              _ap.asc_AddText('M7AUTO-EDIT-OK', null);
              _insOk = true;
            }
            // cell/slide（_ftq !== 'docx'）：不插入 —— asc_PasteData 需要 WorkbookView(wb，
            // GUI 懒建，v13 已知 toolbar 未 init) —— 直接序列化"已打开模型"（未修改同样产出
            // 完整文件，验证 xlst_bin2xlsx/pptt_bin2pptx 落盘链）
            if (_insOk) {
              console.error('M7AUTO_INSERTED ft=' + _ftq);
              _doSave();
              return;
            }
            console.error('M7AUTO_SAVE_DIRECT ft=' + _ftq);
            _doSave();
          } catch (x) { console.error('M7AUTO_ACCEPT_ERR ' + String(x)); }
        };
        var _reg = function() {
          var _ap = _getApi();
          // 等 API 对象就绪（等对象而非等模型/界面元素——官方 api 出现于 onLaunch 完成）
          if (!_ap || typeof _ap.asc_registerCallback !== 'function') { setTimeout(_reg, 300); return; }
          try {
            _ap.asc_registerCallback('asc_onDocumentContentReady', function() {
              console.error('M7AUTO_DOC_READY');
              _onDocReady();
            });
          } catch (e) { console.error('M7AUTO_REG_ERR ' + String(e)); }
        };
        setTimeout(_reg, 1200);
      })();
    }

    // ---- 3.55b 欢迎页 m7open 验收段：?m7open=<name>（如 m7-open-test.docx / sample.xlsx）——
    //      欢迎页面加载就绪后自动发官方 open:recent（路径 = 沙箱 filesDir/<name>），等价
    //      「打开本地文件 → 用户点选该文件」；与 3.55 m7auto 配套做全自动开关验收链。
    //      门控：URL 带 m7open 参数才触发（产品 URL 无此参数 = 零代价）——M7OPEN_COND 打点
    //      仅在参数存在时输出（2026-09-05：原无条件打点改为参数内）。 ----
    if (/[?&]m7open=([^&]+)/.test(window.location.search) && !window.__m7open) {
      var _m7f = (String(window.location.search).match(/[?&]m7open=([^&]+)/) || [])[1];
      _m7f = decodeURIComponent(_m7f);
      window.__m7open = true;
      try { console.error('M7OPEN_COND search=' + window.location.search + ' sdk=' + typeof (window.sdk && window.sdk.command) + ' asc=' + !!window.AscNative); } catch (cb) {}
      (function() {
        var _t2 = 0;
        var _try2 = function() {
          try {
            if (window.sdk && window.sdk.command && window.AscNative && window.AscNative._call) {
              var _fd2 = String(window.AscNative._call('getFilesDir', []) || '');
              // 扩展名取末段（文件名可含多点）
              var _ext2 = (_m7f.match(/\.([a-z0-9]+)$/i) || [])[1] || 'docx';
              var _type2 = _ext2 === 'xlsx' ? 0x101 : _ext2 === 'pptx' ? 0x81 : 0x41;
              window.sdk.command('open:recent', JSON.stringify({
                id: 99, name: _m7f, path: _fd2 + '/' + _m7f, type: _type2
              }));
              console.error('M7OPEN_SENT name=' + _m7f + ' path=' + _fd2 + '/' + _m7f);
              return;
            }
          } catch (x) { console.error('M7OPEN_ERR ' + String(x)); }
          // 窗口说明（2026-09-04 回退）：loginpage 正常 1-2s 就绪（实测），20×600ms=12s 足够；
          // 曾放大至 250 次（150s）拖延主线程加重白屏——已回退。
          if (++_t2 < 20) { setTimeout(_try2, 600); }
          else { console.error('M7OPEN_TIMEOUT'); }
        };
        setTimeout(_try2, 1300);
      })();
    }

    // ---- 3.6 字体链修复（历史注记，2026-09-05 审查）：官方 shim loadLocalFile 请求
    //      ascdesktop://fonts/（CEF 拦截），ArkWeb 无此 scheme，XHR 永远 pending →
    //      字体回调 null → BIN 读取 undefined.length 崩；原修复改经
    //      http://localhost/onlyoffice/fonts/（rawfileLoader 提供已 pre_xor 字体）。
    //      当前在编辑器页 3.7 段删除 window.AscDesktopEditor（web 语义），且 sdkjs 唯一
    //      调用点 cell/api.js:616 自身以 if (window["AscDesktopEditor"]) 门控 → **本段在
    //      编辑器页永不执行**（字体实际走 web 链 Externals.js LoadFontArrayBuffer XHR，同 URL）。
    //      保留以备桌面语义启用；如确认桌面色态启用请同步 3.7 门控。 ----
    window.AscDesktopEditor.loadLocalFile = function(url, callback, start, len) {
      try {
        var loadUrl = url;
        if (start !== undefined) loadUrl += ('__ascdesktopeditor__param__' + start);
        if (len !== undefined) {
          if (undefined === start) loadUrl += '__ascdesktopeditor__param__0';
          loadUrl += ('__ascdesktopeditor__param__' + len);
        }
        var _xh = new XMLHttpRequest();
        _xh.open('GET', 'http://localhost/onlyoffice/fonts/' + loadUrl, true);
        _xh.responseType = 'arraybuffer';
        _xh.onload = function() {
          try { callback(new Uint8Array(_xh.response)); } catch (x) { callback(null); }
        };
        _xh.onerror = function() { callback(null); };
        _xh.send(null);
      } catch (x) { callback(null); }
    };

    // ---- 3.4 顶层编辑器页模拟官方 api.js _onAppReady（无 api/documents 壳时）：
    //      init(editorConfig) → Gateway loadConfig；opendocument(_offline_) → loadDocument
    //      → asc_LoadDocument(loadSdk→isLoadFullApi) → onEndLoadDocInfo → _openEmptyDocument
    //      → 空模型建立（web 构建无 Local 截胡，openDocument 正常执行）。此后 waitFull
    //      在 isLoadFullApi 后发 LocalStartOpen → 壳注入真实字节。与 api.js:463-468 相同。
    try {
      var _pn = window.location && window.location.pathname || '';
      if (_pn.indexOf('/main/index.html') >= 0) {
        var _sendInit = function() {
          try {
            // 文档类型取自 URL（EditorPage.editorUrl 带 fileType=xlsx/pptx/docx）：
            // docInfo.put_Format(fileType) 必须与二进制签名一致（XLSY→xlsx 等），
            // 否则 onEndLoadFile 的 editorId 校验会拒绝（"打开文件错误"）。
            var _ftq = (window.location.search || '').match(/[?&]fileType=([^&]+)/);
            var _ft = _ftq ? decodeURIComponent(_ftq[1]) : 'docx';
            // 标题取自 URL（EditorPage.editorUrl 带 title=Unnamed.xxx）；缺省 'sample'
            // 兜底（POC 遗留默认值，未传 title 时保持旧行为）
            var _tq = (window.location.search || '').match(/[?&]title=([^&]+)/);
            var _title = _tq ? decodeURIComponent(_tq[1]) : 'sample';
            var _dt = _ft === 'xlsx' ? 'cell' : _ft === 'pptx' ? 'slide' : 'word';
            var _cfg = {
              documentType: _dt,
              width: '100%', height: '100%',
              editorConfig: {
                mode: 'edit', lang: 'zh-CN', createUrl: 'desktop://create.new',
                user: {id: 'uid-1', name: 'User'},
                // 保存链开关：docInfo.put_SupportsOnSaveDocument(true) →
                // asc_Save → checkSaveDocumentEvent → saveLogicDocumentToZip →
                // sendEvent('asc_onSaveDocument', DOCX bytes) → Main.onSaveDocumentBinary
                // → Common.Gateway.saveDocument(data)（无服务器环境由 ascshim 覆写落盘）
                canSaveDocumentToBinary: true,
                // 「关闭」官方 web 链（M5 补丁，方案 C）：Main.js:504
                //   canCloseEditor = customization.close.visible!==false && canRequestClose && !isDesktopApp
                //   → FileMenu.js:542 web 分支注入「关闭」菜单项(action:'close-editor')
                //   → LeftMenu.js:309 'close' → Main.js:1025 closeEditor → onRequestClose
                //   → Gateway.requestClose()（ascshim 已覆写回欢迎页）
                canRequestClose: true,
                customization: {
                  about: false, feedback: {url: 'https://helpdesk.onlyoffice.com/?desktop=true'},
                  // web 语义"关闭/返回"：Main.js canBack = customization.goback.url 非空
                  // → 头部/文件菜单"返回"按钮 → goback → parent.location.href = url
                  //（web 编辑器层唯一的官方回欢迎页机制；Desktop 菜单"关闭文件"项待桌面
                  //  字体/native 通路三项补齐后再启用 isDesktopApp）。
                  goback: {url: 'http://localhost/onlyoffice/index.html'},
                  close: {visible: true, text: '关闭'}
                }
              },
              document: {
                key: 'k' + Date.now(), url: '_offline_', title: _title, fileType: _ft,
                permissions: {edit: true, download: true}
              }
            };
            var _k = ('' + _cfg.document.key + Math.random().toString(16).substring(2)).replace(/[^0-9a-f]/g, '');
            // key 以 '1' 开头（首字符 '0' 时为 0x 前缀语义接 1；非 '0' 原样保留——
            // 2026-09-05 审查修复：原实现非 '0' 时丢弃首字符）
            _cfg.document.key = _k.charAt(0) === '0' ? '1' + _k.substring(1) : _k;
            // 与官方 api.js _onAppReady 相同：_init(_config.editorConfig)（内层 editorConfig，
            // 不是 DocsAPI 顶层配置！Main.js loadConfig $.extend(editorConfig, data.config) 直接
            // 取顶层 customization/user 等 → 传 _cfg 会 undefined）。
            // 调用 = 官方 Gateway trigger('init', {config}) → handler(data) 同构（直调官方实例，
            // 绕开 postMessage 时序：首次 700ms 时 app.js(require 全部 controller) 往往未就绪，
            // Gateway.on('init') 未注册 → 消息静默丢失 → DocInfo 永空 → 空模型/真文档均不打开）。
            var _m = window[_ns] && window[_ns].controllers && window[_ns].controllers.Main;
            if (_m && typeof _m.loadConfig === 'function' && typeof _m.loadDocument === 'function') {
              // cell onLaunch 有机会在 editorConfig 初始化前中断（asc_setDefaultBlitMode
              // 等 sdk 调用异常）→ loadConfig 里 fillUserInfo(editorConfig.user...) 崩
              // 'lang'。预制默认空对象使 loadConfig 可执行（$.extend 后即填全）。
              _m.editorConfig = _m.editorConfig || {};
              _m.appOptions = _m.appOptions || {};
              // -25(EditingError) 拦截已在 40_save.js 的 sendEvent 层完成（更早生效，
              // 任何 handler 触达前吞掉；本处 onError 级拦截与它重复，2026-09-05 移除）
              try {
                _m.loadConfig({config: _cfg.editorConfig});
                console.error('LSO_LC_OK ec=' + (typeof _m.editorConfig) + ' lang=' + ((_m.editorConfig || {}).lang)
                  + ' cfgLang=' + _cfg.editorConfig.lang + ' user=' + (typeof _m.appOptions.user));
                // 全 controller init 补齐（2026-09-04，.lang 级联崩溃根因）：3.4 只直调
                // Main.loadConfig，Gateway('init') 从未触发 → 其他 controller 的 init 链
                // （Gateway.on('init') 注册，如 FormulaDialog.js:174 loadConfig）全部饿死 →
                // FormulaDialog.appOptions 未初始化 → applyModeCommonElements → FormulaDialog.
                // setApi 内 appOptions.lang 读崩（"reading 'lang'"）。Gateway.trigger 非公开
                // API（Gateway.js 无 trigger 暴露）→ 遍历 controller 表补发 loadConfig
                // （官方 init 协议对每 controller 同构；Main 二次调用幂等）。
                // 命名空间按页面取（window[_ns].controllers——原硬编码 SSE 只覆盖 cell，
                // word/slide 打误导 N=0，2026-09-05 审查修复）。
                try {
                  var _app2 = _m.getApplication();
                  var _nInit = 0;
                  for (var cName in (window[_ns] && window[_ns].controllers || {})) {
                    try {
                      var _ci = _app2.getController(cName);
                      if (_ci && typeof _ci.loadConfig === 'function') {
                        _ci.loadConfig({config: _cfg.editorConfig});
                        _nInit++;
                      }
                    } catch (cc) {}
                  }
                  console.error('LSO_INIT_ALL_OK n=' + _nInit);
                } catch (iax) { console.error('LSO_INIT_ALL_ERR ' + String(iax)); }
              } catch (le) {
                console.error('LSO_LC_ERR ' + String(le));
              }
              if (_dt === 'word') {
                // 官方 loadDocument（word 已实机验证可用；cell/slide 会崩 'lang' —— 见下）
                _m.loadDocument({doc: _cfg.document});
                console.error('LSO_LD_OK');
              } else {
                // cell/slide：官方 loadDocument 在无服务器环境崩（'reading lang'，细节未知），
                // 但 DI 链（官方 asc_CDocInfo 字段装配 + asc_setDocInfo + asc_getEditorPermissions）
                // 实测可用——等价 loadDocument 的前半段（DocInfo 装配/权限），
                // 保证 onEndLoadDocInfo → 空模型/打开链正常继续。
                if (!window.__lsoDIUsed) {
                  window.__lsoDIUsed = true;
                  var _ui = new Asc.asc_CUserInfo();
                  var _uopt = _m.appOptions.user || {};
                  _ui.put_Id(_uopt.id || 'uid-1');
                  _ui.put_FullName(_uopt.fullname || 'User');
                  _ui.put_IsAnonymousUser(!!_uopt.anonymous);
                  var _di2 = new Asc.asc_CDocInfo();
                  _di2.put_Id(_cfg.document.key);
                  _di2.put_Url(_cfg.document.url);
                  _di2.put_Title(_cfg.document.title);
                  _di2.put_Format(_cfg.document.fileType);
                  _di2.put_Options({});
                  _di2.put_UserInfo(_ui);
                  _di2.put_Permissions(_cfg.document.permissions);
                  _di2.put_CallbackUrl('');
                  _di2.put_Lang('zh-CN');
                  _di2.put_Mode('edit');
                  _di2.put_CoEditingMode('fast');
                  // CDocsCoApi 离线 dummy 补丁（2026-09-04）：auth 离线分支（docscoapi.js:187
                  // this.onFirstLoadChangesEnd()）在无服务器链必达；该方法本是外部注入
                  // （服务器联机链由 CoAuthoringApi.onFirstLoadChangesEnd 呼应），我们的组合
                  // 下缺失 → auth 报 "this.onFirstLoadChangesEnd is not a function"。
                  // serverId 完成已由 Gateway 踢闸覆盖（asyncServerIdEndLoaded），此处
                  // dummy 与官方 web 语义等价。**必须在 asc_setDocInfo/权限分发之前执行**
                  //（CDocsCoApi.auth 由引擎链触发，晚补无效）。
                  try {
                    var _cda = window.AscCommon && window.AscCommon.CDocsCoApi;
                    if (_cda && _cda.prototype
                      && typeof _cda.prototype.onFirstLoadChangesEnd !== 'function') {
                      _cda.prototype.onFirstLoadChangesEnd = function() {};
                      console.error('LSO_CDA_FLC_PATCHED');
                    }
                  } catch (cda) { console.error('LSO_CDA_ERR ' + String(cda)); }
                  _m.api.asc_setDocInfo(_di2);
                  // 权限链三刀（工具栏/文档 holder 的 mode 电源，2026-09-04）：
                  // ① Main.permissions（loadDocument Main.js:571-575 同义）；
                  // ② asc_getEditorPermissions 引擎回调（asc_onGetEditorPermissions）只在
                  //    服务器 license 回调（CoAuthoringApi.onLicense → isOnLoadLicense）后
                  //    发送——**无服务器链永不发送** → 注册回调也触发不了；
                  // ③ = 直接构造 asc_CAscEditorPermissions（Success 许可 + Edit 权限，
                  //    页面版本一致避开 onServerVersion 版本弹窗）+ onEditorPermissions.call
                  //    （→ applyModeCommonElements 1545 → Toolbar.setMode/DocumentHolder.setMode
                  //    1645/1649 —— 文档/工具栏 isEdit 等全在此链分发）。
                  // 历史症状：未设权限+引擎不发 → #toolbar 空、DocumentHolder
                  // this.permissions.isEdit 崩（code.js:15325）。
                  // slide onEditorPermissions 1412 读 this.document.info（canFavorite），官方
                  // loadDocument:501 this.document = data.doc 供之；DI 链须同构设置——不设 →
                  // pptx 权限分发崩 TypeError reading 'info' → 尾段 asc_LoadDocument 跳过 →
                  // 编辑器空白（cell 读 appOptions.spreadsheet.info、word 走 loadDocument，
                  // 二者无此问题）。
                  _m.document = _cfg.document;
                  _m.appOptions.spreadsheet = _cfg.document;
                  _m.permissions = {};
                  if (_cfg.document && _cfg.document.permissions) {
                    _m.permissions = window['_'] ? window['_'].extend(_m.permissions, _cfg.document.permissions)
                      : (function (t) { for (var k in _cfg.document.permissions) { t[k] = _cfg.document.permissions[k]; } return t; })(_m.permissions);
                  }
                  try {
                    if (typeof _m.onEditorPermissions === 'function'
                      && window.AscCommon && window.AscCommon.asc_CAscEditorPermissions) {
                      var _pageVer = '4.3.0';
                      try {
                        var _lm = _m.getApplication().getController('LeftMenu');
                        var _av = _lm && _lm.leftMenu && _lm.leftMenu.getMenu('about')
                          && _lm.leftMenu.getMenu('about').txtVersionNum;
                        var _mv = String(_av || '').match(/^(\d+\.\d+\.\d+)/);
                        if (_mv) { _pageVer = _mv[1]; }
                      } catch (vb) {}
                      var _perm = new window.AscCommon.asc_CAscEditorPermissions();
                      _perm.setLicenseType(window.Asc.c_oLicenseResult.Success);
                      _perm.setRights(window.Asc.c_oRights.Edit);
                      _perm.setIsLight(false);
                      _perm.setBuildVersion(_pageVer);
                      // （2026-09-05 稳定化：原 PERM_ENTER 探针 wrap 移除——诊断打点，
                      //  定位工作已完成；权限分发异常现在由页面 console 直接可见）
                      _m.onEditorPermissions.call(_m, _perm);
                      console.error('LSO_PERM_DISPATCH_OK ver=' + _pageVer);
                    } else {
                      console.error('LSO_PERM_DISPATCH_NOSUPPORT');
                    }
                  } catch (de) { console.error('LSO_PERM_DISPATCH_ERR ' + String(de)); }
                  _m.api.asc_getEditorPermissions();
                  console.error('LSO_DIOPEN_OK url=' + _di2.get_Url() + ' perms=' + (typeof _m.permissions));
                }
              }
              console.error('LSO_DIRECT_INIT DONE key=' + _cfg.document.key + ' type=' + _cfg.documentType);
            } else {
              console.error('LSO_DIRECT_INIT main-not-ready (' + (typeof _m) + ')');
            }
          } catch (ix) {
            console.error('LSO_INIT_ERR ' + String(ix) + (ix && ix.stack ? ' | ' + ix.stack.slice(0, 1200) : ''));
          }
        };
        // 应用命名空间随编辑器而异：DE(document)/SSE(spreadsheet)/PE(presentation)，
        // 不能用 window.DE（cell 页 DE=undefined → Main 永远找不到 → 不开文档）
        var _ns = (window.location.pathname || '').indexOf('/spreadsheeteditor/') >= 0 ? 'SSE'
          : (window.location.pathname || '').indexOf('/presentationeditor/') >= 0 ? 'PE' : 'DE';
        var _lsoInitTries = 0;
        (function _lsoInitLoop() {
          var _o = window[_ns];
          var _mr2 = _o && _o.controllers && _o.controllers.Main;
          // 就绪信号 = Main 实例 + api（Viewport.getApi，onLaunch 已完成）：
          // 只判方法名字（loadConfig 属性恒存在于 Backbone controller）会在 onLaunch 中段
          // 触发 → editorConfig 未初始化 → loadConfig 内 'lang' 崩。
          if (_mr2 && _mr2.api && typeof _mr2.loadConfig === 'function' && typeof _mr2.loadDocument === 'function') {
            if (!window.__lsoInitSent) {
              window.__lsoInitSent = true;
              _sendInit();
            }
          } else if (++_lsoInitTries < 120) {
            setTimeout(_lsoInitLoop, 500);
          }
        })();
      }
    } catch (nix) {}


    // ---- 3.9（已移除，2026-09-05 稳定化）：插件装配时序包装。官方 web 链本就保证
    //      「文档加载完成 → 装配插件」：onDocumentContentReady（Main.js:1298）→ app:ready
    //      → pluginsController.setApi(Main.js:1463) → loadPlugins → asc_pluginsRegister
    //      （Plugins.js:259）；官方另有 preSetupPlugins 延迟补发（apiBase.js:3662）。
    //      「1500/4000ms + loading-mask 消失 + 30s 超时」的包装属于重复且不可靠的
    //      权宜实现，删除。若再遇插件装配与文档打开的异常：不回加包装，先用官方事件
    //      （asc_registerCallback('asc_onDocumentContentReady'/'asc_onPluginShow')）打点取证。

    // ---- 3.10（已撤回，2026-09-05 用户决策：专注基础功能）：AI 插件 provider 预配置
    //      （localStorage onlyoffice_ai_plugin_storage_key + ai-mock 端点）与 3.11 AI 按钮
    //      点击诊断一起撤除。AI 后续启用时：恢复该段 + build_editors_ohos.py 的 AI 插件
    //      安装步骤 + EditorPage smoke 的 AI 探针（git 历史可查）。

    // ---- 3.11（已撤回，见 3.10 说明）。
