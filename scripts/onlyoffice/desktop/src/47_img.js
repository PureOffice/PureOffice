  // ==========================================================================
  // 4.7 插入图片：UploadImageFiles 宿主化（轮询等到 sdkjs 就位后覆写）
  // ==========================================================================
  // 背景：插入图片在 sdkjs 里是 **web 形态专属**链——asc_addImage → ShowImageFileDialog
  // → <input type=file>（editorscommon.js _ShowFileDialog → GetUploadInput）→
  // AscCommon.UploadImageFiles POST 到 sUploadServiceLocalUrl（'../../../../upload'：
  // DocumentServer 的上传服务），拿回服务器 URL 写进模型。官方 desktop 形态走 C++
  // 注入的 emulateUpload（原生文件框），我们在 ArkWeb 下两者皆无：没有服务器可传。
  // （刻意不定义 window.native 冒充 native 引擎：editorscommon.js:11580 等多处以
  //  "native 存在" 为条件切换整套行为，语义面过大。）
  //
  // 本段把 UploadImageFiles 换成宿主供给：FileReader 读文件 → base64 → 桥
  // （AscNative.execCommand 'media:put'）落进**本 tab** 的 media/ 目录 → 返回文件名。
  //
  // 三条链共用一个目录（关键设计，见记忆 onlyoffice-image-pipeline）：
  //   保存：文档模型里存 'media/<name>'，x2t bin→OOXML 时按此名从 <bin 同级>/media/
  //         取图打包（DocxSerializer setSrcPath(bin 目录)）——故字节必须落在
  //         tabDir/media/ 下且名与模型引用一致。
  //   渲染：addUrls({'media/<name>': '_offline_media/<name>'}) 建映射 → 引擎按
  //         documentUrl（'_offline_'）拼出的相对 URL 落拦截层（rawfileLoader
  //         OFFLINE_MEDIA_SEG 分支）→ 从同一 media/ 目录供给。
  // 选择器弹窗（<input type=file>）由宿主 onShowFileSelector 接管（DocTabHost），
  // 本段只处理"文件已选定"之后的上传汇合点。三个编辑器共用 AscCommon 上的同一个
  // 函数，故一处覆写覆盖 word/slide/cell（excel 走 asc_addImage 同源调用链）。
  //
  // 轮询而非立即执行：sdk-all.js 由官方链在引擎 init 时异步注入（20_bridge 头注），
  // 本段加载时 AscCommon 尚未定义。
  (function _hookUploadImage() {
    try {
      var _n = 0;
      function _tick() {
        _n++;
        var AC = window.AscCommon;
        if (AC && typeof AC.UploadImageFiles === 'function' && AC.g_oDocumentUrls) {
          AC.UploadImageFiles = function (files, documentId, documentUserId, jwt,
            shardKey, wopiSrc, userSessionId, callback) {
            var _eid = (typeof Asc !== 'undefined' && Asc.c_oAscError) ? Asc.c_oAscError.ID : null;
            var E_URL = _eid ? _eid.UplImageUrl : 0;
            try {
              if (!files || files.length === 0) {
                callback(_eid ? _eid.UplImageFileCount : E_URL);
                return;
              }
              var file = files[0];
              var fr = new FileReader();
              fr.onload = function () {
                try {
                  var res = String(fr.result || '');
                  var comma = res.indexOf(',');
                  var b64 = comma >= 0 ? res.substring(comma + 1) : '';
                  // 扩展名取 data URL 的 MIME（'data:image/png;base64,...'）——File.type
                  // 与真实字节同源即此；取不到再回退原文件名后缀。
                  // 先去参数段（';base64' 在逗号之前，直接切到逗号会得到 'image/png;base64'
                  // → 扩展名成了 'pngbase64'，落盘文件名与 OOXML 部件名都会带上它）
                  var mime = comma >= 0 ? res.substring(5, comma).toLowerCase() : '';
                  var semi = mime.indexOf(';');
                  if (semi >= 0) { mime = mime.substring(0, semi); }
                  var ext = mime.indexOf('/') >= 0 ? mime.substring(mime.indexOf('/') + 1) : '';
                  ext = ext.replace('+xml', '').replace(/[^a-z0-9]/g, '');
                  if (ext === 'jpeg') { ext = 'jpg'; }
                  if (!ext) {
                    var fn = String(file.name || '');
                    var d = fn.lastIndexOf('.');
                    ext = d >= 0 ? fn.substring(d + 1).toLowerCase().replace(/[^a-z0-9]/g, '') : 'png';
                  }
                  if (!b64) {
                    console.error('LSO_IMG empty ext=' + ext);
                    callback(E_URL);
                    return;
                  }
                  var name = (window.AscNative && window.AscNative._call)
                    ? String(window.AscNative._call('execCommand', ['media:put', ext + '|' + b64]) || '')
                    : '';
                  if (!name || name === '""' || name === 'false') {
                    console.error('LSO_IMG put fail r=' + name);
                    callback(E_URL);
                    return;
                  }
                  // 模型引用（media/<name>）→ 渲染 URL（_offline_media/<name>）映射
                  var map = {};
                  map['media/' + name] = '_offline_media/' + name;
                  AC.g_oDocumentUrls.addUrls(map);
                  console.error('LSO_IMG put ok ' + name + ' b64=' + b64.length);
                  callback(_eid ? _eid.No : 0, ['_offline_media/' + name]);
                } catch (e) {
                  console.error('LSO_IMG onload err ' + String(e));
                  callback(E_URL);
                }
              };
              fr.onerror = function () {
                console.error('LSO_IMG read err');
                callback(E_URL);
              };
              fr.readAsDataURL(file);
            } catch (e) {
              console.error('LSO_IMG err ' + String(e));
              callback(E_URL);
            }
          };
          console.error('LSO_IMG_HOOKED');
          return;
        }
        if (_n < 600) { setTimeout(_tick, 200); } else { console.error('LSO_IMG_GIVEUP'); }
      }
      setTimeout(_tick, 300);
    } catch (e) {
      console.error('LSO_IMG_HOOK_ERR ' + String(e));
    }
  })();
