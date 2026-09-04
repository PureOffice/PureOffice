(function() {
  'use strict';

  // ---- 0.9 cell 打开剖面（PROF，xlsx 打开 40-60s 诊断）：loading-mask 在 SSE
  //      Main.onLaunch 链尾移除（Main.js:2559 $('#loading-mask').hide().remove()），
  //      用户感知"打开完成"= 其消失；工具栏 el=#toolbar（view/Toolbar.js:135）。
  //      打点：PROF_BOOT（shim 首行）→ PROF_HOOKED → PROF_LAUNCH_START/DONE（onLaunch
  //      wrap；loading 属 promise 尾 → STATE 轮询补足）→ PROF_STATE 变化（lm/wbModel/
  //      tbDOM/tbView）。时间戳由 ArkTS 落盘统一加（onConsole T<ms> 前缀），此处只打事件。
  //      仅 cell 页启用（word 已达标，避免日志杂音）。 ----
  (function() {
    var _pn = (window.location || {}).pathname || '';
    if (_pn.indexOf('/spreadsheeteditor/') >= 0) {
      try {
        console.error('PROF_BOOT');
        var _pollN = 0;
        var _prev = '';
        (function _pfPoll() {
          try {
            var _M = window.SSE && window.SSE.controllers && window.SSE.controllers.Main;
            var _api = _M && _M.api;
            var _lm = document.getElementById('loading-mask');
            var _tb = document.getElementById('toolbar');
            // 工具栏 view 类是 SSE.Views.Toolbar（复数，view/Toolbar.js:133 —— 非 SSE.view）
            var _tv = !!(window.SSE && window.SSE.Views && window.SSE.Views.Toolbar);
            var _cur = 'lm=' + (_lm ? 1 : 0) + ' wbModel=' + (!!(_api && _api.wbModel) ? 1 : 0)
              + ' tbDOM=' + (_tb ? 1 : 0) + ' tbView=' + (_tv ? 1 : 0);
            if (_cur !== _prev) { console.error('PROF_STATE ' + _cur); _prev = _cur; }
          } catch (e) { console.error('PROF_POLL_ERR ' + String(e)); }
          if (++_pollN < 240) { setTimeout(_pfPoll, 500); }   // 上限 120s
        })();
        (function _pfHook() {
          try {
            var _M2 = window.SSE && window.SSE.controllers && window.SSE.controllers.Main;
            if (_M2 && _M2.prototype && typeof _M2.prototype.onLaunch === 'function') {
              if (!_M2.prototype.__pfHook) {
                var _old = _M2.prototype.onLaunch;
                _M2.prototype.onLaunch = function() {
                  console.error('PROF_LAUNCH_START');
                  var r;
                  try { r = _old.apply(this, arguments); }
                  catch (e2) { console.error('PROF_LAUNCH_EXC ' + String(e2)); throw e2; }
                  console.error('PROF_LAUNCH_DONE');
                  return r;
                };
                _M2.prototype.__pfHook = true;
                console.error('PROF_HOOKED');
              }
            } else { setTimeout(_pfHook, 200); }
          } catch (e) {}
        })();
      } catch (e) {}
    }
  })();

