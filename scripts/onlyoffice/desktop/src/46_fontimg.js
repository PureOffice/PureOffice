  // ---- 用户字体名字图（2026-09-18 用户决策：页面侧 canvas 复刻）----
  //      背景：字体下拉每一项显示的是「用该字体渲染的名字」——UI 侧的实现是**精灵图的
  //      一格**（构建期 make_fonts_sprites 逐格渲染；官方桌面版则由 native 在运行时生成
  //      整张表和这些图，见 sdk-all checkAllFonts 开头的 window.native.GenerateAllFonts
  //      分支——我们走构建期静态表，触不到它）。用户导入字体是运行时才有的，精灵里没
  //      它的格子 → 下拉项文字空白（项在、可选、引擎渲染正常，只是名字不可见；空白格
  //      由 build_editors_ohos.make_fonts_sprites 预留，30_open 让用户字体的
  //      CFont.thumbnail 指向它）。本段复刻官方那步"运行时生成"。
  //
  //      **为什么 wrap updateVisibleFontsTiles**：这是列表渲染的真路径（ComboBoxFonts
  //      的方法对象 → prototype 上），循环里 `me.store.at(j).get('name')` 直接给出当前
  //      项字体名、`me.tiles[j]` 就是那个 canvas 元素——名字与图一一对应，无需任何推断。
  //      曾试过 wrap getImageUri（无效：那是工具栏路径，列表不走它），也试过 DOM 替换
  //      （要自己维护"第几项对应哪个字体名"的映射，滚动懒加载重建时易错），均弃。
  //      **不新建 canvas**：直接在官方那张上重画——内部尺寸（300×28 档，由 ratio 定）、
  //      CSS 尺寸、DOM 位置全部继承，滚动重绘（tiles[j] 置 null → 重建）也会再次命中。
  //      画的只是**名字标识**，默认字体即可：字体真实效果由引擎渲染，与此图无关。
  (function _userFontNameImage() {
    try {
      var _p = (window.location || {}).pathname || '';
      if (_p.indexOf('/main/index.html') < 0) { return; }
      var _isUser = function(n) {
        var _uf = window.__lso_user_font_names || [];
        for (var _i = 0; _i < _uf.length; ++_i) { if (_uf[_i] === n) { return true; } }
        return false;
      };
      // 官方精灵格的画法（见 make_fonts_sprites）：格高 28 档、字 20px、左起 10px、
      // 黑字透明底。此处按 canvas 实际尺寸等比换算（ratio 档不同时同样成立）。
      var _fixTiles = function(me) {
        try {
          if (!(window.__lso_user_font_names || []).length) { return; }
          if (!me || !me.store || !me.tiles) { return; }
          for (var j = 0; j < me.store.length; ++j) {
            var _cv = me.tiles[j];
            if (!_cv || !_cv.getContext) { continue; }
            if (_cv.getAttribute && _cv.getAttribute('data-lso-uf') === '1') { continue; }
            var _nm = String(me.store.at(j).get('name') || '');
            if (!_isUser(_nm)) { continue; }
            var _cx = _cv.getContext('2d');
            if (!_cx) { continue; }
            _cx.clearRect(0, 0, _cv.width, _cv.height);
            _cx.fillStyle = '#000000';
            _cx.font = Math.max(10, Math.round(_cv.height * 0.71)) + 'px sans-serif';
            _cx.textBaseline = 'middle';
            _cx.fillText(_nm, Math.round(_cv.width / 30), Math.round(_cv.height / 2));
            if (_cv.setAttribute) { _cv.setAttribute('data-lso-uf', '1'); }
            console.error('LSO_UFONT_IMG drawn j=' + j + ' name=' + _nm
              + ' canvas=' + _cv.width + 'x' + _cv.height);
          }
        } catch (_fe) { console.error('LSO_UFONT_IMG_FIX_ERR ' + String(_fe)); }
      };
      var _tries = 0;
      (function _wait() {
        var _C = window.Common && Common.UI && Common.UI.ComboBoxFonts;
        var _proto = _C && _C.prototype;
        if (!_proto || typeof _proto.updateVisibleFontsTiles !== 'function') {
          if (++_tries < 600) { setTimeout(_wait, 200); return; }
          console.error('LSO_UFONT_IMG_NOPROTO');
          return;
        }
        if (_proto.updateVisibleFontsTiles.__lsoUfWrapped) { return; }
        var _ori = _proto.updateVisibleFontsTiles;
        var _wrapped = function() {
          var _r = _ori.apply(this, arguments);
          _fixTiles(this);
          return _r;
        };
        _wrapped.__lsoUfWrapped = true;
        _proto.updateVisibleFontsTiles = _wrapped;
        console.error('LSO_UFONT_IMG hooked');
        (window.__lsoShim = window.__lsoShim || []).push('fontimg');
      })();
    } catch (e3) { console.error('LSO_UFONT_IMG_OUTER ' + String(e3)); }
  })();
