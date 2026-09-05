// ===========================================================================
// 自动验收 smoke：编辑页状态快照（2026-09-05）
// 由 EditorPage → Smoke.js() 读 rawfile/onlyoffice/smoke/prof-snap.js 注入执行。
// 判据：按页面路径选 app 控制器命名空间（DE/SSE/PE）+ 公共 SSE.Views.Toolbar
//（view/Toolbar.js:133 复数 Views）。仅记录（测量用途），不控制流程——
// 文档就绪判据以官方 asc_onDocumentContentReady 为准（见 ascshim 同门标准）。
// 只做记录，不等待/不轮询任何状态。
// ===========================================================================
(function() {
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
})();
