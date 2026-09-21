    // ---- 3.55 M7 自动化验收工具（?m7auto=1 时编辑器就绪后自动插入文本并序列化保存；
    //      ?m7open=<name> 时欢迎页自动 open:recent 对应沙箱文件 —— 用于真机自动化验证
    //      打开/保存链（uitest 无法向 contenteditable 输字、无法注入系统 picker 列表交互）。
    //      产品路径不拼该参数 → 不生效；2026-09-04 已验证 docx：M7AUTO-EDIT-OK 进 save.docx
    //      word/document.xml，xlsx/pptx 同段（asc_PasteData Text=1 引擎常量） ----
    // ---- 3.55a 装载链探针（m7img 态附带）：cell 的文档图不显示，缺口指向"装载时没把
    //      drawing 对象注册进 worksheet"（判据 M7IMG_DARR/WSD 在插入一张后均为 1）。
    //      这里 hook 装载侧的两个必经点：DrawingObjects.createDrawingObject（ReadDrawings
    //      里 new 出来后立刻调用 → 出现即说明 bin 的 drawing 段确实被读）与
    //      DrawingBase.initAfterSerialize（注册进 ws.Drawings 的唯一入口，前置三个早退：
    //      无 graphicObject / 图片缺 spPr / IsHiddenObj）。只打点不改行为。
    if (/[?&]m7img=/i.test(window.location.search) && !window.__lsoIASHook) {
      window.__lsoIASHook = true;
      (function _hookLoadProbe() {
        var _n = 0;
        var _tick = function () {
          _n++;
          var AF = window.AscFormat;
          // DrawingBase 由 DrawingObjects.js:4936 `window["AscFormat"].DrawingBase = ...` 导出
          //（createDrawingObject 是**实例**方法 `_this.createDrawingObject`，不能按 prototype
          //  探测——照那个写会永远轮询不上）
          var DB = AF && AF.DrawingBase;
          if (!DB || !DB.prototype || typeof DB.prototype.initAfterSerialize !== 'function') {
            if (_n < 300) { setTimeout(_tick, 300); }
            return;
          }
          if (DB.prototype.__lsoIAS) { return; }
          DB.prototype.__lsoIAS = true;
          var _origI = DB.prototype.initAfterSerialize;
          DB.prototype.initAfterSerialize = function (ws) {
            try {
              var go = this.graphicObject;
              var oX = go && go.spPr && go.spPr.xfrm;
              console.error('LSO_IAS enter go=' + (!!go) + ' ws=' + (!!ws)
                + ' img=' + (!!(go && go.isImage && go.isImage()))
                + ' shp=' + (!!(go && go.isShape && go.isShape()))
                + ' spPr=' + (!!(go && go.spPr))
                + ' xfrm=' + (!!oX)
                + ' del=' + ((go && go.getBDeleted) ? go.getBDeleted() : '?'));
            } catch (e) { console.error('LSO_IAS_P_ERR ' + String(e)); }
            // 三个早退条件已在入口验完（实测 img/spPr 都成立），若对象仍未注册即说明
            // 函数后半段被打断——this.from/this.to 为 null 时 `this.from.initAfterSerialize()`
            // 会抛，异常吞在装载流程里就是"对象凭空消失"。这里抓出来。
            var _from = this.from, _to = this.to;
            var _r;
            try {
              _r = _origI.apply(this, arguments);
            } catch (ex2) {
              console.error('LSO_IAS THROW from=' + (!!_from) + ' to=' + (!!_to)
                + ' err=' + String(ex2));
              return _r;
            }
            console.error('LSO_IAS after from=' + (!!_from) + ' to=' + (!!_to)
              + ' pushed=' + ((ws && ws.Drawings) ? ws.Drawings.length : '?'));
            return _r;
          };
          console.error('LSO_LOADPROBE_HOOKED db=' + (!!DB));
        };
        setTimeout(_tick, 300);
      })();
    }

    if (/[?&]m7auto=1(&|$)/.test(window.location.search) && !window.__m7auto) {
      window.__m7auto = true;
      (function() {
        var _n = 0;
        var _getApi = function() {
          // 优先 Main.api（asc_docs_api/spreadsheet_api/presentation_api 实例真实挂点；
          // word 经 Asc.editor 同物，cell 的 Asc.editor 不保证是 spreadsheet_api）
          try {
            var _p = window.location.pathname || '';
            var _ns = _p.indexOf('/spreadsheeteditor/') >= 0 ? 'SSE'
              : _p.indexOf('/presentationeditor/') >= 0 ? 'PE' : 'DE';
            var _m = window[_ns] && window[_ns].controllers && window[_ns].controllers.Main;
            if (_m && _m.api) { return _m.api; }
          } catch (x) {}
          var _e2 = window.Asc && window.Asc.editor ? window.Asc.editor : window.editor;
          if (_e2 && typeof _e2 === 'object') { return _e2; }
          return null;
        };
        var _doSave = function() {
          // 直接序列化（等同 asc_Save 覆写后半程；绕开守卫的 isLongAction —— 文档加载
          // 长事务不结束（模型已就绪可读可写），守卫式保存永远打不穿）。
          // 事件到达（asc_onDocumentContentReady）即加载终了 → 不再延时（旧 2500ms 是
          // 配合轮询判据的缓冲，事件语义下不需要）。
          try {
            var _ap2 = _getApi();
            // 与保存链共用 __ohosWithNativeSaveEnd（临时挂 Native.Save_End 换挂逻辑
            // 的单一点；2026-09-21 fork 化后定义在 sdkjs apiBase.js [OHOS: save] 块）
            var _nb2 = window.__ohosWithNativeSaveEnd(function() {
              return _ap2.asc_nativeGetFileData();
            });
            if (_nb2 && _nb2.byteLength) {
              // m7autosave=1 → userFlag=0（autosave 语义；引擎 _autoSave 走的就是这条）：
              // 用于回归「autosave 不得回写不能原地保存的格式源文件」这条数据安全不变量
              var _uf = /[?&]m7autosave=1(&|$)/.test(window.location.search) ? 0 : 1;
              var _rr = String(window.AscNative && window.AscNative._call('execCommand', ['save:bin', window.__lsoB64(_nb2), _uf]));
              console.error('M7AUTO_DIRECT_SAVE len=' + _nb2.byteLength + ' user=' + _uf + ' ret=' + _rr);
            } else {
              console.error('M7AUTO_DIRECT_EMPTY');
            }
          } catch (x) { console.error('M7AUTO_DIRECT_ERR ' + String(x)); }
        };
        // 插入图片（m7img=1 专用）：构造 File 对象喂给 sdkjs 的**上传汇合点**
        // （AscCommon.UploadImageFiles —— <input type=file> 选完文件之后的同一条路；
        // 只跳过系统 picker 一步，picker 需要手指、uitest 注入不了）。返回的 URL 再走
        // _addImageUrl 进模型（等同 _uploadCallback 的后半程）。
        var _insertImage = function(_ap, done) {
          var _PNG = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAeklEQVR4nO3ZwQmDQABFQQ0WZXch3dmV3sVDSMSHOHNcWPiPPe4wAJTGg7NlvXzG1+b94Fcy40QCagJqAmoCagJqAmrTP5fX+XPKiHF5/3z39i8goCagJqAmoCagJqAmoCagJqAmoCag5peyJqAmoCagJqAmoCYA4Nk2q3UHadIXJqMAAAAASUVORK5CYII=';
          var _n = 0;
          var _tick = function() {
            _n++;
            var AC = window.AscCommon;
            if (!AC || typeof AC.UploadImageFiles !== 'function') {
              if (_n < 200) { setTimeout(_tick, 200); } else { console.error('M7IMG_GIVEUP'); done(); }
              return;
            }
            try {
              var _bin = atob(_PNG);
              var _arr = new Uint8Array(_bin.length);
              for (var i = 0; i < _bin.length; i++) { _arr[i] = _bin.charCodeAt(i); }
              var _f = new File([_arr], 'm7insert.png', { type: 'image/png' });
              AC.UploadImageFiles([_f], '', '', '', '', '', '', function(err, urls) {
                console.error('M7IMG_UPLOAD err=' + err + ' urls=' + JSON.stringify(urls));
                try {
                  // cell 走 asc_addImageDrawingObject：`_addImageUrl(urls, {})` 对它是**空
                  // 操作**——cell 的 _addImageUrl 最终调 wbModel.addImages()，而后者只在
                  // obj.id / obj.callback 存在时才真正插入（Workbook.js:3733），空对象
                  // 什么都不做（图不进模型 → 不绘制也不进产物）。asc_...DrawingObject 进
                  // objectRender 的绘制对象表，是 cell 的正路。word/slide 无此 API，保持原路。
                  if (_ap && typeof _ap.asc_addImageDrawingObject === 'function') {
                    _ap.asc_addImageDrawingObject(urls);
                    console.error('M7IMG_INSERTED cell');
                  } else if (_ap && typeof _ap._addImageUrl === 'function') {
                    _ap._addImageUrl(urls, {});
                    console.error('M7IMG_INSERTED');
                  } else { console.error('M7IMG_NOAPI'); }
                } catch (e) { console.error('M7IMG_INS_ERR ' + String(e)); }
                // 判别探针：cell 的浮动对象绘制链断点定位（xlsx 图片排查——媒体已供给
                // 且被请求、主动 ws.draw() 也无效，说明断在"对象↔图片数据"的关联上）。
                // 一次采全：objectRender/drawingDocument/drawingObjects 是否就位、对象表
                // 里有几个、首个对象有没有 Image、ImageLoader 能否按 URL 取回带 Image 的项。
                setTimeout(function () {
                  try {
                    var _wb2 = _ap.wb;
                    var _ws2 = (_wb2 && typeof _wb2.getWorksheet === 'function') ? _wb2.getWorksheet() : null;
                    var _or = _ws2 && _ws2.objectRender;
                    var _doc = _or && _or.drawingDocument;
                    var _ctrl = _or && _or.controller;
                    var _dobjs = _ctrl && _ctrl.drawingObjects;
                    var _objs = _dobjs && _dobjs.objects;
                    var _n = -1;
                    if (_objs) { _n = (_objs.length !== undefined) ? _objs.length : Object.keys(_objs).length; }
                    var _img = _ap.ImageLoader ? _ap.ImageLoader.LoadImage('_offline_media/insert1.png', 1) : null;
                    console.error('M7IMG_ORP ws=' + (!!_ws2) + ' or=' + (!!_or) + ' dd=' + (!!_doc)
                      + ' ctrl=' + (!!_ctrl) + ' dobjs=' + (!!_dobjs) + ' objs=' + _n
                      + ' imgL=' + (!!_img) + ' imgL.Image=' + (!!(_img && _img.Image))
                      + ' imgL.src=' + ((_img && _img.src) || ''));
                    if (_objs && _objs.length) {
                      var _o0 = _objs[0];
                      console.error('M7IMG_OBJ0 img=' + (!!(_o0 && _o0.Image))
                        + ' src=' + ((_o0 && _o0.Image && _o0.Image.src) || '')
                        + ' type=' + ((_o0 && _o0.getObjectType) ? _o0.getObjectType() : '?'));
                    }
                    // 对象表字段名未知（objects=-1）：采样三个候选容器上的数组型字段，
                    // 找出真正装 drawing 对象的那一个——对象表为空即说明"bin 解析没建对象"
                    //（区别于"建了但没绘制"），这是本缺口最关键的分叉判据。
                    var _out = [];
                    var _scan = function (o, tag) {
                      var _c = 0;
                      for (var kk in o) {
                        try {
                          var vv = o[kk];
                          if (Array.isArray(vv)) {
                            _out.push(tag + '.' + kk + '=' + vv.length);
                            if (++_c > 6) { break; }
                          }
                        } catch (e2) { }
                      }
                    };
                    if (_dobjs) { _scan(_dobjs, 'dobjs'); }
                    if (_ctrl) { _scan(_ctrl, 'ctrl'); }
                    if (_doc) { _scan(_doc, 'doc'); }
                    console.error('M7IMG_SCAN ' + _out.slice(0, 18).join(' | '));
                    // 绘制对象表（cell 的入口是 controller.getDrawingArray → drawingObjects
                    // .getDrawingObjects）：装载后为 0 即说明 bin→对象的**装载**阶段没建对象
                    //（与插入路径对照——插入走 objectRender.addImageDrawingObject 是通的）
                    var _darr = (_ctrl && typeof _ctrl.getDrawingArray === 'function')
                      ? _ctrl.getDrawingArray() : null;
                    var _dl = -1;
                    if (_darr) { _dl = (_darr.length !== undefined) ? _darr.length : -2; }
                    console.error('M7IMG_DARR ' + (_darr ? ('len=' + _dl) : 'noapi'));
                    // ws.Drawings = 装载时 DrawingBase.initAfterSerialize 的注册点
                    //（Charts/DrawingObjects.js:1879）。它为 0 即说明装载读出的 drawing
                    // 在三个早退条件（无 graphicObject / 图片缺 spPr / IsHiddenObj）上被丢掉，
                    // 对象从未成为 worksheet 的绘制对象——这就是"文档图不显示"的落点。
                    // 注意取 **model** 的 Drawings：getWorksheet() 给的是 WorksheetView，
                    // 注册点在 Worksheet（model）上（Serialize.js:11379 `oWorksheet.Drawings.push`）
                    var _mdl = _ws2 && _ws2.model;
                    var _wdr = (_mdl && _mdl.Drawings) ? _mdl.Drawings.length : -1;
                    console.error('M7IMG_WSD mdl=' + (!!_mdl) + ' wsDrawings=' + _wdr);
                    // 文档图已注册进 ws.Drawings 却不请求媒体也不绘制 → 试"显示绘制对象"
                    // 入口（clipboard 在增删对象后调它，cell/api.js 里也用它刷新）。
                    // 对象首张的 Image 是否为 null 一并报出，用于区分"没触发加载"与"加载了没画"。
                    try {
                      var _d0 = (_wdr > 0 && _mdl.Drawings[0]) ? _mdl.Drawings[0] : null;
                      var _g0 = _d0 && _d0.graphicObject;
                      console.error('M7IMG_OBJ0 go=' + (!!_g0)
                        + ' img=' + (!!(_g0 && _g0.Image))
                        + ' blip=' + (!!(_g0 && _g0.blipFill && _g0.blipFill.blip))
                        + ' src=' + ((_g0 && _g0.Image && _g0.Image.src) || ''));
                    } catch (e3) { console.error('M7IMG_OBJ0_ERR ' + String(e3)); }
                    // 修复前提：对象上还剩哪些能推出图片名的字段（bin 里该段字节与 pptx 版
                    // 完全相同，说明 cell 读取器在 pptxDrawing 分支漏了 blipFill，但 rId/名
                    // 可能在别的字段上留了下来）
                    try {
                      var _d0b = (_wdr > 0 && _mdl.Drawings[0]) ? _mdl.Drawings[0] : null;
                      var _g0b = _d0b && _d0b.graphicObject;
                      var _ka = [];
                      for (var _k1 in _d0b) { _ka.push(_k1); }
                      var _kb = [];
                      for (var _k2 in _g0b) {
                        if (/[Ii]mage|[Bb]lip|[Pp]ic|[Uu]rl|[Ss]rc|[Rr]Id/.test(_k2)) { _kb.push(_k2); }
                      }
                      console.error('M7IMG_KEYS d0=[' + _ka.slice(0, 18).join(',')
                        + '] g0=[' + _kb.slice(0, 18).join(',') + ']');
                    } catch (e5) { console.error('M7IMG_KEYS_ERR ' + String(e5)); }
                    // blipFill 本身存在（见 M7IMG_KEYS），缺的是它的 blip 子对象——查
                    // blipFill 里还剩什么、以及 getImageUrl() 这个绘制侧真正取 URL 的入口返回什么
                    try {
                      var _g0c = (_wdr > 0 && _mdl.Drawings[0]) ? _mdl.Drawings[0].graphicObject : null;
                      var _bfx = _g0c && _g0c.blipFill;
                      var _fk = [];
                      for (var _k4 in _bfx) { _fk.push(_k4); }
                      var _u = (_g0c && typeof _g0c.getImageUrl === 'function')
                        ? String(_g0c.getImageUrl()) : 'nofn';
                      console.error('M7IMG_BF url=' + _u + ' bf=[' + _fk.slice(0, 14).join(',') + ']');
                      // Drawings[0] 未必是文档图（插入的图也在同一表里）——逐个列出对象与
                      // 它们的图片 URL / RasterImageId（后者是 blipFill 里的图片标识，若文档图
                      // 的这个字段有值，就说明引用读到了、缺的只是"谁来把它变成 URL"）
                      var _all = [];
                      for (var _i2 = 0; _i2 < _wdr && _i2 < 6; _i2++) {
                        var _ob2 = _mdl.Drawings[_i2];
                        var _gg2 = _ob2 && _ob2.graphicObject;
                        var _uu2 = (_gg2 && typeof _gg2.getImageUrl === 'function')
                          ? String(_gg2.getImageUrl()) : 'nofn';
                        var _rid2 = (_gg2 && _gg2.blipFill)
                          ? String(_gg2.blipFill.RasterImageId || '(nil)') : '(nobf)';
                        _all.push(_i2 + ':url=' + _uu2 + ' rid=' + _rid2);
                      }
                      console.error('M7IMG_ALL ' + _all.join(' | '));
                      // 关键分叉：getWorksheet() 只给**活动** sheet，而文档的图由 x2t 挂在
                      // 它所属的那张表上（我们这份 xlsx 有 3 个 sheet，图在 sheet1）。
                      // 列出所有 sheet 的 Drawings 数量即可判断"文档图在别的表"还是"确实没建"。
                      var _sk = [];
                      try {
                        var _wbm = _wb2.model;
                        var _arr2 = _wbm && (_wbm.worksheets || _wbm.aWorksheets || _wbm.sheets);
                        if (_arr2) {
                          for (var _s2 = 0; _s2 < _arr2.length && _s2 < 8; _s2++) {
                            var _sh2 = _arr2[_s2];
                            var _nm2 = (_sh2 && _sh2.getName) ? String(_sh2.getName()) : String(_s2);
                            _sk.push(_nm2 + '=' + ((_sh2 && _sh2.Drawings) ? _sh2.Drawings.length : 'x'));
                          }
                        }
                      } catch (e7) { _sk.push('ERR ' + String(e7)); }
                      var _cur = (_mdl && _mdl.getName) ? String(_mdl.getName()) : '?';
                      console.error('M7IMG_SHEETS cur=' + _cur + ' all=[' + _sk.join(',') + ']');
                    } catch (e6) { console.error('M7IMG_BF_ERR ' + String(e6)); }
                    try {
                      var _or2 = _ws2 && _ws2.objectRender;
                      if (_or2 && typeof _or2.showDrawingObjects === 'function') {
                        _or2.showDrawingObjects();
                        console.error('LSO_SHOWDO called');
                      } else { console.error('LSO_SHOWDO noapi'); }
                    } catch (e4) { console.error('LSO_SHOWDO_ERR ' + String(e4)); }
                  } catch (e) { console.error('M7IMG_ORP_ERR ' + String(e)); }
                }, 900);
                setTimeout(done, 1500);   // 留一拍给模型装载与渲染再保存
              });
            } catch (e) { console.error('M7IMG_ERR ' + String(e)); done(); }
          };
          setTimeout(_tick, 300);
        };
        var _onDocReady = function() {
          try {
            var _ap = _getApi();
            // 官方事件 asc_onDocumentContentReady（apiBase.js:1519）已证文档加载完成
            // （=旧轮询判据 private_GetLogicDocument/wbModel 的等价且更权威时机）
            var _ftq = (String(window.location.search).match(/[?&]fileType=([^&]+)/) || [])[1] || 'docx';
            // m7img：插入图片后保存（验证"插入的图进模型 → 渲染供给 → 进保存产物"）。
            // =2 时插入后再撤销——验证**模型回退后保存产物不含该图**（删除链的另一半：
            // 保存按模型引用打包，模型里没有的图不会被打进产物；真机选中→按键删除的
            // 交互层由手指验证）。
            var _mimg = (String(window.location.search).match(/[?&]m7img=([123])(&|$)/) || [])[1];
            if (_mimg) {
              _insertImage(_ap, function() {
                if (_mimg === '2') {
                  try {
                    // 三编辑器的撤销导出名不同：word/slide 是 Undo，cell 另有 asc_Undo
                    var _uf2 = (typeof _ap.Undo === 'function') ? _ap.Undo
                      : (typeof _ap.asc_Undo === 'function' ? _ap.asc_Undo : null);
                    if (_uf2) {
                      _uf2.call(_ap);
                      console.error('M7IMG_UNDONE');
                    } else { console.error('M7IMG_NOUNDO'); }
                  } catch (ue) { console.error('M7IMG_UNDO_ERR ' + String(ue)); }
                  setTimeout(_doSave, 1500);
                  return;
                }
                _doSave();
              });
              return;
            }
            var _insOk = false;
            if (_ftq === 'docx' && _ap && typeof _ap.asc_AddText === 'function') {
              // docx：插入文本+保存（验证编辑内容进保存产物）
              _ap.asc_AddText('M7AUTO-EDIT-OK', null);
              _insOk = true;
            }
            // cell/slide（_ftq !== 'docx'）：不插入 —— asc_PasteData 需要 WorkbookView(wb，
            // GUI 懒建，v13 已知 toolbar 未 init) —— 直接序列化"已打开模型"（未修改同样产出
            // 完整文件，验证 xlst_bin2xlsx/pptt_bin2pptx 落盘链）
            if (_insOk) {
              console.error('M7AUTO_INSERTED ft=' + _ftq);
              _doSave();
              return;
            }
            console.error('M7AUTO_SAVE_DIRECT ft=' + _ftq);
            _doSave();
          } catch (x) { console.error('M7AUTO_ACCEPT_ERR ' + String(x)); }
        };
        var _reg = function() {
          var _ap = _getApi();
          // 等 API 对象就绪（等对象而非等模型/界面元素——官方 api 出现于 onLaunch 完成）
          if (!_ap || typeof _ap.asc_registerCallback !== 'function') { setTimeout(_reg, 300); return; }
          try {
            _ap.asc_registerCallback('asc_onDocumentContentReady', function() {
              console.error('M7AUTO_DOC_READY');
              _onDocReady();
            });
          } catch (e) { console.error('M7AUTO_REG_ERR ' + String(e)); }
        };
        setTimeout(_reg, 1200);
      })();
    }

    // ---- 3.55b 欢迎页 m7open 验收段：?m7open=<name>（如 m7-open-test.docx / sample.xlsx）——
    //      欢迎页面加载就绪后自动发官方 open:recent（路径 = 沙箱 filesDir/<name>），等价
    //      「打开本地文件 → 用户点选该文件」；与 3.55 m7auto 配套做全自动开关验收链。
    //      门控：URL 带 m7open 参数才触发（产品 URL 无此参数 = 零代价）——M7OPEN_COND 打点
    //      仅在参数存在时输出（2026-09-05：原无条件打点改为参数内）。 ----
    if (/[?&]m7open=([^&]+)/.test(window.location.search) && !window.__m7open) {
      var _m7f = (String(window.location.search).match(/[?&]m7open=([^&]+)/) || [])[1];
      _m7f = decodeURIComponent(_m7f);
      window.__m7open = true;
      try { console.error('M7OPEN_COND search=' + window.location.search + ' sdk=' + typeof (window.sdk && window.sdk.command) + ' asc=' + !!window.AscNative); } catch (cb) {}
      (function() {
        var _t2 = 0;
        var _try2 = function() {
          try {
            if (window.sdk && window.sdk.command && window.AscNative && window.AscNative._call) {
              var _fd2 = String(window.AscNative._call('getFilesDir', []) || '');
              // type 由壳层给定（EditorPage 按 formats 表推导并拼 m7type=<hex>）——
              // 页面不再自持第二份格式表；无参数（旧 URL）兜底 docx 仅供兼容
              var _tq2 = String(window.location.search).match(/[?&]m7type=([0-9a-fA-F]+)/);
              var _type2 = _tq2 ? parseInt(_tq2[1], 16) : 0x41;
              window.sdk.command('open:recent', JSON.stringify({
                id: 99, name: _m7f, path: _fd2 + '/' + _m7f, type: _type2
              }));
              console.error('M7OPEN_SENT name=' + _m7f + ' path=' + _fd2 + '/' + _m7f);
              return;
            }
          } catch (x) { console.error('M7OPEN_ERR ' + String(x)); }
          // 窗口说明（2026-09-04 回退）：loginpage 正常 1-2s 就绪（实测），20×600ms=12s 足够；
          // 曾放大至 250 次（150s）拖延主线程加重白屏——已回退。
          if (++_t2 < 20) { setTimeout(_try2, 600); }
          else { console.error('M7OPEN_TIMEOUT'); }
        };
        setTimeout(_try2, 1300);
      })();
    }

    // （3.4 DI 打开链主体已于 2026-09-21 fork 化阶段 2-i 源码化，三处分置：
    //   ① 启动链主体（editorConfig 构造/loadConfig+controller 补发/DI 链/权限
    //     分发）→ 宿主装配域 ohos/boot.js（scripts/onlyoffice/ohos/，装配进
    //     rawfile/onlyoffice/ohos/ 并由编辑器 main/index.html 注入）
    //   ② AI 插件 backgroundBtn 修复 → web-apps fork Plugins.js
    //     onResetPlugins [OHOS: plugins]（官方缺口源码修复：按钮缺失时按官方
    //     addBackgroundPluginsButton 同款补建）
    //   ③ 字族下拉归一 → sdkjs fork apiBase.js [OHOS: fonts]（2-h2）
    //   本段仅余 m7 验收工具三块（3.55/3.55a/3.55b）——阶段 4 smoke 外置）

    // （3.9 文件菜单「新建」desktop:// 拦截已于 2026-09-21 fork 化阶段 2-h1
    //   源码化：五编辑器 LeftMenu.js onCreateNew [OHOS: create] 分支——只拦
    //   desktop:// 协议转壳层 create:new 命令，其余 URL 原样 window.open。
    //   window.open 全局覆写退役）

    // （40_save 段已整段退役（2026-09-21 阶段 2-k）：最后一块实质内容 3.9 头部
    //   装饰（btnClose/用户头像圈/左上 logo 三处 DOM 隐藏 MutationObserver）→
    //   web-apps fork common/Header.js [OHOS: header] 渲染点直改（getPanel left
    //   槽隐藏/elUserName 保持 hidden/btnClose 不创建——五编辑器共用一份）。
    //   其余块（3.7/3.7.1/3.8 系）此前已分批迁 ohos/bridge.js 与 fork 源码）
    //（外层 IIFE 闭合在此：40_save 整段退役后由本段收尾——原 50_init→40_save 链）
})();

