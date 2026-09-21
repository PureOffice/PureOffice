  // （3.8.4 两块已于 2026-09-21 fork 化阶段 2-f 源码化进 sdkjs：
  //   ① 序列化公共工具 → apiBase.js window.__ohosWithNativeSaveEnd（30_open
  //     m7auto 引用同步替换）；② asc_Save 保存链管控原型覆写 → apiBase.js
  //     asc_Save 头部 [OHOS: save] 分派 + _ohosSave 实现（guard/askSaveChanges/
  //     save:bin/save:as/autosave 短路/状态栏提示/canSave 复位），asc_isOffline
  //     [OHOS] 恒真、三家 api.js asc_DownloadAs [OHOS] 另存为重定向、三家
  //     sendEvent [OHOS] -25 拦截同批。判据日志字样 LSO_* 全部保留在源码分支）

  // （3.8.2b Gateway.requestClose 覆写 + 3.8.3 Gateway.saveDocument 覆写已于
  //   2026-09-21 fork 化阶段 2-g 源码化进 web-apps fork apps/common/Gateway.js
  //   ——两方法体 [OHOS: close]/[OHOS: save] 分支（requestClose 回欢迎页 /
  //   saveDocument 直连 save:bin）。实例覆写与轮询退役；判据日志字样保留）

  // （3.8.2 引擎级 -25(EditingError) 拦截已于 2026-09-21 fork 化阶段 2-f 源码化：
  //   三编辑器 api.js sendEvent 头部 [OHOS: save] 分支（分发前吞掉——sendEvent 层
  //   是唯一单点，Main.onError 层拦截时机不足）；实例 wrap 轮询退役）

  // ---- 3.7 编辑器页（/main/index.html）web 语义开关：删除 AscDesktopEditor → sdkjs/
  //      webapps 不进入 isDesktopApp 桌面分支（桌面分支把字体 wasm/字体选择表切到
  //      native 通路，g_fonts_selection_bin 类缺失 → Base64.decode(undefined) 崩 →
  //      "打开文件时发生错误"）。桌面语义启用=三条件（native 字体供给 + LoadJS + allfonts
  //      桌面装载），现阶段未齐 —— 保持 web 语义。
  //      "关闭/返回"能力用官方 web 机制：editorConfig.customization.goback.url →
  //      Main.js canBack=true → 头部/文件菜单"返回"按钮 → goback → location.href 回欢迎页。
  try {
    if (window.location && window.location.pathname && window.location.pathname.indexOf('/main/index.html') >= 0) {
      try { delete window.AscDesktopEditor; } catch (d1) { window.AscDesktopEditor = undefined; }
      try { delete window.desktop; } catch (d2) { window.desktop = undefined; }
      console.error('LSO_WEB_SEMANTIC (editor page)');
    }
  } catch (nx) {}

  // ---- 3.7.1 放映全屏通道（2026-09-11，PPT 放映「只在 webview 内播」修复）----
  // 根因（真机 1.6 实证 + 时序日志）：sdkjs 放映引擎只在
  //   `undefined !== window["AscDesktopEditor"]` 时才调 SetFullscreen
  //   （Transitions.js:4075 开始 / :4555 结束）——官方桌面语义里放映全屏是 native 层
  //   的事（web-apps Viewport.js:312 对 isDesktopApp 又显式跳过浏览器 Fullscreen
  //   API，两条路只此一条）。而 3.7 为字体链 web 语义删除了该对象 → 放映时无任何
  //   壳层全屏动作（用户现象：tab 栏与窗口都不动，画面只在 webview 内铺）。
  // 修法=**放映期临时恢复**（web-apps 官方事件驱动；两事件都在 DocumentPreview 的
  //   show/hide 内同步触发——show 早于引擎 StartDemonstration、hide 晚于引擎 End）：
  //     preview:show → window.AscDesktopEditor = window.__lsoAscDE（INSTALL 装配的同份）
  //     preview:hide → 再删除（回到 3.7 的 web 语义）
  //   选"临时"而非"文档就绪后长期恢复"：3.7 注释警告的字体 native 分支按对象存在性
  //   判定，放映期（文档已打开、字体链早已走完）恢复可完全避开该风险面。
  // 判据日志：LSO_FS_BRIDGE on/off（HOOKED=钩子就位）。
  (function _hookShowFullscreen() {
    try {
      if ((window.location || {}).pathname.indexOf('/main/index.html') < 0) { return; }
      var _n = 0;
      var _tick = function() {
        _n++;
        var NC = window.Common && window.Common.NotificationCenter;
        if (NC && typeof NC.on === 'function' && !NC.__lsoFsBridge) {
          NC.__lsoFsBridge = true;
          NC.on('preview:show', function() {
            try {
              if (window.__lsoAscDE) {
                window.AscDesktopEditor = window.__lsoAscDE;
                console.error('LSO_FS_BRIDGE on');
              }
            } catch (e2) { console.error('LSO_FS_BRIDGE_ERR ' + String(e2)); }
          });
          NC.on('preview:hide', function() {
            try {
              delete window.AscDesktopEditor;
              console.error('LSO_FS_BRIDGE off');
            } catch (e3) {}
          });
          console.error('LSO_FS_BRIDGE_HOOKED');
          return;
        }
        if (_n < 900) { setTimeout(_tick, 200); }
      };
      setTimeout(_tick, 500);
    } catch (e) { console.error('LSO_FS_BRIDGE_ERR ' + String(e)); }
  })();

  // ---- 3.9 头部装饰定制（2026-09-05 用户：编辑器页右上角"用户头像 U + 关闭 X"去掉）----
  // 两元素官方均无**独立**显示开关，故按头部视觉定制在页适配层隐藏：
  //   - #slot-btn-close（Header.js:970/1076 btnClose）：显示条件 = canCloseEditor
  //     （Main.js:504 = customization.close.visible!==false && canRequestClose && !isDesktopApp）
  //     —— 若走官方 close.visible=false 会把"文件菜单→关闭"入口一并关掉（退出只剩
  //     左上角返回箭头），不符合"只去装饰、保留功能"意图。
  //   - .btn-current-user（Header.js:1074 用户头像圈）：官方 else 分支无条件渲染
  //     （guest+canRenameAnonymous 分支是改名按钮，非本场景），无配置可关。
  // 功能入口保留：左上角"返回"箭头（customization.goback → Main.js canBack）与
  // 文件菜单"关闭"。用 MutationObserver 等官方渲染后隐藏（事件驱动，非猜时机），
  // 持续监听防官方 re-render 弹回。
  (function _hideHeaderIcons() {
    try {
      if ((window.location || {}).pathname.indexOf('/main/index.html') < 0) { return; }
      var _hide = function() {
        var _c = document.getElementById('slot-btn-close');
        if (_c) { _c.style.display = 'none'; }
        var _u = document.querySelector('.btn-current-user');
        if (_u) { _u.style.display = 'none'; }
        // 左上 ONLYOFFICE logo：官方 branding 语义（bigger customization.logo.visible）
        // 只在 role=='left' 分支生效——docx 正常，cell/slide 的 customization 传递分支
        // 未达（2026-09-05 真机：xlsx/pptx 左上仍显示 logo）→ #header-logo 隐藏兜底
        // （同 3.9 模式，幂等；docx 已 hidden 再藏无影响；隐藏父 section.logo 防留空位）
        var _l = document.querySelector('#header-logo');
        if (_l && _l.closest) {
          var _ls = _l.closest('section.logo');
          if (_ls) { _ls.style.display = 'none'; }
        }
      };
      var _obs = new MutationObserver(_hide);
      if (document.body) {
        _obs.observe(document.body, {childList: true, subtree: true});
      } else {
        document.addEventListener('DOMContentLoaded', function() {
          _obs.observe(document.body, {childList: true, subtree: true});
        });
      }
      _hide();
      console.error('LSO_HEADER_ICONS_HIDDEN');
    } catch (hx) { console.error('LSO_HDR_HIDE_ERR ' + String(hx)); }
  })();

  // （3.9.1「用模板创建」菜单隐藏已于 2026-09-21 fork 化阶段 2 源码化：
  //   Desktop.js _extend_menu_file 头部 [OHOS: menu] 跳过注入——空入口不显示
  //   +官方无防重叠条问题一并消除；本侧 MutationObserver 删节点退役）

  // （3.8.5 closeEditor 实例覆写已于 2026-09-21 fork 化阶段 2-g 源码化：五编辑器
  //   Main.js closeEditor 体 [OHOS: close] 分支（editor:event close-request →
  //   宿主三按钮守卫）。词性坑注记随迁：运行时命名空间=window.<NS>.controllers
  //   （小写 c）。UI 可达性现状见 3.8.5 原注释（两官方关闭入口 UI 均不可达，
  //   本分支为未来恢复 web 关闭档时的守卫一致性）——轮询实例覆写退役）

  // ---- 3.8.6（诊断段，已删——2026-09-09 调查结论固化在 3.8.5 注释与 EditorPage
  //      requestCloseDoc 注释：接口句柄=window.<NS>.controllers.Main.api（小写
  //      controllers）、查询 API=asc_isDocumentCanSave（三引擎均有）、ArkWeb
  //      runJavaScript 返回值 JSON 编码、saveAborted 修复 canSave 复位缝隙）

