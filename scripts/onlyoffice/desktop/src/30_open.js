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
            // 标题取自 URL（EditorPage.editorUrl 带 title=<语言包词条>.ext，新建时
            //   = 官方「未命名的文档/电子表格/演示」+扩展名）；缺省 'sample' 兜底
            //   （POC 遗留默认值，未传 title 时保持旧行为）
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
                // 隐藏「打开文件所在位置」菜单项与头部返回按钮（2026-09-07 用户：
                // 无文件管理器语义，点击只会被导航回欢迎页，暂去掉）。官方语义
                // Main.js:493-506：editorConfig.canBackToFolder!==false 才允许返回
                // → 置 false 后 canBack=false → FileMenu.js:463 miBack hide +
                // Header.setCanBack(false)（头部返回按钮同隐）；「文件→关闭」退出链
                // 由 canRequestClose/close 控制，不受影响。要恢复时删除此行即可。
                canBackToFolder: false,
                customization: {
                  // about 与反馈入口：左菜单「支持」(tipSupport 'Feedback & Support') 渲染
                  // 条件 = feedback.url 非空（LeftMenu.js:117）——离线单机无 helpdesk 语义，
                  // 2026-09-05 用户：隐藏（无用）。about:false 同（官方语义）。
                  about: false, feedback: false,
                  // 文件菜单「帮助」（Main.js:1759 canHelp=help!==false）与「提出功能建议」
                  //（Main.js:1766 canSuggest=suggestFeature!==false）——离线单机无 docs/
                  // 功能建议服务，2026-09-05 用户：去掉（官方语义开关，非 UI hack）。
                  help: false, suggestFeature: false,
                  // web 语义"关闭/返回"：Main.js canBack = customization.goback.url 非空
                  // → 头部/文件菜单"返回"按钮 → goback → parent.location.href = url
                  //（web 编辑器层唯一的官方回欢迎页机制；Desktop 菜单"关闭文件"项待桌面
                  //  字体/native 通路三项补齐后再启用 isDesktopApp）。
                  // 欢迎页语言=URL lang 参数（loginpage utils.js:547 getUrlParams 默认
                  // {lang:'en'}）——与 EditorPage.homeUrl 同参，否则关闭后欢迎页回英文。
                  goback: {url: 'http://localhost/onlyoffice/index.html?lang=zh-CN'},
                  // 隐藏头部左上角 ONLYOFFICE logo：官方 branding 语义
                  // Header.js:798 this.branding = this.options.customization；
                  // :886-888 branding.logo.visible===false → #header-logo.addClass('hidden')
                  logo: {visible: false},
                  close: {visible: true, text: '关闭'},
                  // 关闭自动保存（2026-09-05 用户：桌面使用习惯=用户主动保存，不应
                  // "有修改就自动保存"——autosave 是 Web 服务器版语义；桌面版无）。
                  // 官方语义：ReviewChanges.js:897 customization.autosave===false →
                  // settings-autosave 初始 0（仅 localStorage 无缓存时）。
                  autosave: false
                },
                // B 架构 UI 档位 = 官方「桌面离线」档（Main.js:445）：isDesktopApp=true
                // 后文件菜单「另存为」显示（FileMenu.js:430 公式），「下载为」「另存为
                // 副本」恒隐藏（FileMenu.js:427/:429 的 !isDesktopApp 为假）——「下载为」
                // 不再靠 permissions.download 隐藏（档位公式天然实现）。
                // 注意：仅 UI 档位——引擎桌面分支依赖 window.AscDesktopEditor/Common
                // Controllers.Desktop.isActive()（20_bridge 3.7 已 delete），均未触发，
                // 引擎仍 web 语义；canCloseEditor（:504 !isDesktopApp 分支）随之置 false，
                // 无碍（关闭链由 canRequestClose/goback 承担）。
                targetApp: 'desktop'
              },
              document: {
                key: 'k' + Date.now(), url: '_offline_', title: _title, fileType: _ft,
                // download=false：官方 canDownload=permissions.download!==false（Main.js:1764）
                // → 「下载为/下载原文件」菜单项隐藏（LeftMenu.js:879 显隐条件）——B 架构
                // 无 C++/CEF 下载落地面，且转换链 PDF/HTML/图片依赖 doctrenderer JS 引擎
                // （OHOS 无 V8）不可用（2026-09-08 用户决策：下载为暂不要；**必须显式
                // false**，undefined 也判 true）。不影响保存链（asc_Save 独立）与另存为。
                // 权限位（2026-09-08 定案）：
                //  download:true —— 官方面板显隐不靠它：B 架构切「桌面离线」档
                //   （targetApp:'desktop' + asc_isOffline→true）后「下载为/另存为副本」
                //    恒隐藏（FileMenu.js:427/:429 的 !isDesktopApp 为假），「另存为」
                //    恒显示（:430 公式）——download 位留 true（canSaveToFile 等
                //    连带依赖；c6a6324 曾靠 download:false 隐藏下载为，今被档位替代）。
                //  print:false —— canPrint=permissions.print!==false（Main.js:1735）→
                //    false：文件菜单「打印/打印预览」两项全隐（FileMenu.js:433/:434），
                //    B 架构无打印（引擎 asc_Print 需 C++ 落地/doctrenderer V8 缺失，
                //    2026-09-08 用户决策）。
                permissions: {edit: true, download: true, print: false}
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
              // 2026-09-06 根因（History 假帧）：官方 loadDocument → onEndLoadDocInfo →
              // _openEmptyDocument（apiBase.js:1429）→ AscCommon.getEmpty()（word/document/editor.js:41
              // "DOCY;v2;50190;…" 内置 History 范文，base64 编码——此前"全文搜无"的根因）装载
              // 范文并渲染 7 页；真字节 ReplaceContent 后绘制层范文帧残留 → 用户所见「History」。
              // 官方 Desktop 语义 = 不打开空文档（sdkjs/common/Local/common.js:40-64「非 iframe
              // 编辑器不打开空文档」，等待 LocalStartOpen 注入真字节）。对齐：三格式统一走
              // DI 链（asc_setDocInfo+权限分发——loadDocument 的公因子，cell/slide 已验证；
              // DI 链无 _openEmptyDocument 路径，首帧=真文档）。cell/slide 官方 loadDocument
              // 在无服务器环境崩（'reading lang'），DI 链实测可用——等价 loadDocument 前半段
              // （DocInfo 装配/权限），保证 onEndLoadDocInfo → 空模型/打开链正常继续。
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
                      // isLight=true = 官方「light 无协同单机」语义（2026-09-08 定案）——
                      // 原 setIsLight(false) 是 M3 许可降级链产物，导致 asc_getIsLight()
                      // =false → Main.js:1707 canCoAuthoring=!isLight=true → 页面按「在线
                      // 协同」走 loadCoAuthSettings：fastCoauth=true「快速」预选+协作段
                      // 显示、尾段 autosave 公式短路到 canCoAuthoring→1 → 设置面板「自动
                      // 保存」误勾选（customization.autosave=false / 00_boot 预写'0' 均
                      // 被公式架空）。true 后：canCoAuthoring=false → loadCoAuthSettings
                      // 单机分支（fastCoauth=false, autosave=0）；Main.js:1787 light 分支
                      // 禁 History/Review/Chat——本地单机本无这些（无服务器），正合。
                      _perm.setIsLight(true);
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
              console.error('LSO_DIRECT_INIT DONE key=' + _cfg.document.key + ' type=' + _cfg.documentType);
            } else {
              console.error('LSO_DIRECT_INIT main-not-ready (' + (typeof _m) + ')');
            }
          } catch (ix) {
            console.error('LSO_INIT_ERR ' + String(ix) + (ix && ix.stack ? ' | ' + ix.stack.slice(0, 1200) : ''));
          }
          // ---- 3.6 AI 插件 backgroundBtn 缺失修复（2026-09-06 真机根因修复） ----
          // 现象：插件 tab 不显示（addTab 模板 display:none 保持）。真机取证（诊断
          // wrap mergePlugins/parsePlugins 抓 PLUG_WRAP_ERR 后即撤，仅留证据）：
          // PLUG_WRAP_ERR parsePlugins TypeError: Cannot read properties of
          // undefined (reading 'show')——官方装配链 mergePlugins → parsePlugins →
          // pluginStore.reset() 同步触发 onResetPlugins（Plugins.js:418）：
          // AI 插件 variation type=background → isBackgroundPlugin=true → :445-447
          // 直接 push backgroundPlugins 并 return（**不走 :470 rank===0/2 分支**）；
          // 而 :485 循环后 `if (me.backgroundPlugins.length > 0)
          // me.viewPlugins.backgroundBtn.show()`——backgroundBtn 只在
          // addBackgroundPluginsButton（:285，调用点 :470/:447 rank 分支）创建；
          // store 仅此一个插件（unpack 只带 AI，server 环境常驻常规插件才有 rank
          // 分支兜底创建）→ 从未创建 → undefined.show() TypeError → 异常向上冒泡
          // mergePlugins → getPlugins().then 的 .catch 吞掉
          // （serverPlugins.plugins=false）→ 链断点靠前，refreshPluginsList 的
          // asc_pluginsRegister/trigger('tab:visible')/Gateway.pluginsReady 全未走到
          // → 插件 tab 保持 addTab 模板 display:none（10s 快照 PROF_PLUG_TAB
          // liDisplay=none 实证）。
          // 修复：catch 中断后按官方 :484-501 语义补齐——补建 backgroundSlot 按钮
          // （addBackgroundPluginsButton 幂等：重复创建时 viewPlugins.backgroundBtn
          // 由后续 rank 分支覆盖，多余空 group 无 UI 副作用）+ show:before/click
          // 绑定 + isTabActive 面板复位 + lockControls（docProtection 为只读态）。
          // 非白名单：不看 GUID/target，按「backgroundPlugins 非空且按钮缺失即补建」
          // 的正规化恢复逻辑实现。
          // wrap 对象必须是 parsePlugins（原型调用链 wc7 已证）：onResetPlugins 经
          // initialize 时 addListeners 的 bind 保存引用（Plugins.js:110-111），事后
          // 替换原型/实例属性都截不到绑定过的快照；parsePlugins 是运行时
          // this.parsePlugins 查原型——wrap 有效（2026-09-06 真机实证：上版 wrap
          // onResetPlugins 后 PLUG_BG_FIXED 从未触发，parsePlugins wrap 版
          // 一步抓到 PLUG_WRAP_ERR）。
          (function ensureBgBtn() {
            try {
              var _P = window.Common && window.Common.Controllers && window.Common.Controllers.Plugins;
              if (!_P || !_P.prototype || !_P.prototype.parsePlugins) {
                (ensureBgBtn.__n = (ensureBgBtn.__n || 0) + 1) < 400 && setTimeout(ensureBgBtn, 100);
                return;
              }
              if (ensureBgBtn.__w) return;
              ensureBgBtn.__w = true;
              var _oP = _P.prototype.parsePlugins;
              if (_oP && !_oP.__wrapped) {
                _P.prototype.parsePlugins = function() {
                  var me = this;
                  try {
                    return _oP.apply(me, arguments);
                  } catch (e) {
                    // 异常来自 onResetPlugins:486 backgroundBtn.show()（中断时按钮
                    // 渲染循环已完成、_group 已 append，只差背景按钮与尾部绑定）。
                    // 官方语义下 store 含常规插件时 rank 分支必然建钮、本异常不会
                    // 发生；AI-only 环境（安装集只有 background 插件）触发官方未
                    // 覆盖分支。catch 时 parsePlugins 已执行到 pluginStore.reset(arr)
                    // （Backbone 先更新 models 再 fire reset——store 数据已就绪），
                    // 抛错截断了 reset 之后的尾部：
                    //   onResetPlugins 的 :486-498（按钮/尾部绑定）
                    //   parsePlugins 的 enablePlugins + refreshPluginsList（tab:visible
                    //   门！）+ startOnPostLoad/runAutoStartPlugins。
                    // 修复：补建 backgroundBtn → 重跑 onResetPlugins（此时按钮已存在
                    // 不再抛，面板完整）+ 按官方语义补 executePlugins 尾部。仍抛则
                    // 保留真实异常（说明补建后仍不健康，不掩盖）。
                    if (!me._plgBgRetried) {
                      me._plgBgRetried = true;
                      // ① 只补按钮对象（不挂 DOM）：onResetPlugins 开头
                      //    $toolbarPanelPlugins.empty() 会清掉预挂的 DOM（上版实测
                      //    PLUG_BG_BTN_NOT_FOUND——对象在、DOM 被 empty 清走）；
                      //    对象在即可让 :486 show() 不再抛。
                      if (me.viewPlugins && !me.viewPlugins.backgroundBtn) {
                        me.viewPlugins.backgroundBtn =
                          me.viewPlugins.createBackgroundPluginsButton();
                      }
                      try {
                        me.onResetPlugins(
                          me.getApplication().getCollection('Common.Collections.Plugins'));
                      } catch (err2) {
                        console.error('PLUG_BG_REPLAY_ERR ' + String(err2).slice(0, 120));
                        throw e;
                      }
                      // ② 重放完成后按钮 DOM 已被 empty 清走——按官方 slot 结构重挂
                      //    （slot id 同 addBackgroundPluginsButton/Plugins.js:286）
                      if (me.backgroundPlugins && me.backgroundPlugins.length > 0
                        && me.$toolbarPanelPlugins && me.viewPlugins.backgroundBtn) {
                        try {
                          // 官方可视结构 = div.group（界隔）+ span#slot-background-plugin；
                          // 直挂 panel 也显示（首轮真机已验证），但按官方结构包 group
                          // 保证与其他控件组一致（group 间分隔线/折叠行为同官方）
                          var _grp = $('<div class="group"></div>').appendTo(me.$toolbarPanelPlugins);
                          var _slot = $('<span class="btn-slot text x-huge" id="slot-background-plugin"></span>')
                            .appendTo(_grp);
                          me.viewPlugins.backgroundBtn.render(_slot);
                          me.viewPlugins.backgroundBtn.show();
                        } catch (es) { console.error('PLUG_BG_SLOT_ERR ' + String(es).slice(0, 120)); }
                      }
                      try {
                        me.getApplication().getController('LeftMenu') && me.getApplication()
                          .getController('LeftMenu').enablePlugins();
                        if (me.appOptions.canPlugins) {
                          me.refreshPluginsList();
                          me.startOnPostLoad = !Common.Controllers.LaunchController.isScriptLoaded();
                          !me.startOnPostLoad && me.runAutoStartPlugins();
                        }
                        console.error('PLUG_BG_FIXED ' + String(e).slice(0, 100)
                          + ' btn=' + !!(me.viewPlugins && me.viewPlugins.backgroundBtn));
                        return;
                      } catch (err3) {
                        console.error('PLUG_BG_TAIL_ERR ' + String(err3).slice(0, 120));
                        throw e;
                      }
                    }
                    throw e;
                  }
                };
                _P.prototype.parsePlugins.__wrapped = true;
              }
            } catch (wp) {}
          })();
          // 字族下拉数据源补发（2026-09-05 用户报修「字体列表无法下拉」）：
          // UI 层 Common.Controllers.Fonts.setApi 注册 asc_onInitEditorFonts →
          // onApiLoadFonts → cachedStore.add → trigger('fonts:load') →
          // ComboBoxFonts 实例 fillFonts 填自身 store（Fonts.js:156/343）。事件
          // 官方由 g_font_loader.LoadDocumentFonts → Api.sync_InitEditorFonts 发出
          // （sdk-all.js:244037），真机此链未跑（同 LoadFontAsync 因：web 语义
          // apiBase 不在路径）→ store 恒空 → ComboBoxFonts.onBeforeShowMenu
          // （ComboBoxFonts.js:661）preventDefault → 下拉打不开。
          // 补发判据（双条件轮询，勿改回一次性——实测一次性命中两个时机盲区：
          //   ① _sendInit 时刻 28MB checkAllFonts（g_font_infos）未必已 eval；
          //   ② 各 ComboBoxFonts 实例 init 时才订阅 fonts:load（Toolbar 晚建））：
          //   A. AscFonts.g_font_infos 已建（28MB checkAllFonts 完成）
          //   B. Common.NotificationCenter._events['fonts:load'] 已挂（订阅者就位）
          //     ——与 Fonts.js:127 同判据。
          // —— 字体注入源头归一（2026-09-06 数据取证定案）：官方链（#1/#3 各 18 条）
          //    已跑通（v13 时代"官方链断、需补发"的结论被推翻）——lsoSendFonts 补发
          //    整段删除（截图实证：补发的 CFont（type=''）与官方 18 条混排 → 空白行 +
          //    simsun.ttf 等文件行 + 英中成对重复）；此处 wrap sync_InitEditorFonts
          //    （apiBase.js:806 唯一入口）统一归一：
          //    ① 同签名跳过（官方链重发同内容 → 第二次丢弃，杜绝双份）；
          //    ② 族归一：按 Thumbnail（运行时字段——ROW 打点实证 Arial=0/Liberation=1/
          //       SimHei=10 族号）为键，每族一条；
          //    ③ 中文名优先（两轮处理：先选名再建列表——CFont.name 可能只读，不动原行，
          //       按名重造 CFont 不可（无构造器类型），改「选择保留哪条」策略：
          //       保留【中文名行】或【无中文名时的原行】）；
          //    ④ 剔 .ttf/.otf 文件名行（构建表文件别名，非族名）。
          //    渲染注册表 g_font_infos 不动：文档引用行名照常（宋体修复 name 契约）。
          (function _wrapInj() {
            try {
              if (window.__lsoInjWrapped || !_m || !_m.api) { return; }
              window.__lsoInjWrapped = true;
              var _oriI = _m.api.sync_InitEditorFonts;
              if (typeof _oriI !== 'function') {
                console.error('LSO_FONT_WRAP_NOMETHOD');
                return;
              }
              _m.api.sync_InitEditorFonts = function(fonts) {
                var _prev = '';
                try {
                  _prev = window.__lsoInjSig || '';
                  var _names = [], _sig = [], _nmv = [];
                  for (var ni = 0; ni < (fonts || []).length; ni++) {
                    var _ff = fonts[ni];
                    _nmv.push(String(_ff && _ff.asc_getFontName ? _ff.asc_getFontName() : ''));
                  }
                  _sig = _nmv.join('|');
                  if (_prev && _prev === _sig) {
                    console.error('LSO_FONT_SKIP_DUP n=' + _nmv.length);
                    return undefined; // 同内容重发 → 丢弃（防双份）
                  }
                  window.__lsoInjSig = _sig;
                  // 族归一（两轮）：候选名 → 选中文优先 → 输出
                  var _byThumb = {};
                  for (var k = 0; k < (fonts || []).length; k++) {
                    var _ft = fonts[k];
                    var _nm = String(_ft && _ft.asc_getFontName ? _ft.asc_getFontName() : '');
                    var _th = String(_ft && _ft.asc_getFontThumbnail ? _ft.asc_getFontThumbnail() : 'u');
                    if (!_nm || /\.(ttf|otf|eot|woff2?)$/i.test(_nm)) { continue; }
                    if (!_byThumb[_th]) { _byThumb[_th] = []; }
                    _byThumb[_th].push(_nm);
                  }
                  var _keep = [];
                  for (var _tk in _byThumb) {
                    var _names2 = _byThumb[_tk];
                    var _pick = '';
                    for (var j = 0; j < _names2.length; j++) {
                      if (/[一-龥]/.test(_names2[j])) { _pick = _names2[j]; break; } // 中文名优先
                    }
                    if (!_pick) { _pick = _names2[0]; }
                    _keep.push({thumb: _tk, name: _pick});
                  }
                  // 从原列表挑选“被保留名字”的行（原 CFont 对象 + 不重复）
                  var _out = [];
                  for (var mm = 0; mm < (fonts || []).length; mm++) {
                    var _fo2 = fonts[mm];
                    var _nm3 = String(_fo2 && _fo2.asc_getFontName ? _fo2.asc_getFontName() : '');
                    var _th3 = String(_fo2 && _fo2.asc_getFontThumbnail ? _fo2.asc_getFontThumbnail() : 'u');
                    if (/\.(ttf|otf|eot|woff2?)$/i.test(_nm3)) { continue; }
                    var _isKeep = false;
                    for (var kk = 0; kk < _keep.length; kk++) {
                      if (_keep[kk].thumb === _th3 && _keep[kk].name === _nm3) { _isKeep = true; break; }
                    }
                    if (_isKeep) { _out.push(_fo2); }
                  }
                  console.error('LSO_FONT_INJ n=' + ((fonts || []).length) + ' out=' + _out.length);
                  return _oriI.call(this, _out);
                } catch (iwx) {
                  console.error('LSO_FONT_INJ_ERR ' + String(iwx));
                  return _oriI.apply(this, arguments); // 异常降级原链
                }
              };
            } catch (iwx) { console.error('LSO_FONT_WRAP_ERR ' + String(iwx)); }
          })();
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

