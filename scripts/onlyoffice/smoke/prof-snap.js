// ===========================================================================
// 自动验收 smoke：编辑页状态快照 + 插件链验收动作（2026-09-05 建；9-06 扩）
// 由 EditorPage → Smoke.js() 读 rawfile/onlyoffice/smoke/prof-snap.js 注入执行
// （Smoke.enabled 门控 = ability 启动参数 m7accept=1；产品态不加载）。
// 判据：按页面路径选 app 控制器命名空间（DE/SSE/PE）+ 公共 SSE.Views.Toolbar
//（view/Toolbar.js:133 复数 Views）。初始快照仅记录；插件链段（2026-09-06）为
// 验收自动化：点击插件 tab/后台开关/AI Chatbot + 预注入 AI 模型配置——只在
// 验收态（本文件加载本身受 Smoke.enabled 控）执行，且各项均 console.error 打点
//（EditorPage onConsole → web_console.txt），不阻塞也不改写官方链路状态。
// 文档就绪判据以官方 asc_onDocumentContentReady 为准（见 ascshim 同门标准）。
// ===========================================================================
(function() {
  // AI 插件自动点击门控（2026-09-11）：下列点击动作默认不执行——它们会展开插件
  // 菜单/AI 面板并弹出聊天窗口（chat.html），遮挡常规验收（字体/打开/保存/打印等）
  // 的截图。需验 AI 插件链时由 EditorPage 在页面 URL 拼 m7ai=1 显式开启。
  // 取证类日志（DOM/结构快照）不受影响，仅"点击"这一动作受门控。
  var LSO_M7AI = /[?&]m7ai=1/.test(window.location.search || '');
  // AI 插件 iframe 的 contentDocument（同源；background 分支隐藏 iframe 名
  // iframe_<guid>，sdkjs show():1145 创建）——JSON.parse 化后由探针使用
  function _ifcDoc() {
    var _fi = document.getElementById('iframe_asc.{9DC93CDB-B576-4F0C-B55E-FCC9C48DD007}');
    return _fi && _fi.contentDocument;
  }
  // —— AI 模型预配置（2026-09-06 实验性注入；官方键 = AI.Storage localStorageKey
  //    "onlyoffice_ai_plugin_storage_key"，local_storage.js:42；version=4；
  //    结构 {version, providers, models, customProviders}）。
  //    用途：AI 插件 run 前把 Ollama(localhost:11434) 模型入库——无模型时
  //    Chatbot 点击走官方降级链 onOpenSettingsModal（无模型 → 自动弹设置窗口，
  //    engine.js:466-470 实证）——注入后 Chatbot 直接开 chat.html 窗口，可验
  //    AI 对话 UI 面。设备无 Ollama 时对话请求报错（引擎错误提示可见），属
  //    设备级外部依赖，不影响窗口/UI 链路验收。仅验收态（本文件）运行。 ——
  try {
    var _AIK = 'onlyoffice_ai_plugin_storage_key';
    if (!localStorage.getItem(_AIK)) {
      var _aitcfg = {
        version: 4,
        providers: {
          'Ollama': {
            name: 'Ollama',
            url: 'http://localhost:11434',
            key: '',
            models: [{ id: 'llama3.2:latest', object: 'model', created: 1739120925, owned_by: 'library', name: 'llama3.2:latest', endpoints: [], options: {} }]
          }
        },
        models: [{ capabilities: 255, provider: 'Ollama', name: 'Ollama [llama3.2:latest]', id: 'llama3.2:latest' }],
        customProviders: {}
      };
      localStorage.setItem(_AIK, JSON.stringify(_aitcfg));
      console.error('PROF_AI_CFG_SEEDOK');
    } else {
      console.error('PROF_AI_CFG_EXISTS len=' + String(localStorage.getItem(_AIK)).length);
    }
    // 动作→模型映射（行动能选择模型；键 actions_key=register.js:1063；Chat 动作
    // 默认 model=""（ActionUI modelId 缺省）→ 无映射则 getModelById("") 空 →
    // chatWindowShow 里 Request.create 降级 settings——第二键必配）
    var _AIK2 = 'onlyoffice_ai_actions_key';
    if (!localStorage.getItem(_AIK2)) {
      localStorage.setItem(_AIK2, JSON.stringify({
        'Chat': { 'name': 'Chatbot', 'icon': 'ask-ai', 'model': 'llama3.2:latest', 'capabilities': 1 },
        'Summarization': { 'name': 'Summarization', 'icon': 'summarization', 'model': 'llama3.2:latest', 'capabilities': 1 },
        'Translation': { 'name': 'Translation', 'icon': 'translation', 'model': 'llama3.2:latest', 'capabilities': 1 },
        'TextAnalyze': { 'name': 'Text analysis', 'icon': 'text-analysis-ai', 'model': 'llama3.2:latest', 'capabilities': 1 }
      }));
      console.error('PROF_AI_ACTIONS_SEEDOK');
    } else {
      console.error('PROF_AI_ACTIONS_EXISTS len=' + String(localStorage.getItem(_AIK2)).length);
    }
  } catch (es) { console.error('PROF_AI_CFG_ERR ' + String(es)); }
  try {
    var p = String(window.location.pathname || '');
    var ns = p.indexOf('/spreadsheeteditor/') >= 0 ? 'SSE'
      : p.indexOf('/presentationeditor/') >= 0 ? 'PE' : 'DE';
    var M = window[ns] && window[ns].controllers && window[ns].controllers.Main;
    var tb = document.getElementById('toolbar');
    var tv = window.SSE && window.SSE.Views && window.SSE.Views.Toolbar;
    var tc = window.SSE && window.SSE.controllers && window.SSE.controllers.Toolbar;
    console.error('PROF_SNAP ns=' + ns + ' now=' + Date.now()
      + ' main=' + !!M + ' api=' + !!(M && M.api)
      + ' wbModel=' + !!(M && M.api && M.api.wbModel)
      + ' lm=' + !!document.getElementById('loading-mask')
      + ' tbDom=' + !!tb + ' tbLen=' + (tb ? tb.innerHTML.length : 0)
      + ' ViewsTb=' + !!tv + ' ctrlTb=' + !!tc
      + ' wb=' + !!(M && M.api && M.api.wb));
  } catch (e) {
    console.error('PROF_SNAP_ERR ' + String(e));
  }

  // —— 点击捕手（2026-09-05 三轮终局：点击事件层 + onBeforeShowMenu 判定一次抓全。
  //      判定：CLICK_CAP 命中与否 = 事件是否到组件；PREV 记录防止值+store.length；
  //      MENU 记录菜单 DOM 的 display/行数。仅记录，不控制流程——
  (function clickcap() {
    var _hooked = false;
    function tryHook() {
      if (_hooked) return;
      var P = window.Common && window.Common.UI && window.Common.UI.ComboBoxFonts
        && window.Common.UI.ComboBoxFonts.prototype;
      if (!P) { return; }
      _hooked = true;
      var _bs = P.onBeforeShowMenu;
      var _wasPrevented = false;
      P.onBeforeShowMenu = function(e) {
        var _sl = this.store ? this.store.length : -1;
        var _r = _bs.apply(this, arguments);
        _wasPrevented = !!(e && e.isDefaultPrevented && e.isDefaultPrevented());
        try { console.error('PROF_PREV stop=' + _wasPrevented
          + ' store=' + _sl + ' menuOpen=' + this.isMenuOpen()
          + ' rendered=' + this.rendered + ' disabled=' + this.disabled); } catch (x) {}
        return _r;
      };
      console.error('PROF_CLICK_HOOKED');
    }
    document.addEventListener('click', function(ev) {
      tryKeyboard: try {
        tryHook();
        var _t = ev && ev.target;
        if (!_t) break tryKeyboard;
        var _cl = String(_t.className || '');
        var _isCombo = /font|combo|dropdown|input-group/.test(_cl);
        if (!_isCombo && !(_t.toElement && /font|combo/.test(String(_t.toElement.className || '')))) {
          break tryKeyboard;
        }
        var _menu = document.querySelector('ul.dropdown-menu');
        console.error('PROF_CLICK_CAP cls=' + _cl.slice(0, 80)
          + ' withinCombo=' + _isCombo
          + ' menuExists=' + !!_menu
          + ' menuDisp=' + (_menu ? getComputedStyle(_menu).display : 'npos')
          + ' menuItems=' + (_menu ? _menu.children.length : -1));
      } catch (e) { console.error('PROF_CLICK_ERR ' + String(e)); }
    }, true);
    console.error('PROF_CLICK_ARMED');
  })();

  // —— 字族下拉链现场（2026-09-05 二轮：Desktop 桩版。判定矩阵——
  //    FF_NOFF        = fillFonts 从未被调（事件链断：Fonts.setApi/或 register 未挂）
  //    FF_CALLED+持0  = fillFonts 被调但 store 仍空（loadSprite 仍未回调=桩未生效，
  //                     核对 DSK_* 行）
  //    FF_CALLED+>0   = store 已填充（下拉应开；若仍不弹→渲染层，另判）——
  // 仅记录，不控制流程——
  (function proff() {
    var out = [];
    try {
      var _ds = window.Common && window.Common.Controllers && window.Common.Controllers.Desktop;
      out.push('DSK=' + !!_ds + ' active=' + !!(_ds && _ds.isActive && _ds.isActive())
        + ' fa=' + !!( _ds && _ds.isFeatureAvailable && _ds.isFeatureAvailable('isSupportBinaryFontsSprite')));
    } catch (e) { out.push('DSK_E ' + e); }
    try {
      var _P = window.Common && window.Common.UI && window.Common.UI.ComboBoxFonts
        && window.Common.UI.ComboBoxFonts.prototype;
      if (!_P || !_P.fillFonts) { out.push('FF_NOPROTO'); }
      else if (!_P.__lsoFFW) {
        _P.__lsoFFW = true;
        var _ff = _P.fillFonts;
        out.push('FFW=' + (window.__lsoFFN = (window.__lsoFFN || 0) + 1));
        _P.fillFonts = function(store, select) {
          var me = this;
          var _preN = (window.__lsoFFN = (window.__lsoFFN || 0) + 1);
          try { console.error('PROF_FF CALL n=' + _preN
            + ' in=' + (store ? store.length : 'null')
            + ' store0=' + (me.store ? me.store.length : '?')); } catch (e) {}
          var _r = _ff.apply(this, arguments);
          setTimeout(function() {
            try { console.error('PROF_FF AFT n=' + _preN
              + ' store=' + (me.store ? me.store.length : '?')); } catch (e) {}
          }, 1500);
          return _r;
        };
      }
    } catch (e) { out.push('FF_E ' + e); }
    console.error('PROF_FONTPROBE ' + out.join(' '));
  })();

  // —— 字体下拉现场（2026-09-05 「工具栏字族下拉无法展开」：事件→store 链逐环取证，
  //      仅记录，不控制流程。链：sync_InitEditorFonts → sendEvent asc_onInitEditorFonts
  //      → Common.Controllers.Fonts.onApiLoadFonts → fonts:load → ComboBoxFonts.fillFonts
  //      → store 长度——空环=不弹（ComboBoxFonts.js:661 preventDefault）——
  try {
    var _app3 = M && M.getApplication ? M.getApplication() : null;
    var _out2 = ['vm=' + (M && M.api ? M.api.isViewMode : 'noApi')];
    try {
      var _fc2 = _app3 && _app3.getController('Common.Controllers.Fonts');
      _out2.push('fctl=' + (!!_fc2));
      if (_fc2) {
        _out2.push('fsetapi=' + !!_fc2.api);
        var _st = _fc2.store && _fc2.store();
        _out2.push('fstore=' + (_st ? _st.length : 'null'));
      }
    } catch (e9) { _out2.push('FERR ' + e9); }
    try {
      var _nc2 = window.Common && window.Common.NotificationCenter;
      var _ev = _nc2 && _nc2._events && _nc2._events['fonts:load'];
      _out2.push('subs=' + (_ev ? _ev.length : 0));
    } catch (e9) { _out2.push('NC ' + e9); }
    try {
      var _tb = _app3 && _app3.getController('Toolbar');
      var _vw = _tb && _tb.getView && _tb.getView('Toolbar');
      var _cb = _vw && _vw.cmbFontName;
      _out2.push('tb=' + !!_cb + ' store=' + (_cb && _cb.store ? _cb.store.length : -1)
        + ' items=' + (_cb && _cb.conf && _cb.conf.menu && _cb.conf.menu.items
          ? Object.keys(_cb.conf.menu.items).length : '?'));
    } catch (e9) { _out2.push('TB ' + e9); }
    console.error('PROF_FONTDD ' + _out2.join(' '));
  } catch (e) { console.error('PROF_FONTDD_ERR ' + String(e)); }

  // —— 字体现场取证（2026-09-05 中文渲染排查，仅记录，不控制流程）——
  try {
    var _fi = window.__fonts_infos || [];
    var _fk = Object.keys(window.AscFonts || {});
    console.error('PROF_FONT infos=' + _fi.length
      + ' afKeys(' + _fk.length + ')=' + _fk.slice(0, 25).join(','));
  } catch (e) { console.error('PROF_FONT_ERR ' + String(e)); }

  // —— 引擎字体注册状态（FontPicker Ranges / GetFontInfo('宋体')——2026-09-05 中文
  //      渲染排查；GetFontInfo 返回 wasm 对象，仅取存在性/名字防序列化爆量）——
  try {
    var _fp = window.AscFonts && window.AscFonts.FontPickerByCharacter;
    var _ra = _fp && _fp.Ranges;
    var _ga = window.AscFonts && window.AscFonts.g_fontApplication;
    var _gi = null;
    try { if (_ga && _ga.GetFontInfo) _gi = _ga.GetFontInfo('宋体'); } catch (ge) { _gi = 'EXC ' + ge; }
    var _gi2 = null;
    try { if (_ga && _ga.GetFontInfo) _gi2 = _ga.GetFontInfo('Noto Sans CJK SC'); } catch (ge) { _gi2 = 'EXC ' + ge; }
    console.error('PROF_PICK ranges=' + (_ra ? _ra.length : -1)
      + ' used=' + (void 0)
      + ' fbCount=' + (_fp && _fp.FontsByRangeCount)
      + ' pending=' + (_fp && _fp.isExtendFonts ? _fp.isExtendFonts() : -1)
      + ' | GI_song=' + (_gi ? ('name=' + _gi.Name + ' idx=' + _gi.indexR + ' byAlias=' + (_gi.byAlias || '')) : String(_gi))
      + ' | GI_noto=' + (_gi2 ? ('name=' + _gi2.Name + ' idx=' + _gi2.indexR) : String(_gi2)));
    // FontInfo 内部面信息（wasm face 指针/流 index——判定打开环节）
    try {
      if (_gi) {
        console.error('PROF_GIKEYS ' + Object.keys(_gi).slice(0, 40).join(','));
      }
      if (_ga) {
        console.error('PROF_GA_KEYS ' + Object.keys(_ga).slice(0, 40).join(','));
        var _fm = _ga.GetFontManager && _ga.GetFontManager();
        if (_fm) console.error('PROF_FMKEYS ' + Object.keys(_fm).slice(0, 40).join(','));
      }
    } catch (e3) { console.error('PROF_GI_ERR ' + String(e3)); }
  } catch (e) { console.error('PROF_PICK_ERR ' + String(e)); }

  // —— WebView 层中文渲染能力（页面 canvas，独立于引擎 libfont 的证据）——
  try {
    var cs = document.createElement('canvas');
    cs.width = 200; cs.height = 60;
    var ctx2 = cs.getContext('2d');
    ctx2.font = '30px sans-serif';
    var wCJK = ctx2.measureText('中文测试').width;
    ctx2.font = '30px serif';
    var wCJKSerif = ctx2.measureText('中文测试').width;
    console.error('PROF_CJK_CANVAS sans=' + wCJK + ' serif=' + wCJKSerif);
  } catch (e) { console.error('PROF_CJK_ERR ' + String(e)); }

  // —— AI 插件装配链现场（2026-09-06 接入：web 语义 plugins.json server 链）。
  //    判定矩阵（全部仅记录，不控制流程）——
  //    PLUG_CFG       = Plugins 控制器 setApi 是否执行过（loadPlugins 门）
  //    PLUG_SRV       = serverPlugins.plugins 状态（undefined=仍在载/false=error）
  //    PLUG_TB        = 顶部工具栏是否出现「插件」tab（DOM 判据）
  //    PLUG_STORE     = 插件集合数量（hasVisible 判定）
  //    PLUG_REG       = asc_pluginsRegister 是否已注册回调（sdkjs 侧收到了几个插件）
  //    PLUG_PLUG      = 菜单/面板 DOM 是否有 AI 插件按钮（background→工具栏 tab）
  //    PLUG_FETCH     = 浏览器侧 fetch 探针：手动拉 plugins.json/config.json 看 200/404
  //                    （rawfileLoader 路径语义；fetch 同源无 CORS 问题）
  //    PLUG_ISACTIVE  = Desktop.isActive/isOffline（决定走 server 链还是 desktop 链）
  //    PLUG_UI        = view 侧 plugin 状态（Common.Views.PluginDialog 能否建帧）
  // ——
  (function proplugin() {
    try {
      var _C = window.Common && window.Common.Controllers && window.Common.Controllers.Plugins;
      var _c = _C ? null : null;
      // Plugins 控制器 = window.DE.controllers 或 application.getController
      var _M = window[ns] && window[ns].controllers && window[ns].controllers.Main;
      var _app2 = _M && _M.getApplication ? _M.getApplication() : null;
      var _pc = null;
      try { if (_app2) _pc = _app2.getController('Common.Controllers.Plugins'); } catch (eg) {}
      var _cfg = _pc && _pc.configPlugins, _srv = _pc && _pc.serverPlugins;
      var _store = null;
      try {
        if (_app2) { var _cl = _app2.getCollection('Common.Collections.Plugins'); _store = _cl; }
      } catch (ec) {}
      var _tb = document.querySelector('ul[role="tablist"]') || document.getElementById('toolbar');
      var _tabNames = [];
      try {
        var _links = document.querySelectorAll('#toolbar-tabs a, #tabs a, .tabs a');
        for (var _ti = 0; _ti < _links.length; _ti++) _tabNames.push(String(_links[_ti].textContent || '').trim());
      } catch (et) {}
      console.error('PROF_PLUG ns=' + ns
        + ' pc=' + !!_pc
        + ' cfgCfg=' + !!( _cfg && _cfg.config)
        + ' cfgPlugins=' + ( _cfg ? (_cfg.plugins === undefined ? 'undef' : Array.isArray(_cfg.plugins) ? 'arr' + _cfg.plugins.length : String(_cfg.plugins)) : '-')
        + ' srvPlugins=' + (_srv ? (_srv.plugins === undefined ? 'undef' : Array.isArray(_srv.plugins) ? 'arr' + _srv.plugins.length : String(_srv.plugins)) : '-')
        + ' store=' + (_store && _store.length)
        + ' sdkDrv=' + (!!( window.Asc && window.Asc.editor && window.Asc.editor.asc_pluginsRegister))
        + ' tabs=' + _tabNames.join('|'));
      // Desktop.isActive/isOffline（server 链门）
      try {
        var _D = window.Common && window.Common.Controllers && window.Common.Controllers.Desktop;
        console.error('PROF_DESKTOP isActive=' + (_D && _D.isActive ? _D.isActive() : -1)
          + ' isOffline=' + (_D && _D.isOffline ? _D.isOffline() : -1));
      } catch (ed) { console.error('PROF_DESKTOP_ERR ' + String(ed)); }
      // fetch 探针（同源 rawfileLoader）：plugins.json + ai/config.json + v1/plugins.js
      // 2026-09-06 增强：body 校验（text + JSON.parse——官方 loadConfig 在 response.ok 后
      // 才 response.json()，rawfileLoader 的 MIME/body 若是 404 文本则 json() 抛错 → 'error'）
      ['plugins.json', 'plugins/ai/config.json', 'plugins/v1/plugins.js'].forEach(function(_f) {
        fetch('http://localhost/onlyoffice/' + _f)
          .then(function(r) {
            return r.text().then(function(_t) {
              var _j = '?';
              try { JSON.parse(_t); _j = 'json-ok'; } catch (je) { _j = 'json-bad'; }
              console.error('PROF_FETCH ' + _f + ' st=' + r.status + ' mime=' + (r.headers.get ? r.headers.get('content-type') : '?')
                + ' len=' + _t.length + ' ' + _j + ' head=' + _t.slice(0, 80).replace(/\s+/g, ' '));
            });
          })
          .catch(function(e) { console.error('PROF_FETCH_ERR ' + _f + ' ' + String(e && e.message)); });
      });
      // 官方 loadConfig 用的相对 URL：../../../../plugins.json 从 main/index.html 上跳四层
      // 应解析为 http://localhost/onlyoffice/plugins.json —— 若不一致即官方 fetch 失败的
      // 直接根因（2026-09-06 加；baseURI 受 <base>/history 影响）
      try {
        var _rel = new URL('../../../../plugins.json', document.baseURI).href;
        var _relCfg = new URL('../../../../plugins/ai/config.json', document.baseURI).href;
        console.error('PROF_BASEURI base=' + document.baseURI + ' href=' + window.location.href
          + ' rel=' + _rel + ' relCfg=' + _relCfg);
      } catch (eb) { console.error('PROF_BASEURI_ERR ' + String(eb)); }
      // 关键面：window.desktop / AscDesktopEditor 存在性 + 插件 store 内容
      try {
        console.error('PROF_DE_NATIVE desktop=' + typeof window.desktop
          + ' ascDE=' + typeof window.AscDesktopEditor
          + ' deKeys=' + (window.AscDesktopEditor ? (Object.keys(window.AscDesktopEditor).length) : -1));
        // store 内容（visible 判定链：parsePlugins:925 visible=(isEdit||viewer)&&EditorsSupport
        // &&!isSystem；AI 插件 isViewer:false→visible=isEdit。hasVisible()=false→
        // refreshPluginsList 不触发 tab:visible→Mixtbar display:none 保持）
        if (_store) {
          var _items = [];
          _store.each(function(it) {
            try {
              _items.push(String(it.get('guid') || '?')
                + '/' + (it.get('visible') === true ? 'vis' : it.get('visible') === false ? 'hid' : String(it.get('visible'))));
            } catch (ei) { _items.push('?'); }
          });
          console.error('PROF_STORE len=' + _store.length + ' items=' + _items.slice(0, 5).join(',')
            + ' hasVisible=' + (_store.hasVisible && _store.hasVisible())
            + ' isEdit=' + (_pc && _pc.appOptions && _pc.appOptions.isEdit === true ? 'true' : (_pc && _pc.appOptions ? String(_pc.appOptions.isEdit) : '-'))
            + ' canPlugins=' + (_pc && _pc.appOptions ? String(_pc.appOptions.canPlugins) : '-')
            + ' autostart=' + (_pc && Array.isArray(_pc.autostart) ? String(_pc.autostart.length) : '-')
            + ' apiVer=' + (_pc && _pc.api && _pc.api.GetVersion ? String(_pc.api.GetVersion()) : '-'));
          // 插件 tab 的 DOM 可见性（addTab 模板 display:none；tab:visible→setVisible 改 display）
          try {
            var _pt = document.querySelector('a[data-tab=plugins]');
            var _pli = _pt ? _pt.parentElement : null;
            console.error('PROF_PLUG_TAB exists=' + !!_pt
              + ' liDisplay=' + (_pli ? getComputedStyle(_pli).display : '-')
              + ' style=' + (_pli ? String(_pli.getAttribute('style') || '').replace(/\s+/g, ' ') : '-'));
          } catch (ep) { console.error('PROF_PLUG_TAB_ERR ' + String(ep)); }
        }
      } catch (en) { console.error('PROF_DE_ERR ' + String(en)); }
      // 观察后续：插件装配事件打点（asc_pluginsRegister 回调、tab:visible、app:ready）
      try {
        if (window.Common && window.Common.NotificationCenter && window.Common.NotificationCenter.on) {
          var _nc = window.Common.NotificationCenter;
          var _o1 = _nc.on.bind(_nc);
          console.error('PROF_NC_HOOK_PENDING');
        }
      } catch (eo) {}
      // —— AI 常驻链验收（2026-09-26 改版）：「插件」tab 已隐藏（web-apps fork：
      //     refreshPluginsList 不再 trigger tab:visible:plugins，addTab 模板恒
      //     display:none）。探针不再点插件 tab/后台插件开关——回归不得把插件菜单
      //     调出来。AI tab 由官方插件自注册（register.js new Asc.ButtonToolbar →
      //     data-tab=随机 UUID，不得按 data-tab 匹配），只能按 caption==='AI' 定位；
      //     它随插件 iframe 加载/run/AddToolbarMenuItem 往返异步出现（真机约 1.5-2s），
      //     故轮询取终值，不做单点采集。
      try {
        var _aiTab = null;
        var _polls = 0;
        var _pollAi = setInterval(function() {
          _polls++;
          try {
            var _lr0 = document.querySelectorAll('li.ribtab a');
            for (var _q0 = 0; _q0 < _lr0.length; _q0++) {
              if (String(_lr0[_q0].textContent || '').trim() === 'AI') { _aiTab = _lr0[_q0]; break; }
            }
          } catch (eq0) {}
          if (_aiTab || _polls >= 20) {
            clearInterval(_pollAi);
            // 「插件」tab 消失判据：元素不存在或 display:none 均算 true（元素在但
            // 恒 display:none 是 fork 后常态；absent 兼未来 DOM 精简）
            var _pt0 = document.querySelector('#toolbar-tabs a[data-tab=plugins]')
              || document.querySelector('a[data-tab=plugins]');
            console.error('PLUG_TAB_GONE=' + (!_pt0 || getComputedStyle(_pt0.parentElement).display === 'none'));
            // 后台插件按钮（原「插件」tab 内的开关）已不可达——仅记录 DOM 终态供诊断
            var _bg0 = document.getElementById('id-toolbar-btn-background-plugin');
            console.error('PLUG_BG_BTN=' + (!_bg0 ? 'absent' : getComputedStyle(_bg0).display));
            if (!_aiTab) {
              console.error('PLUG_AI_TAB_NF');
            } else {
              console.error('PLUG_AI_TAB_EXISTS=true');
              // 受 m7ai 门控：切 AI tab 会展开 AI 面板（原 PLUG_AI_TAB_CLICKED 语义上移至此）
              if (LSO_M7AI) { _aiTab.click(); console.error('PLUG_AI_TAB_CLICKED'); }
              else console.error('PLUG_AI_TAB_GATED');
            }
            // 点击后 6000ms 再走取证链：panel 按钮要等插件 iframe 加载 +
            // AddToolbarMenuItem 往返，等待放宽不压缩（防 PLUG_AI_CHAT_BTN_NF 假 FAIL）
            setTimeout(function() {
            try {
                      // run 后现场（sdkjs 侧）：pluginsMap/runnedPluginsMap/iframe/run 门判定
                      setTimeout(function() {
                        try {
                          var _gm = window.g_asc_plugins;
                          var _pm = _gm && _gm.pluginsMap ? Object.keys(_gm.pluginsMap) : null;
                          var _rm = _gm && _gm.runnedPluginsMap ? Object.keys(_gm.runnedPluginsMap) : null;
                          var _ifr = document.querySelectorAll('iframe[id^=iframe_]').length;
                          var _v = _gm && _gm.plugins && _gm.plugins.length;
                          console.error('PLUG_RUN_STATE gm=' + !!_gm
                            + ' pm=' + (_pm ? _pm.join(',') : '-')
                            + ' rm=' + (_rm ? _rm.join(',') : '-')
                            + ' iframe=' + _ifr
                            + ' plugins=' + (_v === undefined ? '-' : _v)
                            + ' supportMany=' + !!(_gm && _gm.isSupportManyPlugins));
                          // 隐藏 iframe 的 src（show() 若非 Visual 分支建）
                          var _if2 = document.querySelector('iframe[id^=iframe_asc]');
                          console.error('PLUG_IF_FRAME exists=' + !!_if2
                            + ' src=' + (_if2 ? String(_if2.src).slice(0, 120) : '-'));
                          // 顶级「AI」入口 DOM 身份（AddToolbarMenuItem/plugin button）。
                          // 2026-09-06 修正：tabs 容器是 li.ribtab（Mixtbar addTab 模板），
                          // 容器 id 不是 #toolbar-tabs（真实 id 由探针报出）；枚举全部
                          // ribtab 的 text/data-tab/display，AI 是否 tab 以枚举为准。
                          var _ribs = [];
                          try {
                            var _lr = document.querySelectorAll('li.ribtab a');
                            for (var _kr = 0; _kr < _lr.length; _kr++) {
                              var _a9 = _lr[_kr];
                              var _li9 = _a9.parentElement;
                              var _d9 = _li9 ? getComputedStyle(_li9).display : '-';
                              _ribs.push(String(_a9.textContent || '').trim()
                                + '/' + (_a9.getAttribute('data-tab') || '-')
                                + '/' + _d9);
                            }
                          } catch (er9) { _ribs.push('ERR:' + String(er9)); }
                          // tab 身份判定用 caption（data-tab=AI 不存在——tab.id 是随机
                          // UUID，2026-09-06 已证；此字段保留供人读）
                          var _aiByCaption = false;
                          try {
                            var _lc2 = document.querySelectorAll('li.ribtab a');
                            for (var _kc2 = 0; _kc2 < _lc2.length; _kc2++) {
                              if (String(_lc2[_kc2].textContent || '').trim() === 'AI') { _aiByCaption = true; break; }
                            }
                          } catch (kc2) {}
                          var _abtn = document.querySelectorAll('.btn-plugin, .btn-toolbar');
                          console.error('PLUG_AI_DOM aiTab=' + _aiByCaption
                            + ' ribtabs=' + _ribs.join('|')
                            + ' ctrlBtns=' + _abtn.length);
                        } catch (er) { console.error('PLUG_RUN_STATE_ERR ' + String(er)); }
                      }, 3000);
                      // iframe 内部取证（同源可访问 contentDocument）：AI 页是否
                      // 初始化（Asc.plugin 对象 / PluginWindow/executeMethod 框架面 /
                      // 工具栏按钮注册数——框架面齐不齐即 Chatbot 可点的前置）
                      // （AI tab 查找/点击已上移到轮询段——本段由轮询命中后的
                      // setTimeout(6000) 直入）
                      try {
                            var _doc = _ifcDoc();
                            if (_doc) {
                              var _vw = _doc.defaultView;
                              var _pgw = _vw && _vw.Asc && _vw.Asc.plugin;
                              var _pw = _vw && _vw.Asc ? typeof _vw.Asc.PluginWindow : 'noAsc';
                              var _em = _pgw ? typeof _pgw.executeMethod : 'noPlg';
                              var _bt = 0, _mt = 'noAI', _ct = 'noAI', _ser = '?';
                              try {
                                _bt = (_vw.Asc.Buttons && _vw.Asc.Buttons.ButtonsToolbar
                                  && _vw.Asc.Buttons.ButtonsToolbar.length) || 0;
                                // 引擎运行状态：AI.Models 长度 / Actions.Chat.model /
                                // serverSettings 有无（判断 ActionsLoad/Storage.load 是否读到注入）
                                if (_vw.AI) {
                                  _mt = (_vw.AI.Models && _vw.AI.Models.length) || '-';
                                  _ct = (_vw.AI.Actions && _vw.AI.Actions.Chat
                                    && _vw.AI.Actions.Chat.model) || '';
                                  _ser = _vw.AI.serverSettings === undefined ? 'undef' : (!!_vw.AI.serverSettings);
                                }
                              } catch (ebt) {}
                              console.error('PLUG_AI_IFC len=' + (_doc.body ? _doc.body.innerHTML.length : -1)
                                + ' asc=' + !!_pgw
                                + ' PluginWindow=' + _pw
                                + ' executeMethod=' + _em
                                + ' toolbarBtns=' + _bt
                                + ' models=' + _mt
                                + ' chatModel=' + _ct
                                + ' serverSettings=' + _ser
                                + ' ls=' + String(_vw && _vw.localStorage && _vw.localStorage.getItem('onlyoffice_ai_actions_key') || '').slice(0, 80)
                                + ' ls2=' + String(_vw && _vw.localStorage && _vw.localStorage.getItem('onlyoffice_ai_plugin_storage_key') || '').slice(0, 80)
                                + ' txt=' + String(_doc.body && _doc.body.textContent || '').replace(/\s+/g, ' ').slice(0, 120));
                            } else {
                              console.error('PLUG_AI_IFC_NF');
                            }
                          } catch (ei) { console.error('PLUG_AI_IFC_ERR ' + String(ei)); }
                          // 点 AI 面板的 Chatbot 按钮（点击 → chatWindowShow → 插件窗口；
                          // 页面按钮 text=Chatbot，类型 btn-toolbar；panel 的 data-tab 为
                          // 插件 UUID（tab.id），非字面 AI——2026-09-06 实测）
                          setTimeout(function() {
                            try {
                              // tab.id 是 UUID 且可能每次 run 变化——动态取 AI 项的 data-tab
                              // （稳妥：.tabs / #tabs 里 textContent==AI 的 a；再退 tab 面板
                              // [data-tab] 枚举文本匹配）
                              var _aiKey = '';
                              try {
                                var _lk = document.querySelectorAll('.tabs a, #tabs a, li.ribtab a');
                                for (var _kk = 0; _kk < _lk.length; _kk++) {
                                  if (String(_lk[_kk].textContent || '').trim() === 'AI') {
                                    _aiKey = _lk[_kk].getAttribute('data-tab') || '';
                                    break;
                                  }
                                }
                              } catch (ekk) {}
                              // 引号必须加：UUID 以数字开头裸写是非法选择器（真机踩过
                              // SyntaxError not a valid selector）。还必须限定 section——
                              // a[data-tab]（tab 项）与 section[data-tab]（面板）同 id
                              // 再次匹配（2026-09-06 事实：querySelector 先命中 a → btns=0
                              // 误判为面版无按钮）
                              var _panel = _aiKey ? document.querySelector('section[data-tab="' + _aiKey + '"]') : null;
                              console.error('PLUG_AI_PANEL key=' + _aiKey + ' panel=' + !!_panel);
                              // 按钮不在 panel 内（真机 2026-09-06：panel=true 但 btns=0）——
                              // 打印 panel outerHTML 前 400 + 全文档 Chatbot 文案的元素路径
                              var _chatBtn = null;
                              try {
                                var _pcb = document.querySelectorAll('[class*="btn-toolbar"], [class*="plg"], button');
                                for (var _kb = 0; _kb < _pcb.length; _kb++) {
                                  var _t9 = String(_pcb[_kb].textContent || '').trim();
                                  if (_t9 === 'Chatbot' || _t9.indexOf('Chatbot') >= 0) { _chatBtn = _pcb[_kb]; break; }
                                }
                              } catch (ekb) {}
                              console.error('PLUG_AI_DOM2 panelHtml=' + String(_panel && _panel.outerHTML || '').replace(/\s+/g, ' ').slice(0, 300)
                                + ' chatByText=' + (_chatBtn ? (_chatBtn.tagName + '.' + String(_chatBtn.className).slice(0, 40)
                                  + ' parent=' + String(_chatBtn.parentElement && _chatBtn.parentElement.className).slice(0, 40)) : 'nf'));
                              if (!_chatBtn) {
                                // 兜底：AI panel 内下挂按钮（btn-slot 结构）。真机实测
                                // （2026-09-06）：首个按钮是 Settings（register.js 在
                                // AI.serverSettings 空时先建 buttonSettings）——Chatbot 的
                                // 图标资源含 ask-ai（getToolBarButtonIcons("ask-ai")）：
                                // strings 由 URL/class 无法区分时按 img src 含 ask-ai 匹配，
                                // 其次才取第一个（保底；log 输出实际选项供判）
                                try {
                                  var _pb2 = _panel ? _panel.querySelectorAll('.btn-slot button, .btn-slot .btn, .btn-slot [data-toggle], .btn-slot') : [];
                                  // 每个 slot 的 DOM 特征（icon 是 sprite：class/背景含图标名，
                                  // 无 <img.src> 可嗅探——打印各 slot 内部 class/hint/title 供区分）
                                  var _slotList = [];
                                  try {
                                    var _sl2 = _panel ? _panel.querySelectorAll('.btn-slot') : [];
                                    for (var _kn = 0; _kn < _sl2.length; _kn++) {
                                      var _sIn = _sl2[_kn].innerHTML || '';
                                      _slotList.push(_kn + ':cls=' + String(_sIn.match(/class="[^"]*"/) && _sIn.match(/class="[^"]*"/)[0]).slice(0, 90)
                                        + '|hint=' + String(_sIn.match(/data-hint=\"([^\"]*)\"/) && _sIn.match(/data-hint=\"([^\"]*)\"/)[1]).slice(0, 40)
                                        + '|ttl=' + String(_sIn.match(/data-title=\"([^\"]*)\"/) && _sIn.match(/data-title=\"([^\"]*)\"/)[1]).slice(0, 40)
                                        + '|ai=' + _sIn.indexOf('ask-ai'));
                                    }
                                  } catch (ek8) {}
                                  console.error('PLUG_AI_BTN_PANELSLOT count=' + _pb2.length
                                    + ' imgAI=' + (_panel ? String(_panel.innerHTML || '').indexOf('ask-ai') : -1)
                                    + ' || ' + _slotList.join(' || '));
                                  if (_pb2.length > 0 && !_chatBtn) {
                                    // 用 .btn-slot 唯一序列（querySelectorAll 多选择器会重复匹配
                                    // 同一 slot 内的多个条件——9-30 实测 _pb2[1] 命中第一 slot
                                    // 的 btn div 而非第二 slot 按钮——按 .btn-slot 索引+图标类
                                    // 匹配 ask-ai（slot[1]，实测 ai=339））
                                    var _sl3 = _panel.querySelectorAll('.btn-slot');
                                    var _b3 = null;
                                    for (var _kp = 0; _kp < _sl3.length; _kp++) {
                                      var _slot = _sl3[_kp];
                                      var _in9 = _slot.innerHTML || '';
                                      if (_in9.indexOf('ask-ai') >= 0) {
                                        _b3 = _slot.querySelector('button') || _slot; break;
                                      }
                                    }
                                    // 保底：第二个 slot（Settings[0], Chatbot[1]——9-30 实测序）
                                    if (!_b3 && _sl3.length > 1) {
                                      var _s3 = _sl3[1];
                                      _b3 = _s3.querySelector('button') || _s3;
                                    }
                                    console.error('PLUG_AI_CHAT_TARGET ' + (_b3 ? ('slot=' + String(_b3.className || _b3.tagName).slice(0, 40)) : 'nf'));
                                    if (_b3) _chatBtn = _b3;
                                  }
                                } catch (eb2) {}
                              }
                              // 受 m7ai 门控：Chatbot 点击会经 chatWindowShow 弹出聊天窗口
                              // （chat.html），默认不点——常规验收截图不再被遮挡
                              if (!_chatBtn) {
                                console.error('PLUG_AI_CHAT_BTN_NF panel=' + !!_panel);
                              } else if (LSO_M7AI) {
                                _chatBtn.click();
                                console.error('PLUG_AI_CHAT_CLICKED');
                              } else {
                                console.error('PLUG_AI_CHAT_GATED');
                              }
                              // 4s 后查插件窗口 DOM（sdkjs ShowWindow → asc_onPluginWindowShow →
                              // Plugins.js onPluginWindowShow(1178) → Common.Views.PluginDlg：
                              // 弹窗内有 #id-plugin-container，内嵌 iframe url=variation.url
                              // （chat.html）；帧 id=frameId 名 iframe_<desc>）
                              setTimeout(function() {
                                try {
                                  var _ws = document.querySelectorAll('#id-plugin-container');
                                  // 弹窗里 iframe 全枚举（src/name/id）；plugin iframe 是
                                  // <iframe id="<frameId>" name="<frameId>">（PluginDlg url
                                  // 传入；若 src 未含 chat.html——打印实际 src 供判）
                                  var _wsIfr = [];
                                  try {
                                    var _mi = document.querySelectorAll('.modal iframe, #id-plugin-container iframe');
                                    for (var _k5 = 0; _k5 < _mi.length; _k5++) {
                                      _wsIfr.push(String(_mi[_k5].getAttribute('src') || '').slice(0, 140)
                                        + '/' + (_mi[_k5].id || '-'));
                                    }
                                  } catch (ek5) {}
                                  var _ci = null;
                                  var _ifr3 = document.querySelectorAll('iframe');
                                  for (var _k3 = 0; _k3 < _ifr3.length; _k3++) {
                                    if (String(_ifr3[_k3].src).indexOf('chat.html') >= 0) { _ci = _ifr3[_k3]; break; }
                                  }
                                  console.error('PLUG_AI_CHAT wins=' + _ws.length
                                    + ' chatIframe=' + (_ci ? String(_ci.src).slice(0, 140) : '-')
                                    + ' frameId=' + (_ci ? _ci.id : '-')
                                    + ' dlgn=' + (_ws.length ? document.querySelectorAll('.modal').length : 0)
                                    + ' modalIfr=' + _wsIfr.join('|')
                                    + ' dlgHtml=' + String((_ws.length ? (_ws[0].innerHTML || '') : '')).replace(/\s+/g, ' ').slice(0, 200));
                                } catch (ew) { console.error('PLUG_AI_CHAT_ERR ' + String(ew)); }
                              }, 4000);
                            } catch (ec) { console.error('PLUG_AI_CHAT_CLICK_ERR ' + String(ec)); }
                          }, 1500);
                      } catch (echain) { console.error('PLUG_AI_CHAIN_ERR ' + String(echain)); }
                      }, 6000);
          }
        }, 500);
      } catch (etb) { console.error('PLUG_AI_CHAIN_ERR ' + String(etb)); }

      // —— 插件装配异常重演（2026-09-06：官方 fetch 全 200，srvPlugins=false 说明
      //     getPlugins().then(loaded → serverPlugins.plugins=loaded → mergePlugins()) 中抛错
      //     → .catch → false。可疑点 refreshPluginsList（parsePlugins 尾调）——
      //     asc_pluginsRegister/trigger('tab:visible')/Gateway.pluginsReady 三连。
      //     本段幂等重演 refreshPluginsList 抓真实异常；异步 1s 后再查 tab display。
      //     仅验收态（prof-snap 本身）运行；重复调用三方无副作用（register 幂等/setVisible 反复）
      try {
        var _pr = _pc && _pc.refreshPluginsList && _pc.refreshPluginsList.bind(_pc);
        var _ascC = !!(window.Asc && window.Asc.CPlugin);
        var _gw = !!(window.Common && window.Common.Gateway && window.Common.Gateway.pluginsReady);
        console.error('PROF_RPL pred=' + !!_pr + ' ascCPlugin=' + _ascC + ' gwPluginsReady=' + _gw
          + ' apiHas=' + (!!(_pc && _pc.api) && Object.prototype.hasOwnProperty.call(_pc.api, 'asc_pluginsRegister')));
        if (_pr) {
          try {
            _pr();
            console.error('PROF_RPL_OK');
          } catch (rp) {
            console.error('PROF_RPL_ERR ' + String(rp && rp.stack || rp));
          }
        }
        setTimeout(function() {
          try {
            var _pt2 = document.querySelector('a[data-tab=plugins]');
            var _pl2 = _pt2 ? _pt2.parentElement : null;
            console.error('PROF_PLUG_TAB2 exists=' + !!_pt2
              + ' liDisplay=' + (_pl2 ? getComputedStyle(_pl2).display : '-')
              + ' style=' + (_pl2 ? String(_pl2.getAttribute('style') || '').replace(/\s+/g, ' ') : '-'));
          } catch (ep2) { console.error('PROF_PLUG_TAB2_ERR ' + String(ep2)); }
        }, 1000);
      } catch (erp) { console.error('PROF_RPL_ARM_ERR ' + String(erp)); }
      // hook fetch：记录插件相关请求（相对 plugins.json server 链 URL）
      try {
        var _of = window.fetch;
        if (!window.__pluginFetchHook) {
          window.__pluginFetchHook = true;
          window.fetch = function(url, opt) {
            var _u = String(url);
            if (_u.indexOf('plugins.json') >= 0 || _u.indexOf('onlyoffice/plugins/') >= 0) {
              console.error('PROF_FETCHHOOK ' + _u + ' opt=' + (opt ? JSON.stringify({m: opt.method || 'GET', h: opt.headers ? Object.keys(opt.headers) : []}) : 'none'));
            }
            return _of.apply(this, arguments).then(function(r2) {
              if (_u.indexOf('plugins.json') >= 0 || _u.indexOf('onlyoffice/plugins/') >= 0)
                console.error('PROF_FETCHHOOK_R ' + _u + ' st=' + r2.status);
              return r2;
            }).catch(function(e2) {
              if (_u.indexOf('plugins.json') >= 0 || _u.indexOf('onlyoffice/plugins/') >= 0)
                console.error('PROF_FETCHHOOK_E ' + _u + ' ' + String(e2 && e2.message));
              throw e2;
            });
          };
          console.error('PROF_FETCH_HOOKED');
        }
      } catch (ef) { console.error('PROF_FETCHHOOK_ERR ' + String(ef)); }
    } catch (e) { console.error('PROF_PLUG_ERR ' + String(e)); }
  })();
})();
