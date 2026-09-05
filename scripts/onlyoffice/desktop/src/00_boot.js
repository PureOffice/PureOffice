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

