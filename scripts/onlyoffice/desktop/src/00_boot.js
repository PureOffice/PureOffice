(function() {
  'use strict';

  // ---- 00_boot：（已移除）cell 打开剖面诊断（PROF_STATE/onLaunch 打点 + loading-mask/
  //      toolbar 轮询）——凭界面元素/定时器判状态的旧做法，按稳定化计划（2026-09-05）
  //      移除；文档就绪判据以官方 asc_onDocumentContentReady 为权威事件（见 30_open/40_save）。

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

  // ---- 页面级整体缩放（2026-09-05 PC 用户诉求 1.2 倍）----
  // 生效机制：EditorPage（ArkTS，唯一可信 deviceInfo 源）在 URL 拼 &zoom=<factor>
  // （仅 2in1/pc）；本段读参数对 html 元素设 CSS zoom——布局整体重排放大
  // （DOM UI 清晰；canvas 元素同步放大）。
  // 放弃过的路径（勿回退）：WebviewController.zoom(factor)（@ohos.web.webview.d.ts:4331）
  // 是移动端触摸缩放语义，桌面布局页面实测无效——量化验证：缩放前后「主页」
  // 文本高 47px 无变化（2026-09-05）；zoomAccess(true) 仅放行手势，与设置无关。
  // 时机：ascshim 注入于 <head>（早于 app.js/页面 DOM），documentElement 恒存在，
  // 同步设置、无竞态。
  (function () {
    try {
      var _zq = (window.location.search || '').match(/[?&]zoom=([^&]+)/);
      if (_zq && parseFloat(_zq[1]) > 0) {
        document.documentElement.style.zoom = parseFloat(_zq[1]);
        console.error('LSO_PAGE_ZOOM ' + parseFloat(_zq[1]));
      }
    } catch (ze) {
      console.error('LSO_PAGE_ZOOM_ERR ' + String(ze));
    }
  })();
