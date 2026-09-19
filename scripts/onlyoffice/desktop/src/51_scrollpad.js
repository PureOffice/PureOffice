// ---- 触摸拖拽滚动条：capture 层坐标接管（pointer 流转发 + 双流拦截）----
// 编辑器滚动条 = sdkjs ScrollObject 在 14px 窄容器内自画的 canvas（拖拽逻辑齐全，
// canvas.that 即实例）。真机打点实证：ArkWeb 的触摸 target 判定会跳过这个窄
// canvas——elementFromPoint 正确命中、touch target 却穿透给两侧元素，且分界线随
// 页面状态波动，DOM 代理层无法稳定拦截。因此改为 document capture 阶段按
// 「触点坐标 ∈ 滚动条矩形」接管。
// 同一次触摸有两条事件流（pointerdown 先于 touchstart），只转发 pointer 流驱动
// 引擎；touch 流在命中/拖拽中仅拦截（stopPropagation+preventDefault），否则
// overlay 收到 pointer 会开始编辑器自己的手势，与滚动条拖拽互相拉扯（真机实测
// 表现为滚动条跟手一点后被拖回原位）。
// 矩形每次按下动态读取 canvas rect（含外扩容错），自适应布局与折叠形态切换；
// canvas display:none（内容不超屏）时 rect 为 0 自然跳过。PC 鼠标同样经此转发
// （与触摸同路径），未按下时的 hover 移动不拦截，原生行为保留。
// 覆盖：word/slide 主纵条与横条（id_*）、cell 纵横条（ws-*-scrollbar）。
(function () {
    // 页门控：仅编辑器页（欢迎页无滚动条容器）
    var _pp = (window.location || {}).pathname || '';
    if (_pp.indexOf('/main/index.html') < 0) { return; }

    var BARS = [
        'id_vertical_scroll', 'ws-v-scrollbar',
        'id_horizontal_scroll', 'ws-h-scrollbar'
    ];
    // 按压中心抖动容错：滚动条右缘紧贴属性按钮栏、横条下缘紧贴状态栏，外扩只留
    // 小量，避免吞掉邻区交互
    var EXT = 8;

    // 手势竞争抑制：scroll.js 只写了 msTouchAction（IE 旧前缀，Chromium 无效）；
    // 容器随 cell 视图重建，故常驻补设
    var iv = setInterval(function () {
        for (var i = 0; i < BARS.length; i++) {
            var holder = document.getElementById(BARS[i]);
            if (holder && !holder.__lso_ta) {
                var canvas = holder.querySelector('canvas');
                if (!canvas) continue;
                holder.style.touchAction = 'none';
                canvas.style.touchAction = 'none';
                holder.__lso_ta = true;
            }
        }
    }, 2000);

    // —— capture 层坐标接管（pointer 流）——
    var drag = null; // 拖拽中：{ canvas }
    var hitBar = function (x, y) {
        for (var i = 0; i < BARS.length; i++) {
            var holder = document.getElementById(BARS[i]);
            if (!holder) continue;
            var canvas = holder.__cv || (holder.__cv = holder.querySelector('canvas'));
            if (!canvas || !canvas.that) continue;
            var r = canvas.getBoundingClientRect();
            if (r.width < 2 && r.height < 2) continue; // 隐藏/未布局
            if (x >= r.left - EXT && x <= r.right + EXT && y >= r.top - EXT && y <= r.bottom + EXT)
                return canvas;
        }
        return null;
    };
    var fwd = function (name, e, canvas) {
        // PointerEvent 带 clientX/Y，与原生 ontouchstart 传入的 Touch 对象接口兼容
        // （引擎处理器只读 clientX/clientY）
        try { canvas.that[name](e); } catch (x) {}
    };

    document.addEventListener('pointerdown', function (e) {
        if (drag) { e.preventDefault(); e.stopPropagation(); return; }
        var canvas = hitBar(e.clientX, e.clientY);
        if (!canvas) return;
        drag = { canvas: canvas };
        fwd('evt_mousedown', e, canvas);
        e.preventDefault();
        e.stopPropagation();
    }, true);
    document.addEventListener('pointermove', function (e) {
        if (!drag) return;
        fwd('evt_mousemove', e, drag.canvas);
        e.preventDefault();
        e.stopPropagation();
    }, true);
    var onUp = function (e) {
        if (!drag) return;
        fwd('evt_mouseup', e, drag.canvas);
        drag = null;
        e.preventDefault();
        e.stopPropagation();
    };
    document.addEventListener('pointerup', onUp, true);
    document.addEventListener('pointercancel', onUp, true);

    // —— touch 流：命中/拖拽中仅拦截，防合成鼠标与 target 侧派发（不转发）——
    document.addEventListener('touchstart', function (e) {
        if (drag || hitBar(e.touches[0].clientX, e.touches[0].clientY)) {
            e.preventDefault();
            e.stopPropagation();
        }
    }, true);
    document.addEventListener('touchmove', function (e) {
        if (drag) { e.preventDefault(); e.stopPropagation(); }
    }, true);
    var onTEnd = function (e) {
        if (drag) { e.preventDefault(); e.stopPropagation(); }
    };
    document.addEventListener('touchend', onTEnd, true);
    document.addEventListener('touchcancel', onTEnd, true);
    try { console.log('LSO_SCROLLCAP armed'); } catch (x) {}
})();
