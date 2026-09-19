// ===========================================================================
// 焦点链路取证探针（验收态专用，由 EditorPage 在文档打开后注入执行）
// ---------------------------------------------------------------------------
// 记录 DOM 焦点迁移与窗口焦点事件，判据前缀 LSO_FOCUS。
// 用途：排查「点工具栏 / 切 tab / 退出放映后系统软键盘被唤起」这类问题——
// 观测 sdkjs 的隐藏输入代理（textarea#area_id）与 Web 组件窗口焦点之间的先后关系，
// 据此区分「焦点被引擎抢回」与「内核恢复焦点」两种机制。
// 与 prof-snap 分开：本段纯观测、不触发任何动作，不参与插件链验收。
// ===========================================================================
(function() {
  try {
    var _fDesc = function(el) {
      if (!el) { return 'null'; }
      var r = (el.tagName || '?') + '#' + (el.id || '-');
      var cl = String(el.className || '');
      if (cl) { r += '.' + cl.slice(0, 30); }
      if (el.getAttribute && el.getAttribute('contenteditable')) { r += '|ce'; }
      return r;
    };
    console.error('LSO_FOCUS snap active=' + _fDesc(document.activeElement) + ' hasFocus=' + document.hasFocus());
    document.addEventListener('focusin', function(e) {
      console.error('LSO_FOCUS in ' + _fDesc(e.target));
    }, true);
    document.addEventListener('focusout', function(e) {
      console.error('LSO_FOCUS out ' + _fDesc(e.target));
    }, true);
    document.addEventListener('mousedown', function(e) {
      console.error('LSO_FOCUS mdown ' + _fDesc(e.target) + ' active=' + _fDesc(document.activeElement));
    }, true);
    window.addEventListener('focus', function() {
      console.error('LSO_FOCUS winfocus active=' + _fDesc(document.activeElement));
    });
    window.addEventListener('blur', function() {
      console.error('LSO_FOCUS winblur');
    });
  } catch (_fe) { console.error('LSO_FOCUS_ERR ' + String(_fe)); }
})();
