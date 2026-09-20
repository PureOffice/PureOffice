(function() {
  'use strict';

  // ---- 0.10 tab 主题色上报（2026-09-08 官方桌面特性：选中 tab 颜色跟随文档页当前
  //      主题色）---- 权威数据源 = 官方主题定义的 CSS 自定义属性
  //      （apps/common/main/resources/less/colors-table-<theme>.less：
  //       .theme-<id> { --toolbar-header-document: #446995 / --toolbar-header-spreadsheet:
  //       #3A8056 / --toolbar-header-presentation: #B75B44 ... }——每个主题族各有其值）。
  //      用户切换主题（Themes.js setTheme → body class 替换）后经 MutationObserver
  //      重报——tab 激活色随主题自动变化，零硬编码色值。
  //      上报：AscNative._call('theme:color', [{app,color}])（同步桥；ArkTS 侧缓存到
  //      docAccents 平行数组；home/loginpage 无该变量不上报——home chip 走默认品牌蓝）。
  //      【迁移注记】本段原含 0.9 主题默认预写与 0.11 导出 PDF 菜单隐藏，已于
  //      2026-09-21 fork 化阶段 1 源码化进 web-apps fork（themeinit.js 默认值
  //      'theme-classic-light' + RPV 兜底对象；common.less 的
  //      #fm-btn-export-pdf display:none!important）——本段仅余 0.10，待阶段 2
  //      随 ohos/theme.js（引擎域桥模块）迁移后整段退役。
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

  // 自检登记
  (window.__lsoShim = window.__lsoShim || []).push('theme');
})();
