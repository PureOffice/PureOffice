  // ---- 模态弹窗触发保护（2026-09-11）----
  // 现象：AI 插件「设置」弹窗只有灰遮罩、内容空白（用户报告「整个界面变灰，似乎是想
  //   弹窗但是没弹出来」）。
  // 根因链（真机日志实证）：
  //   apps/common/main/lib/controller/Desktop.js:611 `if (config.isDesktopApp)` 注册了
  //   modal:show/close/hide → _onModalDialog → native.execCommand('title:button', ...)；
  //   而编辑器页按 3.7 保持 web 语义（40_save.js 删 window.AscDesktopEditor 与
  //   window.desktop → Desktop.js 模块加载时 `var native = window.desktop ||
  //   window.AscDesktopEditor` 为空）→ TypeError: Cannot read properties of undefined
  //   (reading 'execCommand')。
  //   Window.js:822 的 `Common.NotificationCenter.trigger('modal:show', this)` **位于
  //   this.render() 之前**，异常冒泡出 show() → 窗口 DOM 永不创建（遮罩已显示）→
  //   「界面变灰但没有弹窗」。已渲染过的窗口（如聊天窗）不受影响 —— 故只有
  //   **首次打开**的弹窗（AI 设置）中招，且此后每次都空白。
  // 修法：仅对这三个模态事件包 try/catch。该 handler 是纯壳层通知（模态期间经
  //   title:button 禁用标题栏按钮），本壳无标题栏 → 吞掉异常后 Window.show() 正常
  //   走到 render()。
  // 已知残留：Backbone 的 trigger 是同步遍历，异常会中断，吞掉后**排在其后的同名
  //   handler 仍被跳过**（DocumentHolder/Main/FocusManager 的模态联动）——它们的作用是
  //   「模态期间禁用文档交互」，而窗口遮罩本就挡住点击，影响可忽略；换取的是弹窗恢复。
  // 页门控：无（欢迎页/编辑器页共用同一 Common 实例，两页都有模态）。
  (function _guardModalTrigger() {
    try {
      var _n = 0;
      function _tick() {
        _n++;
        var NC = (window.Common && window.Common.NotificationCenter) || null;
        if (NC && typeof NC.trigger === 'function' && !NC.__lsoModalGuarded) {
          NC.__lsoModalGuarded = true;
          var _orig = NC.trigger;
          NC.trigger = function (name) {
            if (name === 'modal:show' || name === 'modal:close' || name === 'modal:hide') {
              try {
                return _orig.apply(this, arguments);
              } catch (e) {
                console.error('LSO_MODAL_GUARDED ' + name + ' ' + String(e));
                return this;
              }
            }
            return _orig.apply(this, arguments);
          };
          console.error('LSO_MODAL_GUARD_HOOKED');
          return;
        }
        if (_n < 900) { setTimeout(_tick, 200); } else { console.error('LSO_MODAL_GUARD_GIVEUP'); }
      }
      setTimeout(_tick, 500);
    } catch (cbx) { console.error('LSO_MODAL_GUARD_ERR ' + String(cbx)); }
  })();
