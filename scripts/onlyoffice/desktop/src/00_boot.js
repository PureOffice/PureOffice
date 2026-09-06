(function() {
  'use strict';

  // ---- 00_boot：（已移除）cell 打开剖面诊断（PROF_STATE/onLaunch 打点 + loading-mask/
  //      toolbar 轮询）——凭界面元素/定时器判状态的旧做法，按稳定化计划（2026-09-05）
  //      移除；文档就绪判据以官方 asc_onDocumentContentReady 为权威事件（见 30_open/40_save）。

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

