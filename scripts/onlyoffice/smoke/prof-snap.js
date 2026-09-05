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

    // 高层 name→face 链逐步面诊（2026-09-05 最后收窄：a/b/c 每步返回值）
    try {
      var out = [];
      try { out.push('idxSong=' + _ga.GetFontIndex('宋体')); } catch (e) { out.push('A' + e); }
      try { out.push('idxSimSun=' + _ga.GetFontIndex('SimSun')); } catch (e) { out.push('B' + e); }
      try {
        var _dict = _ga.GetFontNameDictionary && _ga.GetFontNameDictionary();
        out.push('dict=' + (typeof _dict === 'string' ? _dict.slice(0, 120) : (_dict ? Object.keys(_dict).slice(0, 20).join(',') : 'null')));
      } catch (e) { out.push('C' + e); }
      try {
        var _ffw = _ga.GetFontFileWeb && _ga.GetFontFileWeb('宋体');
        if (_ffw) {
          out.push('ffwIdx=' + _ffw.m_lIndex
            + ' r1=' + ((_ffw.m_ulUnicodeRange1 === undefined) ? 'undef' : (_ffw.m_ulUnicodeRange1 >>> 0).toString(16))
            + ' r4=' + ((_ffw.m_ulUnicodeRange4 === undefined) ? 'undef' : (_ffw.m_ulUnicodeRange4 >>> 0).toString(16))
            + ' cp1=' + ((_ffw.m_ulCodePageRange1 === undefined) ? 'undef' : (_ffw.m_ulCodePageRange1 >>> 0).toString(16))
            + ' fmt=' + _ffw.m_eFontFormat
            + ' path=' + _ffw.m_wsFontPath);
        } else { out.push('ffw=null'); }
      } catch (e) { out.push('D' + e); }
      try {
        var _ff = _ga.GetFontFile && _ga.GetFontFile('宋体');
        out.push('ff=' + (_ff ? Object.keys(_ff).slice(0, 20).join('.') : 'null'));
      } catch (e) { out.push('E' + e); }
      // CFontSelectList.List 的名字全集（GetFontIndex 候选列表 = g_fonts_selection_bin 反序列化）
      try {
        var _selList = _ga && _ga.g_fontSelections && _ga.g_fontSelections.List || [];
        var _nm = [];
        for (var _i = 0; _i < Math.min(_selList.length, 40); _i++) {
          _nm.push(_selList[_i] && (_selList[_i].m_wsFontName || _selList[_i].m_wsFontPath || '?'));
        }
        console.error('PROF_LIST n=' + _selList.length + ' names=' + _nm.join(','));
      } catch (e5) { console.error('PROF_LIST_ERR ' + String(e5)); }
      // 直接调 GetFontIndex（名字选择），观察对两个名字的选择结果
      try {
        var _o1 = { wsName: 'HarmonyOS Sans SC' };
        var _r1 = _ga.GetFontIndex(_o1, true);
        var _o2 = { wsName: '宋体' };
        var _r2 = _ga.GetFontIndex(_o2, true);
        console.error('PROF_GETIDX hxos=[' + (_r1 && (_r1.m_wsFontName || '?') + '/' + _r1.m_lIndex) + ']'
          + ' song=[' + (_r2 && (_r2.m_wsFontName || '?') + '/' + _r2.m_lIndex) + ']');
      } catch (e6) { console.error('PROF_GETIDX_ERR ' + String(e6)); }
      // 逐候选罚分（名字选择为何不中——2026-09-05）
      try {
        var _pl = _ga.g_fontSelections && _ga.g_fontSelections.List || [];
        var _dict = _ga.g_fontDictionary;
        for (var _i2 = 0; _i2 < _pl.length; _i2++) {
          try {
            var _oPen = { wsName: 'HarmonyOS Sans SC' };
            var _res = _pl[_i2].GetPenalty(_oPen, _dict.MainUnicodeRanges);
            if (_res && _res.Penalty < 9000) {
              console.error('PROF_PEN ' + JSON.stringify(_pl[_i2].m_wsFontName)
                + ' pen=' + _res.Penalty + ' namePen=' + _res.NamePenalty);
            }
          } catch (e7) {}
        }
      } catch (e8) { console.error('PROF_PEN_ERR ' + String(e8)); }
      console.error('PROF_CHAIN ' + out.join(' | '));
    } catch (e4) { console.error('PROF_CHAIN_ERR ' + String(e4)); }
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
