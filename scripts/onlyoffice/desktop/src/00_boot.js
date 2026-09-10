(function() {
  'use strict';

  // ---- 自动保存：默认不开启（2026-09-05 用户决策：支持自动保存，但默认关——用户可在
  //      高级设置自行开启，且官方语义为全局持久）。此处只在「从未设置过」时补默认 0
  //      （开关首次显现=关）；用户切过（0/1）则不覆盖——尊重用户全局选择。引擎侧初始值
  //      另由 customization.autosave=false（Main.js:1899 null 分支）兜底。三编辑器前缀
  //      已实测：de=documenteditor / sse=spreadsheet / pe=presentation（Main.js:1436/1030/1004）。
  try {
    var _asa = ['de', 'sse', 'pe'];
    for (var _ai = 0; _ai < _asa.length; _ai++) {
      try {
        var _key = _asa[_ai] + '-settings-autosave';
        if (localStorage.getItem(_key) === null) { localStorage.setItem(_key, '0'); }
      } catch (e) {}
    }
  } catch (e) {}

  // ---- 页面公共工具：Uint8Array → base64（0x8000 分块 btoa，避免大缓冲 apply 栈爆；
  //      2026-09-05 审查收敛：30_open m7auto / 40_save asc_Save / 40_save saveDocument
  //      三处重复实现至此单点） ----
  window.__lsoB64 = function(u8) {
    var _bin = '';
    for (var _i = 0; _i < u8.length; _i += 0x8000) {
      _bin += String.fromCharCode.apply(null, u8.slice(_i, _i + 0x8000));
    }
    return btoa(_bin);
  };

  // ---- 插件链早期 fetch 取证（2026-09-06 AI 插件接入；仅验收态生效——编辑器页 URL
  //      带 m7auto=1（EditorPage m7Target），产品 URL 无此行为）：官方 loadPlugins 的
  //      loadConfig('../../../../plugins.json') 在文档 ready（app:ready → setApi）时发出，
  //      早于 prof-snap（10s 注入）——必须先装 hook 才能抓到官方 fetch 的真实 URL/status/
  //      body（10s 快照 srvPlugins=false 之谜：loadConfig 回 'error' 或 getPlugins catch） ----
  try {
    if (/[?&]m7auto=1/.test(location.search) || /[?&]m7accept=1/.test(location.search)) {
      var ___of = window.fetch;
      window.fetch = function(_furl, _fopt) {
        var _fu = String(_furl);
        var _isP = _fu.indexOf('plugins.json') >= 0 || _fu.indexOf('plugins/') >= 0 || _fu.indexOf('config.json') >= 0;
        if (_isP) console.error('PLUG_FETCH_GO ' + _fu);
        return ___of.apply(this, arguments).then(function(_fr) {
          if (_isP) {
            _fr.clone().text().then(function(_ft) {
              console.error('PLUG_FETCH_RET ' + _fu + ' st=' + _fr.status + ' len=' + (_ft || '').length
                + ' head=' + String(_ft || '').slice(0, 60).replace(/\s+/g, ' '));
            }).catch(function() {});
          }
          return _fr;
        }).catch(function(_fe) {
          if (_isP) console.error('PLUG_FETCH_ERR ' + _fu + ' ' + String(_fe && _fe.message));
          throw _fe;
        });
      };
    }
  } catch (_fe2) {}

  // ---- 壳层适配自检（2026-09-11，用户决策）----
  // 目的：官方升级 / 资源改动后，**一行日志**判断哪些注入点没挂上——运行时注入最大的
  //   隐患是「静默失效」（官方改了对象名/时序，hook 悄悄不生效，没人发现），本段把
  //   它变成可见。
  // 机制：各段 hook 就位处 `(window.__lsoShim = window.__lsoShim || []).push('<tag>')`。
  //   **用数组 push 而非函数调用**：00_theme / 09_fonts 排在本段之前执行，那时本段的
  //   函数还没定义——数组由首个调用者自建，任何执行顺序都成立。
  // 输出：页面加载后轮询期望项，齐了立即打 `LSO_SHIM_STATUS ok=N/N [...]`；超时 20s 打
  //   `MISSING [...]` 并列出已就位项（缺失=该段没挂上，或该段还在等对象）。
  // 期望清单 EXPECT 的页值：'editor'=仅编辑器页 / 'home'=仅欢迎页 / 'both'=两页。
  //   清单语义是「我认为必须挂上的注入点」——**新增段请顺手加一行**；漏登记只是少检查
  //   一项，不会误报（自检只做减法，不猜）。
  // 真机读法：hdc ... grep LSO_SHIM_STATUS web_console.txt → `ok=8/8` 即全绿。
  //   注意：两页各自独立自检（欢迎页期望 3 项、编辑器页 8 项），日志里两条各管各自页面。
  (function _shimSelfCheck() {
    try {
      var EXPECT = {
        theme: 'both', bridge: 'both',                      // 两页共用
        fonts: 'editor', engine: 'editor', open: 'editor',  // 编辑器页
        save: 'editor', print: 'editor', modal: 'editor',   // （modal 不在欢迎页：那儿没有 Common）
        about: 'home'                                       // 欢迎页（app:version 补发）
      };
      var _isEditor = ((window.location || {}).pathname || '').indexOf('/main/index.html') >= 0;
      var _want = [];
      for (var _k in EXPECT) {
        if (EXPECT[_k] === 'both' || (EXPECT[_k] === 'editor') === _isEditor) { _want.push(_k); }
      }
      var _t0 = Date.now();
      function _tick() {
        var _got = window.__lsoShim || [];
        var _miss = [];
        for (var _i = 0; _i < _want.length; _i++) {
          if (_got.indexOf(_want[_i]) < 0) { _miss.push(_want[_i]); }
        }
        var _el = Date.now() - _t0;
        if (!_miss.length) {
          console.error('LSO_SHIM_STATUS ok=' + _want.length + '/' + _want.length
            + ' [' + _want.join(',') + '] in ' + _el + 'ms');
          return;
        }
        if (_el > 20000) {
          console.error('LSO_SHIM_STATUS ok=' + (_want.length - _miss.length) + '/' + _want.length
            + ' MISSING [' + _miss.join(',') + '] got [' + _got.join(',') + ']');
          return;
        }
        setTimeout(_tick, 500);
      }
      setTimeout(_tick, 500);
    } catch (e) { console.error('LSO_SHIM_STATUS_ERR ' + String(e)); }
  })();

