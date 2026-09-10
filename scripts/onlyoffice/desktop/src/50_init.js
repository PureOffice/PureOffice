    // ---- 4. 初始化尾 ----
    if (window.AscNative && window.AscNative._onReady) window.AscNative._onReady();
    // 自检登记：INSTALL 仅在 AscNative 注入后调用 → 走到这里=页面侧壳桥已就绪
    (window.__lsoShim = window.__lsoShim || []).push('bridge');
  };

  // —— 中文渲染阶段诊断段（PROF_LF/HB/HBS/GS/CG/RAST/MEAS/DRAW 等探针，多轮单次采集）——
  // 已完成使命，整段移除（2026-09-05 稳定化）。链路结论与验收键见
  // docs/ONLYOFFICE_OHOS_PORT_KEYPOINTS.md「字体链」章节；运行时保留观测仅
  // 装填/验收键：FONT_WARM_*（ascshim 0.5 装填）、LSO_*（打开链）、M7*（验收链）。

  // AscNative 由 ArkWeb registerJavaScriptProxy('AscNative', ...) 注入；等待它出现
  // （等注入对象，非界面/时间判据——ArkWeb 注入时序所致；ASC_BOOT/ASC_FOUND 保留一行
  // 区分"ascshim 未加载"与"AscNative 未注入"两种失败）
  try { console.error('ASC_BOOT ' + (window.location.pathname || '')); } catch (bx) {}
  (function wait() {
    if (window.AscNative) { try { console.error('ASC_FOUND native=' + (typeof window.AscNative._call)); } catch (bx) {} INSTALL(); return; }
    if (!wait.__log && (window.__lsoWaitN = (window.__lsoWaitN || 0) + 1) === 20) {
      wait.__log = true;
      console.error('ASC_WAITING_ASC (1s, no AscNative)');
    }
    setTimeout(wait, 50);
  })();
})();
