(function() {
  'use strict';

  // （autosave 默认预写已于 2026-09-21 fork 化阶段 2-m 核实删除——三重证据冗余：
  //   ①引擎 asc_setAutoSaveGap 有 typeof number 检查，null/字符串均 no-op，构造
  //     默认 autoSaveGap=0 即关（apiBase.js:116）；
  //   ②高级设置开关首显 setValue(value == 1)，null 与 '0' 都显示关
  //     （FileMenuPanels.js:1035-1036）；
  //   ③三编辑器 loadCoAuthSettings 链同构（de:1896/sse:1573/pe:1469），本壳
  //     isOffline 恒真连协同分支都不进。用户拨开关后的 localStorage 记忆语义不变）
  // （壳层适配自检 LSO_SHIM_STATUS 已于同批迁 ohos/bridge.js IIFE 尾部——自检
  //   检查的注入点（bridge/fonts）全在宿主装配域，且 bridge.js 已两页注入）

  // ---- 页面公共工具：Uint8Array → base64（0x8000 分块 btoa，避免大缓冲 apply 栈爆；
  //      消费者=30_open m7auto 序列化段——40_save 系退役后唯一在用，随 30_open
  //      阶段 4 外置 smoke 时一并处置） ----
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

