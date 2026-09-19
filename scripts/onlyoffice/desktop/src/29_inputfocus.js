// ===========================================================================
// 输入焦点抑制：非 PC 形态下，不让「界面事件」把焦点自动夺回编辑器的隐藏输入代理
// ---------------------------------------------------------------------------
// sdkjs 的文本输入由一个隐藏 textarea（id=area_id，移出视口但可编辑）承接。
// 编辑器为了「保住物理键盘输入」会在多处把 DOM 焦点拉回它，共两条独立路径：
//   1) web-apps 的界面事件（点工具栏 / 关菜单）→ asc_enableKeyEvents(true) →
//      text_input2.js setInterfaceEnableKeyEvents —— 用 sdkjs 自带的守卫
//      isGlobalDisableFocus 关掉这次自动聚焦；
//   2) sdkjs 的 document 级 focus 捕获监听器末段的兜底 focusHtmlElement ——
//      它没有守卫开关可用，且「用户点文档区要输入」走的也是它，故在原型链上按
//      「本次指针按下是否落在文档区」放行 / 吞掉。
// 在 ArkWeb 上，可编辑元素聚焦即拉起系统软键盘：第 1 条是「点工具栏弹键盘」的
// 主因，第 2 条是键盘已隐藏后再点工具栏仍会重弹的原因。
// 第 2 条吞掉聚焦后焦点停在 editor_sdk（文档 canvas 本身不可聚焦），sdkjs 那条
// 依赖 focus 事件的链路就不再被触发——所以点文档区时要主动补一次原生聚焦。
// PC（2in1）保留原行为——那边靠它维持物理键盘输入（键盘事件绑在 HtmlArea 上，
// 失焦即收不到按键）；门控参数由宿主按设备形态追加（EditorPage.editorUrl）。
// ===========================================================================
(function () {
  try {
    if (!/[?&]nofocus=1/.test(window.location.search || '')) { return; }

    var _of = HTMLElement.prototype.focus;

    // g_inputContext 由 sdkjs 初始化时创建（晚于本段），轮询等它就位
    var _n = 0;
    var _t = setInterval(function () {
      var _ic = window.AscCommon && window.AscCommon.g_inputContext;
      if (_ic) {
        _ic.isGlobalDisableFocus = true;
        clearInterval(_t);
        return;
      }
      if (++_n > 600) { clearInterval(_t); }
    }, 100);

    // 「本次指针按下是否落在文档编辑区」：判据与 web-apps 自身一致（Main.js 用
    // closest('#editor_sdk') 区分「点文档」与「点界面」），editor_sdk 是六个编辑器
    // 统一的文档区容器 id。三种指针事件都挂：不同路径下收到的种类不同。
    var _want = false;
    var _inEditor = function (el) {
      try {
        return !!(el && el.closest && el.closest('#editor_sdk'));
      } catch (e2) { return false; }
    };
    var _mark = function (e) {
      try {
        _want = _inEditor(e.target);
        if (_want) {
          // 点文档区 = 用户要输入：canvas 不可聚焦、浏览器不会代劳，而 sdkjs 的
          // 聚焦链路依赖焦点事件（已被本段吞掉），这里补一次原生聚焦。
          var _ic = window.AscCommon && window.AscCommon.g_inputContext;
          var _ha = _ic && _ic.HtmlArea;
          if (_ha && document.activeElement !== _ha) { _of.apply(_ha, []); }
        }
      } catch (e3) { }
    };
    document.addEventListener('pointerdown', _mark, true);
    document.addEventListener('mousedown', _mark, true);
    document.addEventListener('touchstart', _mark, true);

    HTMLElement.prototype.focus = function () {
      if (this && this.id === 'area_id' && !_want) { return; }
      return _of.apply(this, arguments);
    };
  } catch (e) { }
})();
