  // ==========================================================================
  // 4.8 宿主预解包文档媒体（xlsx 图片显示的前置条件）
  // ==========================================================================
  // 背景：x2t 打开 pptx/docx 时会把 `ppt/media/*`、`word/media/*` 解包到工作目录
  //（`<tabDir>/media/`），渲染链按 `_offline_media/<name>` 找我们供给；但 **xlsx
  // 不会**——`xl/media/*` 既不进工作目录、bin 里却留着 `image1.png` 引用，引擎渲染
  // floating object 时无从取图（2026-09-12 真机截图实证：表格正常、图缺失）。
  //
  // 本段补这一步：页面加载时（早于文档注入，故早于任何图片请求）拉源文件字节，
  // 就地解析 zip 的中央目录，把 `*/media/*` 逐个解出 → base64 → 桥 media:unpack
  // 落到**本 tab** 的 media/ 目录（名字保持 zip 内原名——bin 里的引用就是这个名字，
  // 改名等于对不上）。
  //
  // 不做的事：不依赖 x2t 的格式差异（对 pptx/docx 也能跑，同名覆盖内容一致、无害）；
  // 不用 window.native 冒充 native 引擎（语义面过大，见 47_img 头注）；不引第三方
  // zip 库（中央目录 + deflate-raw 各几十行，浏览器原生 DecompressionStream 足够）。
  //
  // 触发条件：URL 带 `&src=<源文件名>`（EditorPage 在编辑器 URL 上拼；新文档无此参数）。
  (function _unpackMedia() {
    try {
      var _m = String(window.location.search).match(/[?&]src=([^&]+)/);
      if (!_m || window.__lsoUnpacked) { return; }
      var _name = decodeURIComponent(_m[1]);
      // 只处理 zip 容器（OOXML）；其余格式的媒体供给由各自链路负责
      if (!/\.(xlsx|docx|pptx|xlsm|docm|pptm)$/i.test(_name)) { return; }
      window.__lsoUnpacked = true;
      var _log = function (s) { try { console.error('LSO_UNPACK ' + s); } catch (e) { } };

      function _findMedia(u8) {
        var n = u8.length;
        var dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
        // EOCD（中央目录结束记录）：从尾部回扫，最大注释 64KB
        var eocd = -1;
        for (var i = n - 22; i >= 0 && i >= n - 66000; i--) {
          if (u8[i] === 0x50 && u8[i + 1] === 0x4b && u8[i + 2] === 0x05 && u8[i + 3] === 0x06) {
            eocd = i;
            break;
          }
        }
        if (eocd < 0) { _log('no eocd'); return []; }
        var count = dv.getUint16(eocd + 10, true);
        var p = dv.getUint32(eocd + 16, true);
        var out = [];
        for (var k = 0; k < count && p + 46 <= n; k++) {
          if (dv.getUint32(p, true) !== 0x02014b50) { break; }
          var method = dv.getUint16(p + 10, true);
          var csize = dv.getUint32(p + 20, true);
          var nameLen = dv.getUint16(p + 28, true);
          var extraLen = dv.getUint16(p + 30, true);
          var cmtLen = dv.getUint16(p + 32, true);
          var lho = dv.getUint32(p + 42, true);
          var nm = '';
          for (var j = 0; j < nameLen; j++) { nm += String.fromCharCode(u8[p + 46 + j]); }
          // 媒体条目：<根>/media/<文件>（word/ ppt/ xl/）；只取单一文件名，防目录穿越
          var mm = nm.match(/(?:^|\/)(?:media)\/([^/]+)$/);
          if (mm) {
            var lnameLen = dv.getUint16(lho + 26, true);
            var lextraLen = dv.getUint16(lho + 28, true);
            out.push({
              name: mm[1], method: method, csize: csize,
              off: lho + 30 + lnameLen + lextraLen
            });
          }
          p += 46 + nameLen + extraLen + cmtLen;
        }
        return out;
      }

      function _inflate(u8, e) {
        var raw = u8.subarray(e.off, e.off + e.csize);
        if (e.method === 0) { return Promise.resolve(raw); }   // store
        if (e.method !== 8 || typeof DecompressionStream === 'undefined') {
          return Promise.resolve(null);
        }
        try {
          var st = new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
          return new Response(st).arrayBuffer().then(function (b) { return new Uint8Array(b); });
        } catch (x) { return Promise.resolve(null); }
      }

      var _x = new XMLHttpRequest();
      _x.open('GET', 'http://localhost/userfile/' + encodeURIComponent(_name) + '?v=' + Date.now(), true);
      _x.responseType = 'arraybuffer';
      _x.onload = function () {
        try {
          var ab = _x.response;
          if (!ab || !ab.byteLength) { _log('src empty st=' + _x.status); return; }
          var u8 = new Uint8Array(ab);
          var items = _findMedia(u8);
          if (!items.length) { _log('no media in ' + _name); return; }
          _log('found ' + items.length + ' media, src=' + ab.byteLength);
          var _seq = Promise.resolve();
          items.forEach(function (e) {
            _seq = _seq.then(function () {
              return _inflate(u8, e).then(function (data) {
                if (!data || !data.byteLength) { _log('inflate fail ' + e.name); return; }
                var b64 = window.__lsoB64 ? window.__lsoB64(data) : '';
                if (!b64) { _log('b64 fail ' + e.name); return; }
                var r = (window.AscNative && window.AscNative._call)
                  ? String(window.AscNative._call('execCommand', ['media:unpack', e.name + '|' + b64]) || '')
                  : '';
                _log('unpack ' + e.name + ' bytes=' + data.byteLength + ' ret=' + r);
              });
            });
          });
        } catch (x) { _log('err ' + String(x)); }
      };
      _x.onerror = function () { _log('xhr err st=' + _x.status); };
      _x.send(null);
    } catch (e) {
      try { console.error('LSO_UNPACK_HOOK_ERR ' + String(e)); } catch (e2) { }
    }
  })();
