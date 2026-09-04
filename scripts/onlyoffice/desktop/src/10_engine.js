  // ---- 0.95 打开链引擎适配（Gateway 层官方公开 API）：wrap Common.Gateway.on ——
  //      各编辑器 Main.js 在 onLaunch 里 Gateway.on('opendocumentfrombinary', loadBinary)
  //      注册，Gateway.js _onMessage dispatch → trigger → localHandler。此 wrap 100% 可达
  //      （独立于 *SE.controllers.Main.prototype 结构）；回调被调用即字节传到了 Main。 ----
  (function() {
    var _pn2 = (window.location || {}).pathname || '';
    if (_pn2.indexOf('/spreadsheeteditor/') >= 0 || _pn2.indexOf('/presentationeditor/') >= 0) {
      (function _hGW() {
        try {
          var G = window.Common && window.Common.Gateway;
          if (!G || typeof G.on !== 'function') { setTimeout(_hGW, 250); return; }
          if (!G.__profff) {
            G.__profff = true;
            var _oldOn = G.on;
            G.on = function(event, handler) {
              if (event === 'opendocumentfrombinary') {
                var _h = function(data) {
                  console.error('PROF_GW_BIN len=' + (data && data.byteLength));
                  var r;
                  try { r = handler.call(this, data); }
                  catch (e2) { console.error('PROF_GW_BIN_EXC ' + String(e2)); throw e2; }
                  // —— 引擎适配（POC 踢闸的正规化落位）：cell/slide 走 DI 链（asc_setDocInfo）
                  // 打开，协同引擎从不初始化 → 服务器链 asyncServerIdEndLoaded() 永不触发
                  // （apiBase.js:1968 onFirstLoadChangesEnd 服务器专路）→ ServerIdWaitComplete
                  // 永 false → _openDocumentEndCallback 门槛（cell/api.js:3362 / slide
                  // api.js:5835 / word:8224）永不过 → isDocumentLoadComplete 永 false →
                  // GUI 完成链（loading 移除/工具栏/渲染视图）永不驱动（引擎模型已装载但
                  // 页面永久定格"加载中"）。此踢闸 = 字节注入返回后补发"服务器首载完成"
                  // 通知（官方公共 API；与服务器链 CoAuthoringApi.onFirstLoadChangesEnd
                  // 同语义）。slide 另有 images 闸门（ServerImagesWaitComplete，slide
                  // api.js:5835）→ 一并补发 asyncImagesDocumentEndLoaded（slide 专有；
                  // cell/word 无此闸门）。
                  try {
                    var _m = window.SSE && window.SSE.controllers && window.SSE.controllers.Main
                      || window.PE && window.PE.controllers && window.PE.controllers.Main;
                    var _ed = _m && _m.api;
                    if (!_ed) {
                      _ed = window.Asc && (window.Asc.editor || window.editor);
                    }
                    if (_ed && typeof _ed.asyncServerIdEndLoaded === 'function' && !_ed.ServerIdWaitComplete) {
                      _ed.asyncServerIdEndLoaded();
                      console.error('PROF_KICK_SERVERID (engine adapt)');
                    }
                    if (_ed && typeof _ed.asyncImagesDocumentEndLoaded === 'function' && !_ed.ServerImagesWaitComplete) {
                      _ed.asyncImagesDocumentEndLoaded();
                      console.error('PROF_KICK_IMAGES (engine adapt)');
                    }
                  } catch (kx) { console.error('PROF_KICK_ERR ' + String(kx)); }
                  console.error('PROF_GW_BIN_DONE');
                  return r;
                };
                console.error('PROF_GW_ON_BIN_HOOKED');
                return _oldOn.call(G, event, _h);
              }
              return _oldOn.call(G, event, handler);
            };
          }
        } catch (e) { console.error('PROF_GW_ERR ' + String(e)); }
      })();
      // 0.95b 引擎回调探针：wrap api.asc_registerCallback → asc_on* 事件触发打点。
      // 字节装载后引擎走了哪些回调（尤其 ContentReady/OpenDocumentProgress/EndAction/
      // LongAction）——GUI/loading 链靠这些驱动，缺哪个即卡点。
      (function _hCB() {
        try {
          var M = window.SSE && window.SSE.controllers && window.SSE.controllers.Main;
          var api = M && M.api;
          if (!api || typeof api.asc_registerCallback !== 'function') { setTimeout(_hCB, 250); return; }
          if (!api.__cbHooked) {
            api.__cbHooked = true;
            var _reg = api.asc_registerCallback;
            api.asc_registerCallback = function(evt, fn) {
              var _wrapped = function() {
                if (String(evt).indexOf('DocumentContentReady') >= 0
                  || String(evt).indexOf('OpenDocumentProgress') >= 0
                  || String(evt).indexOf('EndAction') >= 0
                  || String(evt).indexOf('LongAction') >= 0
                  || String(evt).indexOf('DocumentReady') >= 0
                  || String(evt).indexOf('DocumentName') >= 0) {
                  console.error('PROF_CB ' + evt);
                }
                return fn.apply(this, arguments);
              };
              return _reg.call(this, evt, _wrapped);
            };
            console.error('PROF_CB_HOOKED');
          }
        } catch (e) {}
      })();
      (function _hLB() {
        try {
          var M = window.SSE && window.SSE.controllers && window.SSE.controllers.Main;
          if (!M) { setTimeout(_hLB, 250); return; }
          if (M.prototype && typeof M.prototype.loadBinary === 'function' && !M.prototype.__lbHooked) {
            M.prototype.__lbHooked = true;
            var _olb = M.prototype.loadBinary;
            M.prototype.loadBinary = function(data) {
              console.error('PROF_LB_IN len=' + (data && data.byteLength));
              var r;
              try { r = _olb.call(this, data); }
              catch (e3) { console.error('PROF_LB_EXC ' + String(e3)); throw e3; }
              console.error('PROF_LB_OUT');
              return r;
            };
            console.error('PROF_LB_HOOKED');
            return;
          }
          var _api = M.api;
          if (_api && typeof _api.asc_openDocumentFromBytes === 'function' && !_api.__dfbHooked) {
            _api.__dfbHooked = true;
            var _o2 = _api.asc_openDocumentFromBytes;
            _api.asc_openDocumentFromBytes = function(data) {
              console.error('PROF_DFB_IN len=' + (data && data.byteLength));
              var r;
              try { r = _o2.apply(this, arguments); }
              catch (e4) { console.error('PROF_DFB_EXC ' + String(e4)); throw e4; }
              console.error('PROF_DFB_OUT');
              return r;
            };
            console.error('PROF_DFB_HOOKED');
            return;
          }
          setTimeout(_hLB, 250);
        } catch (e) {}
      })();
    }
  })();


