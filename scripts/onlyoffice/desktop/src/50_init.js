    // ---- 4. 初始化尾 ----
    if (window.AscNative && window.AscNative._onReady) window.AscNative._onReady();
  };

  // AscNative 由 ArkWeb registerJavaScriptProxy('AscNative', ...) 注入；等待它出现
  // （诊断：boot 打点 + 等待计数——区分"ascshim 未加载"与"AscNative 未注入"）
  try { console.error('ASC_BOOT ' + (window.location.pathname || '') + ' rec=' + !!window.__lsoRecovered); } catch (bx) {}
  (function wait() {
    if (window.AscNative) { try { console.error('ASC_FOUND native=' + (typeof window.AscNative._call)); } catch (bx) {} INSTALL(); return; }
    if (!wait.__log && (window.__lsoWaitN = (window.__lsoWaitN || 0) + 1) === 20) {
      wait.__log = true;
      console.error('ASC_WAITING_ASC (1s, no AscNative)');
    }
    setTimeout(wait, 50);
  })();
})();
