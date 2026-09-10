  // ---- 0.94 字体文件加载取证（仅记录）：hook XHR onload，记录 /fonts/ 请求的
  //      状态码与字节数（LSO_FONT_XHR）。2026-09-05 中文渲染排查：判断 CJK 字体
  //      是否真正进入引擎（成功应为 status=200 len≈字体大小）。
  try {
    if (!window.__lsoXhrHook) {
      window.__lsoXhrHook = true;
      var _xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__lsoU = u;
        this.addEventListener('load', function() {
          try {
            if (String(u).indexOf('/fonts/') >= 0) {
              console.error('LSO_FONT_XHR ' + String(u).split('/').pop()
                + ' status=' + this.status
                + ' len=' + (this.response ? (this.response.byteLength || this.response.length || 0) : 0));
            }
          } catch (e) {}
        }, false);
        return _xo.apply(this, arguments);
      };
    }
  } catch (e) {}

  // ---- 0.95 打开链引擎适配（Gateway 层官方公开 API）：wrap Common.Gateway.on ——
  //      各编辑器 Main.js 在 onLaunch 里 Gateway.on('opendocumentfrombinary', loadBinary)
  //      注册，Gateway.js _onMessage dispatch → trigger → localHandler。此 wrap 100% 可达
  //      （独立于 *SE.controllers.Main.prototype 结构）；回调被调用即字节传到了 Main。
  //      正文（踢闸）：cell/slide 走 DI 链（asc_setDocInfo）打开，协同引擎从不初始化 →
  //      服务器链 asyncServerIdEndLoaded() 永不触发（apiBase.js:1968 onFirstLoadChangesEnd
  //      服务器专路）→ ServerIdWaitComplete 永 false → _openDocumentEndCallback 门槛
  //      （cell/api.js:3364 / slide api.js:5835 / word api.js:8224）永不过 → isDocumentLoadComplete
  //      永 false → GUI 完成链（loading 移除/工具栏/渲染视图）永不驱动。此踢闸 = 字节注入
  //      返回后补发「服务器首载完成」通知（官方公共 API；与服务器链 CoAuthoringApi
  //      .onFirstLoadChangesEnd 同语义）。slide 另有 images 闸门（ServerImagesWaitComplete，
  //      slide api.js:5835）→ 一并补发 asyncImagesDocumentEndLoaded。
  //      保留条件：正式环境用服务器或桌面链（onFirstLoadChangesEnd 自带）时应删除本节。
  //      挂点/机制说明（2026-09-05 审查更正）：_ed 取 Main.api、回退 window.Asc.editor——
  //      asyncServerIdEndLoaded 定义在 baseEditorsApi.prototype（apiBase.js:1486），三编辑器
  //      api 全继承 → 每次字节注入都会触发踢闸（word 与 cell/slide 一致；word api.js:8224
  //      门槛同样需要它，行为为有意）。serverId/images 均有方法存在性+未完成位双重 guard，
  //      重复调用无害。
  (function() {
    var _pn2 = (window.location || {}).pathname || '';
    // 三编辑器统一 hook（word Main.js:271 与 cell/slide 同样 Gateway.on 注册）：
    // LSO_GW_BIN len= 是字节到达的官方事件层打点（取证用）；LSO_KICK_* 为踢闸日志。
    if (_pn2.indexOf('/main/index.html') >= 0) {
      (function _hGW() {
        try {
          var G = window.Common && window.Common.Gateway;
          if (!G || typeof G.on !== 'function') {
            if ((window.__lsoKickGWWaitN = (window.__lsoKickGWWaitN || 0) + 1) < 240) setTimeout(_hGW, 250);
            return; // 60s 未就绪放弃（官方链异常时留给 LSO_* 门户日志取证，不无限空转）
          }
          if (!G.__lsoKickWrapped) {
            G.__lsoKickWrapped = true;
            var _oldOn = G.on;
            G.on = function(event, handler) {
              if (event === 'opendocumentfrombinary') {
                var _h = function(data) {
                  var r;
                  try {
                    var _dl = data && (data.byteLength || data.length
                      || (data.data && (data.data.byteLength || data.data.length)));
                    console.error('LSO_GW_BIN len=' + _dl);
                  } catch (bl) {}
                  try { r = handler.call(this, data); }
                  catch (e2) { console.error('LSO_GW_BIN_EXC ' + String(e2)); throw e2; }
                  try {
                    var _m = window.SSE && window.SSE.controllers && window.SSE.controllers.Main
                      || window.PE && window.PE.controllers && window.PE.controllers.Main;
                    var _ed = _m && _m.api;
                    if (!_ed) {
                      _ed = window.Asc && (window.Asc.editor || window.editor);
                    }
                    if (_ed && typeof _ed.asyncServerIdEndLoaded === 'function' && !_ed.ServerIdWaitComplete) {
                      _ed.asyncServerIdEndLoaded();
                      console.error('LSO_KICK_SERVERID (engine adapt)');
                    }
                    if (_ed && typeof _ed.asyncImagesDocumentEndLoaded === 'function' && !_ed.ServerImagesWaitComplete) {
                      _ed.asyncImagesDocumentEndLoaded();
                      console.error('LSO_KICK_IMAGES (engine adapt)');
                    }
                  } catch (kx) { console.error('LSO_KICK_ERR ' + String(kx)); }
                  return r;
                };
                console.error('LSO_GW_ONBIN_HOOKED');
                (window.__lsoShim = window.__lsoShim || []).push('engine');  // 自检登记
                return _oldOn.call(G, event, _h);
              }
              return _oldOn.call(G, event, handler);
            };
          }
        } catch (e) { console.error('LSO_GW_ERR ' + String(e)); }
      })();
    }
  })();

