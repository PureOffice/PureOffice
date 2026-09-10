  // ---- 壳层事件防护（2026-09-11 扩展；原名「模态弹窗触发保护」）----
  // 根因（一条线贯穿）：官方 Desktop.js 在 `if (config.isDesktopApp)` 块里注册了一批
  //   「把 UI 状态通知原生层」的 handler / 菜单回调，全部**无保护**地调
  //   `native.execCommand(...)`；而编辑器页按 3.7 保持 web 语义（40_save.js 删
  //   window.AscDesktopEditor 与 window.desktop → Desktop.js:60 模块加载时
  //   `var native = window.desktop || window.AscDesktopEditor` 为空）
  //   → TypeError: Cannot read properties of undefined (reading 'execCommand')。
  // 危害不止「报个错」：Backbone 的 trigger 是**同步遍历 handler、异常即中断后续**
  //   （backbone.js:336 triggerEvents）→ 排在其后的其它 handler 全被跳过，表现为
  //   **UI 只刷新一半**。
  //
  // 已实测确认（2026-09-11 真机 1.6:33363）：
  //   1. `uitheme:changed`（Desktop.js:619-632）——「视图 → 界面主题」切任意主题即抛
  //      （报错点 Desktop.js:626）。症状=主题只切一半：顶栏 / tab 栏 / 左右面板 /
  //      页面背景换新，**工具栏区域保持旧主题**。对照实验：同一深色主题下重启应用，
  //      工具栏是深色 —— 渲染本身没问题，是切换路径被中断。
  //   2. `modal:show/close/hide`（Desktop.js:616-618 → _onModalDialog）—— 首次打开的
  //      弹窗（AI 插件「设置」）只有灰遮罩、内容空白：Window.js:822 的
  //      trigger('modal:show') **位于 this.render() 之前**，异常冒泡出 show() →
  //      窗口 DOM 永不创建。
  // 同族候选（静态确认同样无保护，本段一并兜住；日志会自动告诉我们哪些真被触发）：
  //   `app:face` → _onHidePreloader（Desktop.js:441 / 449，打开文档高频）、
  //   `hints:show` → _onHintsShow（Desktop.js:633 / 299）、
  //   `quickaccess:changed` → _onChangeQuickAccess（Desktop.js:634 / 573）。
  // 已确认不在兜底范围（各自安全，勿重复加）：
  //   FileMenu item:click 三分支（file:exit/open/create:fromtemplate —— 本壳文件菜单
  //   实测只有 返回/新建/保存/另存为/打印/信息/高级设置，菜单项不可达）、
  //   settings:apply（有 titlebuttons.quickprint 判空，本壳无该按钮）、
  //   process / requestClose / removeRecent / app:ready（均带 `!!native` 保护）。
  //
  // 修法：对上述事件在 NC.trigger 层包 try/catch。这些 handler 的职责本就是「把 UI
  //   状态通知原生层」，本壳没有原生标题栏 / CEF 接收方 → 吞掉异常后 Window.render()
  //   等正常路径得以走完，语义正确。**保留 console.error**（LSO_EVT_GUARDED + 事件名）
  //   —— 它同时是「还有哪些事件真被触发」的实测探针，勿删。
  //   （前缀 2026-09-11 由 LSO_MODAL_GUARDED 改名为 LSO_EVT_GUARDED：保护范围已从模态
  //   三事件扩到整族；旧前缀只出现在本次排查前的日志里。）
  // 已知残留（不变）：吞掉后**排在其后的同名 handler 仍被跳过**（Backbone 无法逐个
  //   隔离），本轮排查未发现因此造成的可见故障；若后续需要彻底隔离，再改 per-handler 包装。
  // 页门控：无（欢迎页 / 编辑器页共用同一 Common 实例，两页都有这些事件）。
  (function _guardShellEvents() {
    try {
      var _n = 0;
      // 白名单 = 已确认无保护且会调 native 的壳层事件；其余事件原样透传（不改变语义）
      var _GUARDED = {
        'modal:show': 1, 'modal:close': 1, 'modal:hide': 1,
        'uitheme:changed': 1, 'hints:show': 1, 'quickaccess:changed': 1, 'app:face': 1
      };
      function _tick() {
        _n++;
        var NC = (window.Common && window.Common.NotificationCenter) || null;
        if (NC && typeof NC.trigger === 'function' && !NC.__lsoShellGuarded) {
          NC.__lsoShellGuarded = true;
          var _orig = NC.trigger;
          NC.trigger = function (name) {
            if (_GUARDED[name]) {
              try {
                return _orig.apply(this, arguments);
              } catch (e) {
                console.error('LSO_EVT_GUARDED ' + name + ' ' + String(e));
                return this;
              }
            }
            return _orig.apply(this, arguments);
          };
          console.error('LSO_EVT_GUARD_HOOKED');
          return;
        }
        if (_n < 900) { setTimeout(_tick, 200); } else { console.error('LSO_EVT_GUARD_GIVEUP'); }
      }
      setTimeout(_tick, 500);
    } catch (cbx) { console.error('LSO_EVT_GUARD_ERR ' + String(cbx)); }
  })();
