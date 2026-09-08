(function() {
  'use strict';

  // ---- 0.9 主题默认=经典浅色：官方 web 语义通道（非 RPV！）----
  // 【机制实锤（2026-09-08 真机三连排查）】官方编辑器加载顺序（documenteditor/index.html
  // 同一文档流同步执行）：
  //   head:4  ascshim.js（本文件）
  //   head:322 if(window.AscDesktopEditor){ ... if(RendererProcessVariable){ uitheme=... } }
  //           ——桌面语义段。首加载 AscNative 未注入（ArkTS registerJavaScriptProxy 页面
  //           加载后才注入）→ AscDesktopEditor 不存在 → **整段跳过，RPV 无人消费**。
  //   head:333 themeinit 内联立即执行：!uitheme.id && set_id(localStorage['ui-theme-id'])
  //   body:331 !uitheme.id && params.uitheme(...)；仍无 → adapt_to_system_theme() →
  //           body.classList.add(relevant_theme_id()) 即 theme-white（官方兜底=跟系统）。
  // 【之前失败根因】把注入塞进 RPV（先 INSTALL 内、后同步头部）都是错位机制——web
  // 语义下官方段A 根本不读 RPV（外层 if(AscDesktopEditor)），body 恒走 theme-white。
  // 【正解】官方 web 语义主题命脉 = themeinit 的 localStorage::ui-theme-id（官方键：
  // Themes.js setTheme:611 写入/themeinit:82 读取）。ascshim 在 head:4 先于 themeinit
  // 执行——**预写默认值（仅当用户从未设置过）**：themeinit 读它 → uitheme.id=
  // theme-classic-light → body=theme-classic-light + 设置高亮「经典浅色」；
  // 用户设置里切换（setTheme 写同名键）→ 下次加载预写被「非 null」守卫跳过 → 用户
  // 选择持久化。零 RPV 依赖、零时序 hack、官方键官方机制。
  // 主题 id 必须是官方主题族（Themes.js themes_map / app.css `.theme-*`：
  // theme-system/theme-light/theme-classic-light/theme-dark/theme-contrast-dark/
  // theme-gray/theme-white/theme-night）。默认=经典浅色（用户需求 2026-09-08）。
  var _themeIdDefault = 'theme-classic-light';
  var _saved = null;
  try {
    _saved = localStorage.getItem('ui-theme-id');
    if (_saved === null) { localStorage.setItem('ui-theme-id', _themeIdDefault); }
  } catch (e) { _saved = null; }
  var _themeId = (_saved && String(_saved)) || _themeIdDefault;

  // RendererProcessVariable 仍需存在（面板设置 localthemes for..of / desktopinit.js
  // 若后执行会读 RPV.theme）：theme 字段给**同源值**（与预写/用户选择一致，避免双链
  // 冲突）；localthemes/rtl 结构不变。真正的机制是上面的 localStorage 预写。
  if (!window.RendererProcessVariable) {
    var themeType;
    if (_themeId == 'theme-system') {
      try { themeType = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light'; } catch (e) { themeType = 'light'; }
    } else if (_themeId == 'theme-dark' || _themeId == 'theme-night' || _themeId == 'theme-contrast-dark') {
      themeType = 'dark';
    } else {
      themeType = 'light';
    }
    window.RendererProcessVariable = {
      theme: { id: _themeId, type: themeType },
      localthemes: [],   // panelsettings.js 用 for..of 迭代 → 必须数组
      rtl: false
    };
  }
  // 主题诊断（与 LSO_ 系同惯例，一次一行）：1500ms 时 themeinit/body 段已走完——
  // 判据：body 必须含 theme-classic-light 且 uitheme.id=theme-classic-light
  //（2026-09-08 教训：此前 body=theme-white 即失败态——注入执行≠生效）。
  setTimeout(function () {
    try {
      var _ui = window.uitheme && window.uitheme.id;
      console.error('LSO_UITHEME ' + (_saved ? 'saved=' + _saved + ' ' : 'first-run ') + 'inject=' + _themeId
        + ' body=' + document.body.className + ' uitheme=' + _ui);
    } catch (e) {}
  }, 1500);

  // ---- 0.10 tab 主题色上报（2026-09-08 官方桌面特性：选中 tab 颜色跟随文档页当前
  //      主题色）---- 权威数据源 = 官方主题定义的 CSS 自定义属性
  //      （apps/common/main/resources/less/colors-table-<theme>.less：
  //       .theme-<id> { --toolbar-header-document: #446995 / --toolbar-header-spreadsheet:
  //       #3A8056 / --toolbar-header-presentation: #B75B44 ... }——每个主题族各有其值）。
  //      用户切换主题（Themes.js setTheme → body class 替换）后经 MutationObserver
  //      重报——tab 激活色随主题自动变化，零硬编码色值。
  //      上报：AscNative._call('theme:color', [{app,color}])（同步桥；ArkTS 侧缓存到
  //      docAccents 平行数组；home/loginpage 无该变量不上报——home chip 走默认品牌蓝）。
  (function() {
    try {
      var _path = window.location.pathname || '';
      var _app = _path.indexOf('/spreadsheeteditor/') >= 0 ? 'spreadsheet'
        : _path.indexOf('/presentationeditor/') >= 0 ? 'presentation'
          : _path.indexOf('/documenteditor/') >= 0 ? 'document' : '';
      if (!_app) { return; }
      var _tries = 0;
      var _sent = false;
      var _send = function() {
        try {
          if (!window.AscNative) { return; }
          if (document.readyState === 'complete' && document.body
            && document.body.className.indexOf('theme-') >= 0) {
            if (_sent) { return; }
            _sent = true;
            var _c = getComputedStyle(document.body).getPropertyValue('--toolbar-header-' + _app);
            if (_c && _c.length > 1) {
              window.AscNative._call('theme:color', [JSON.stringify({ app: _app, color: _c.trim() })]);
              console.error('LSO_THEME_COLOR ' + _app + ' ' + _c.trim() + ' body=' + document.body.className);
            }
          } else if (++_tries < 300) {
            setTimeout(_send, 100);
          }
        } catch (e2) {
          if (++_tries < 300) { setTimeout(_send, 200); }
        }
      };
      setTimeout(_send, 300);
      try {
        if (document.body || document.documentElement) {
          new MutationObserver(function() {
            _sent = false;
            setTimeout(_send, 300);
          }).observe(document.body ? document.body : document.documentElement,
            { attributes: true, attributeFilter: ['class'] });
        }
      } catch (e3) {}
    } catch (e4) {}
  })();
})();
