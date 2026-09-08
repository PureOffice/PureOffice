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

  // ---- 0.11 文件菜单「导出为PDF」隐藏（用户 2026-09-09 要求移除）----
  //     官方显隐条件（spreadsheeteditor FileMenu.js:408）：
  //     canDownload && isDesktopApp && isOffline —— 与「另存为」（407）**条件
  //     完全相同**（不能动 canDownload/权限——会连带杀另存为）；官方
  //     customization.features（FeaturesManager）无该功能开关——官方仅此一项级
  //     DOM 通道。DOM 锚点=官方模板固定 id #fm-btn-export-pdf（MenuItem el）。
  //     官方菜单每次打开会 show/hide 重置该元素 inline style——定向
  //     MutationObserver 盯其 style 变化立即回 hide（只在命中元素上监听，
  //     低成本；比构建链 FileMenu.js 字符串 patch 更贴近页面层可审计——
  //     2026-09-09 用户选型）。
  (function() {
    // 【v1 JS 隐藏失败实测（2026-09-09 真机 1.4：导出为PDF 仍在）】v1 是
    // 「getElementById 查找 + 只对命中元素挂定向 observer」——败因：菜单模板
    // （FileMenu.template:12，`<li id="fm-btn-export-pdf" class="fm-btn"></li>`）
    // 是**离线片段**；FileMenu 构造时（FileMenu.js:160 经 $markup.elementById，
    // 见 utils.js:1254）先从 document.getElementById 取——取不到——**仅菜单打开
    // (show) 才把模板挂载进 document**。页面 ascshim 于 head 执行：永远落空 →
    // observer 未挂上 → 落空后无人接管（官方 menu 每次打开还会 show/hide 重置
    // inline style）。
    // 【v2 正解：CSS 注入 display:none!important】a) 零时序/零观察/零状态——
    // 元素无论何时入 DOM、菜单重建多少次恒得隐藏；b) stylesheet 的 !important
    // 恒胜非 !important 的 inline 声明（官方重置为 el.style.display=''，不带
    // !important）——官方「每次打开重置」翻不过来；c) 页面层可审计（ascshim
    // 挂 head，与本文件其余注入段、CJK 字体链 CSS 同惯例）。
    try {
      var _st = document.createElement('style');
      _st.textContent = '#fm-btn-export-pdf{display:none!important}';
      (document.head || document.documentElement).appendChild(_st);
    } catch (e5) {}
  })();
})();
