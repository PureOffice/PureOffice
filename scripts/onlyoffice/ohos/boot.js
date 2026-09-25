// ============================================================================
// ohos/boot.js —— B 架构编辑器页启动链（原 ascshim 30_open 3.4 段，2026-09-21
// fork 化阶段 2-i2 源码化：宿主装配域定制模块，随包装配进 rawfile/onlyoffice/
// ohos/，由装配链在编辑器 main/index.html 注入 <head>（ascshim 之后）。
//
// 职责（= 官方 api.js _onAppReady 的 B 架构等价物，无 api/documents DocsAPI 壳）：
//   ① editorConfig 构造（fileType/title 取自宿主 URL；customization/permissions/
//      targetApp 档位）② Main 就绪后直调 loadConfig + 遍历 controller 补发
//   ③ DI 打开链（asc_CDocInfo + asc_setDocInfo + 权限分发）——对齐官方桌面
//      「不打开空文档」语义（Local/common.js），首帧即真文档。
// 已迁出（源码化到 fork）：AI 插件 backgroundBtn 修复（web-apps Plugins.js
// [OHOS: plugins]）、字族下拉归一（sdkjs apiBase.js [OHOS: fonts]）。
// ============================================================================
(function() {
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
            // 界面语言：宿主 EditorPage 以 &lang=<systemLang()> 传入（2026-09-25 起
            //   跟随系统语言）。本页的 editorConfig.lang 与下方 goback 的 URL 都用它
            //   ——两处若各写各的，关闭文档回欢迎页时语言会漂移。缺省 'zh-CN' 仅为
            //   防御（宿主恒带参）。
            var _lq = (window.location.search || '').match(/[?&]lang=([^&]+)/);
            // 缺省 'en'：与整体回退策略一致（不在随包 46 种内 → 英文，spec §6 决策 1）。
            // 宿主 EditorPage 恒带 &lang=（故正常路径不会走到这里），缺省值只是防御。
            var _lang = _lq ? decodeURIComponent(_lq[1]) : 'en';
            var _cfg = {
              documentType: _dt,
              width: '100%', height: '100%',
              editorConfig: {
                mode: 'edit', lang: _lang, createUrl: 'desktop://create.new',
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
                  // {lang:'en'}）——回跳时带上当前页语言（_lang），否则关闭文档后欢迎页
                  // 掉回默认语言。
                  goback: {url: 'http://localhost/onlyoffice/index.html?lang=' + _lang},
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
                //  print:true —— canPrint=permissions.print!==false（Main.js:1735）
                //    → 工具栏打印按钮显示（Toolbar.js:3407-3408）+ 文件菜单打印项
                //    显示（FileMenu.js:435-436）。落地链=45_print.js 覆写 asc_Print
                //    → x2t bin2pdf → @ohos.print 系统打印（2026-09-10）。
                permissions: {edit: true, download: true, print: true}
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
                  (window.__lsoShim = window.__lsoShim || []).push('open');  // 自检登记
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
                  // CDocInfo.Lang = 文档信息里的语言（引擎侧拼写/状态栏的兜底来源）。
                  // 此前写死 zh-CN：单一语言年代无影响，跟随系统后必须与界面语言同源，
                  // 否则「文档自身未声明语言」的路径会拿到中文。与 _lang 同源（见上）。
                  _di2.put_Lang(_lang);
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
                  // 打印档位（2026-09-10）：onEditorPermissions 内部按
                  // canPreviewPrint = canPrint && !isMac && isDesktopApp
                  // （Main.js:1735）算出 true——本壳 targetApp='desktop'。
                  // 置 false 走官方「不预览直印」分支（macOS 同款）：
                  //   LeftMenu.clickToolbarPrint → canPreviewPrint ? 打印面板
                  //   : clickMenuFileItem('print') → api.asc_Print
                  // 理由：官方打印面板的打印机列表需壳层经 printer:config 事件
                  // 注入（Desktop.js:204-221，在 if(!!native) 内），而编辑器页已
                  // delete window.AscDesktopEditor → 面板下拉恒空、打印按钮恒灰。
                  // 系统打印框自己带打印机列表，故不需要该面板。
                  // canQuickPrint 同理置 false（静默快速打印语义——系统打印框必弹，
                  // 不成立）。**必须写在 try/catch 之外**：onEditorPermissions 在离线
                  // 环境会中途抛错（LSO_PERM_DISPATCH_ERR execCommand——官方内部对
                  // undefined 的 sdk 取方法，2026-09-10 真机实证），写在 call() 之后就
                  // 会被跳过；而 canPrint/canPreviewPrint 的赋值在抛错之前已完成，
                  // 故此处覆写既必要又有效。
                  _m.appOptions.canPreviewPrint = false;
                  _m.appOptions.canQuickPrint = false;
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
})();
