// ---- 字体映射探针（smoke 专用；回归 P2）----
// 目的：把「请求名 → 命中字体行」落日志，供真机回归断言——覆盖"请求被错误行
//   截胡"类回归（Symbol/Wingdings 曾因 FONT_INFOS 里存在精确同名行而命中自身，
//   ChangeGlyphsMap 的码位映射永不触发 → 符号整体变方块）。装填缺失类由
//   FONT_WARM_FILLED 判据覆盖（见 tests/cases.tsv 的 font-* case），二者互补：
//   前者判"选对了字体"，后者判"字体字节在不在"。
// 手段：官方 GetFontFileWeb 的内建回调 window.onLogPickFont（map.js:2941，某请求名
//   首次解析时回调一次；之后 FontPickerMap 命中缓存不再回调，故日志中每个请求名
//   至多一条——断言用"存在"语义即可）。
// 时机：必须**页面早期**安装——smoke 侧 prof-snap 注入带 10s 延迟（EditorPage
//   诊断配额，为区分"主线程卡死 vs 链未走完"），到那时文档字体早已解析完；故本段
//   随 ascshim 在页面 head 执行（早于 sdkjs 加载与文档打开）。
// 门控：仅验收态（URL 带 m7auto=1，EditorPage 只在 Smoke.enabled 时拼该参数）——
//   产品路径不安装回调，零行为差异。
(function() {
  if (!/[?&]m7auto=1/.test(window.location.search || '')) return;
  window.onLogPickFont = function(s) { console.error('FONT_PICK ' + s); };
})();
