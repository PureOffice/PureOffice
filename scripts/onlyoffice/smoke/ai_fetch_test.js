// ---- AI 插件联网验证（smoke 注入；仅 m7accept 激活态执行）----
// 验证目标（2026-09-07 方案 A 放行）：onInterceptRequest 对非 localhost URL 返回
// null → AI 插件远程 API 走 ArkWeb 默认网络栈直连。本脚本用与插件 engine.js
// requestWrapper 相同的 fetch 形态（同源 iframe/主页面 CORS 等价）对 DeepSeek
// OpenAI 兼容 /v1 做真实调用：GET /models（放行+可达）→ POST /chat/completions
// （放行+preflight+出网+回复回传）。
// key 双通道：优先 URL 参数 ?m7key=（编辑页 editorUrl 拼——Web 侧可靠通道，
// 2026-09-08 1.4 启动参数链不可达教训）；回退 EditorPage 注入替换 __AI_KEY__。
// 均未注入（生产态）→ 只打 AI_TEST_NOKEY，不发任何网络请求。
(function () {
  var m = window.location.search.match(/[?&]m7key=([^&]+)/);
  var KEY = m ? decodeURIComponent(m[1]) : '__AI_KEY__';
  function log(m2) { console.error(m2); }
  if (!KEY || KEY.indexOf('__') === 0) { log('AI_TEST_NOKEY'); return; }
  log('AI_TEST_KEY_READ m7key=' + KEY.slice(0, 12) + '***');

  var BASE = 'https://api.deepseek.com/v1';

  function check(ctx, r) {
    // 放行成功=远程真实响应（非本地 made 404 文本）
    return { ctx: ctx, status: r.status, body: r.text ? r.text() : r };
  }

  async function main() {
    var models = [], model = 'deepseek-chat';
    try {
      var r = await fetch(BASE + '/models', { method: 'GET', headers: { 'Authorization': 'Bearer ' + KEY } });
      var t = await r.text();
      if (r.status === 200) {
        try {
          var j = JSON.parse(t);
          models = (j.data || []).map(function (m) { return m.id; });
          if (models.length > 0) { model = models[0]; }
        } catch (e) { t = 'parse-err ' + String(e); }
        log('AI_MODELS_OK n=' + models.length + ' first=' + model);
      } else {
        log('AI_MODELS_ERR st=' + r.status + ' body=' + t.slice(0, 200));
      }
    } catch (e) {
      log('AI_MODELS_CATCH ' + String(e));
    }
    try {
      var r2 = await fetch(BASE + '/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + KEY },
        body: JSON.stringify({
          model: model,
          messages: [{ role: 'user', content: 'AISTUB-PING 平台连通性测试' }],
          max_tokens: 16
        })
      });
      var t2 = await r2.text();
      if (r2.status === 200) {
        try {
          var j2 = JSON.parse(t2);
          var content = (j2.choices && j2.choices[0] && j2.choices[0].message)
            ? j2.choices[0].message.content : '<empty>';
          log('AI_CHAT_OK reply=' + String(content).slice(0, 80));
        } catch (e) {
          log('AI_CHAT_PARSE_ERR ' + String(e) + ' body=' + t2.slice(0, 120));
        }
      } else {
        log('AI_CHAT_ERR st=' + r2.status + ' body=' + t2.slice(0, 200));
      }
    } catch (e) {
      log('AI_CHAT_CATCH ' + String(e));
    }
    log('AI_TEST_DONE');
  }
  main();
})();
