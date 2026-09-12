  // ==========================================================================
  // 4.9 文档默认语言 = 中文简体（cell 侧；三格式对齐的最后一块）
  // ==========================================================================
  // 目标（2026-09-12 用户需求）：从主页新建三种文档时语言统一中文简体（对齐 docx）。
  // 三格式的语言载体天生不同，前两个由**空模板**承载：
  //   docx：styles.xml 的 docDefaults → w:lang val/eastAsia="zh-CN"（2026-09-05）
  //   pptx：官方 blank 主题自带 165 处 lang="en-US"（slide 的文档语言 = 各文本
  //         run / endParaRPr / defaultTextStyle defRPr 的 lang）→ make_empty_templates.py
  //         生成时统一替换为 zh-CN
  //   cell：**SpreadsheetML 没有文档级语言元素**——core 的 XlsxFormat 不解析任何 lang
  //         （仅命中图表 <c:lang> 与图形兜底字符串），引擎对任何 xlsx 都用内置默认
  //         1033(en-US)（cell/api.js:97 `this.defaultLanguage = 1033`，不进模型也
  //         不进 bin）→ 模板无从承载。而官方 web 对 cell 的语义本就是**编辑器偏好**：
  //         localStorage 的 sse-spellcheck-locale（Spellcheck.js:143 回灌
  //         InternalSettings ← :186 面板初值），不是文档属性。
  // 故本段走与 00_theme（预写 ui-theme-id）同一条官方 web 通道：
  //   1. 预写缺失的偏好键（zh-CN 的 LCID 2052 = 0x0804）——用户若在设置里改过，
  //      键已在 = 不覆盖，用户选择持久化；
  //   2. api 就绪后把该值回灌引擎字段（拼写检查/输入默认取它）。
  // 判据：LSO_DOCLANG。cell 的用户可见处 = 左侧菜单 abc「拼写检查」面板里的「字典
  // 语言」下拉（cell 无 asc_onTextLanguage 注册 → **状态栏**不显示语言，别处找不到）。
  // 另两个编辑器不执行本段——它们的语言由文档自身承载，越权设置默认语言会盖掉
  // 文档语言（word 的 run/docDefaults、slide 的 run/defRPr 各自带 lang）。
  (function _docLang() {
    try {
      if ((window.location.pathname || '').indexOf('/spreadsheeteditor/') < 0) {
        return;
      }
      var LANG_ZH_CN = 2052; // LCID 0x0804；LanguageInfo 表 short-name 'zh-CN'
      var KEY = 'sse-spellcheck-locale';
      var injected = false;
      var saved = null;
      try {
        saved = localStorage.getItem(KEY);
        if (saved === null) {
          localStorage.setItem(KEY, String(LANG_ZH_CN));
          saved = String(LANG_ZH_CN);
          injected = true;
        }
      } catch (e) { saved = null; }
      var _n = 0;
      var _t = setInterval(function () {
        _n++;
        var api = (window.Asc && window.Asc.editor) ? window.Asc.editor : window.editor;
        if (api && typeof api.asc_setDefaultLanguage === 'function') {
          clearInterval(_t);
          var v = parseInt(saved, 10);
          if (isFinite(v) && v > 0) {
            try { api.asc_setDefaultLanguage(v); } catch (e) {}
          }
          var _cur = '?';
          try { _cur = api.asc_getInputLanguage(); } catch (e) {}
          console.error('LSO_DOCLANG first-run=' + injected + ' want=' + v + ' cur=' + _cur);
          return;
        }
        if (_n > 300) { clearInterval(_t); } // 30s 未就绪：放弃（不阻断页面）
      }, 100);
    } catch (e) { }
  })();
