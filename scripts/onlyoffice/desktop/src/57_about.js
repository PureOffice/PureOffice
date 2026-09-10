/**
 * 57_about.js —— 欢迎页「关于」入口（app:version 补发 + 侧栏项即时显示）。
 *
 * 背景（2026-09-10 调查定音）：官方欢迎页自带整套 About——侧栏项
 * `<li class="menu-item hidden"><a action="about">…`（**官方默认 hidden**）+
 * AboutDialog（dlg-about）+ 事件通路：官方壳经
 * `window.sdk.fire('on_native_message', ['app:version', json])` 注入版本信息，
 * 页面主控制器订阅 `window.sdk.on("on_native_message", …)`，其中
 * `/app\:version/.test(e) && $(".tool-menu a[action=about]").parent().removeClass("hidden")`
 * ——**「关于」项显示的唯一通道**；About 面板视图（appname/version/版权行填充）也由
 * 该事件创建。本 B 架构壳此前从未补发 → 入口恒 hidden（「入口不见」根因；
 * 与多 tab、ascshim 左栏均无关）。
 *
 * 两件事解耦（2026-09-10 用户反馈「入口要加载成功一段时间后才出现」——原实现卡在
 * fetch version.json → 800ms 首 tick 的单链上）：
 *   A. **侧栏项显示**：独立高频轮询（100ms）removeClass——官方菜单渲染完成即命中，
 *      页面基本刚就绪入口就在（不依赖版本取值）；
 *   B. **面板视图创建**：版本号 fetch 完成（几十 ms）即开始重发 app:version（Fire
 *      官方正路，事件注册方=欢迎页主脚本，晚于 ascshim——重发×8@500ms 覆盖）——视图
 *      创建+字段填充依赖它，点击前必然就绪；fire 幂等（removeClass 幂等；view 已建
 *      分支仅更新）。
 * 载荷（对齐官方 opts 字段，见 build 链 patch_about_brand 欢迎页段注释）：
 *   appname/version/commercial/changelog/active/edition 之外不再给 link/site
 *   （官网行已被 patch 成许可链接）/rights（版权行 patch 成 CREDIT 归属行）。
 * 版本值：version.json.ver（构建期 PRODUCT_VERSION，2026-09-10 用户拍板展示产品
 *   版本号——资源哈希 v 只做 URL 缓存指纹，不再出现在面板）。
 */
(function () {
  'use strict';

  var _p = (window.location || {}).pathname || '';
  if (_p.indexOf('/onlyoffice/index.html') < 0) { return; }

  // 产品版本（fetch 异步填充；'use strict' 下未声明赋值=ReferenceError，
  // 2026-09-10 真机踩坑：.then 里裸 ver= 抛错 → promise 链断 → 永不执行）
  var ver = '';
  // 诊断节流：SENT 只打首次成功；EXHAUSTED 只在 8 次全失败时打（避免重发刷屏）
  var sentLogged = false;
  var everOk = false;

  function fire() {
    try {
      if (!window.sdk || typeof window.sdk.fire !== 'function') { return false; }
      var opts = {
        appname: 'Pure Office',
        // 产品版本（version.json.ver；空串=版本行留白，不展示构建哈希——2026-09-10）
        version: (ver ? '版本 ' + ver : ''),
        commercial: false,
        active: false,
        changelog: false
      };
      // 官方 fire 签名=fire(事件名, 参数类数组)——payload 作第二参数会进
      // apply 被当类数组转换抛 CreateListFromArrayLike（2026-09-10 真机踩坑；
      // 官方 window.onupdaterecents=function(){i("publish",...)} 同款用法）
      window.sdk.fire('on_native_message', ['app:version', JSON.stringify(opts)]);
      everOk = true;
      if (!sentLogged) {
        sentLogged = true;
        console.error('LSO_APP_VERSION_SENT ver=' + ver);
        (window.__lsoShim = window.__lsoShim || []).push('about');  // 自检登记（仅欢迎页）
      }
      return true;
    } catch (e) {
      console.error('LSO_APP_VERSION_ERR ' + String(e));
      return false;
    }
  }

  function unhideNavItem() {
    try {
      // 官方同款动作（app:version 处理器里那行）；幂等；提前执行无副作用
      var m = document.querySelector('.tool-menu a[action="about"]');
      if (m && m.parentElement) {
        m.parentElement.classList.remove('hidden');
        return true;
      }
    } catch (e) {}
    return false;
  }

  // ---- A. 侧栏项立即显示：高频 removeClass，官方菜单一渲染到 DOM 即命中 ----
  (function () {
    var t = 0;
    var tickA = function () {
      if (unhideNavItem()) { return; }
      if (++t < 60) { setTimeout(tickA, 100); }   // 6s 窗口；未命中打日志留证
      else { console.error('LSO_ABOUT_NAV_UNFOUND'); }
    };
    setTimeout(tickA, 100);
  })();

  // ---- B. 面板视图创建：版本就绪即开始重发 app:version ----
  function scheduleFire() {
    var tries = 0;
    var tickB = function () {
      fire();
      if (++tries < 8) { setTimeout(tickB, 500); }
      else if (!everOk) { console.error('LSO_ABOUT_RETRY_EXHAUSTED'); }
    };
    setTimeout(tickB, 250);
  }

  try {
    fetch('/onlyoffice/version.json')
      .then(function (r) { return r.json(); })
      .then(function (j) {
        // version.json.ver=产品版本（About 展示）；v=资源哈希（URL 指纹，不上面板）
        ver = (j && j.ver) ? String(j.ver) : '';
        scheduleFire();
      })
      .catch(function () {
        ver = '';
        scheduleFire();
      });
  } catch (e2) {
    ver = '';
    scheduleFire();
  }
})();
