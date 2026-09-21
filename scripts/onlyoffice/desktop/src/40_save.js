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

  // （3.7/3.7.1 web 语义开关+放映全屏已于 2026-09-21 fork 化阶段 2-j2 并入
  //   ohos/bridge.js（INSTALL 装配后按页语义删/放映期临时恢复 AscDesktopEditor））
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
  //（外层 IIFE 闭合在此：原 50_init 为末段时承担 `})();`，其退役后由本段收尾）
})();

