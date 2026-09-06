/**
 * 55_lic.js —— 许可证弹层（关于面板「许可信息」链接点击用）。
 *
 * 背景：ArkWeb 无多窗口/新标签页语义——target="_blank" 的 <a> 点击会被静默丢弃
 * （2026-09-07 真机实证：About.js 模板加 `许可信息` href target=_blank 后点击无反应）。
 * 本文件在 document **捕获阶段**先于官方 UI 处理器拦截 target=_blank 且 href 为
 * 本地同源资源（http://localhost/onlyoffice/）的链接，改为全屏遮罩 + 内容弹层
 * （fetch 文本 → iframe.srcdoc 渲染，不依赖服务器 MIME、不跳转不丢编辑状态）。
 * 非本地外链（官网/mailto/公网）保持默认行为不弹层。
 */
(function () {
  'use strict';

  var mask, box, bar, iframe, title;

  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function ensure() {
    if (mask) {
      return;
    }
    mask = document.createElement('div');
    mask.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:100001;display:none;';
    box = document.createElement('div');
    box.style.cssText = 'position:absolute;width:84%;height:84%;left:8%;top:8%;' +
      'background:#fff;border-radius:8px;overflow:hidden;display:flex;flex-direction:column;' +
      'box-shadow:0 6px 30px rgba(0,0,0,.3);';
    bar = document.createElement('div');
    bar.style.cssText = 'height:44px;background:#f2f2f2;flex:none;display:flex;' +
      'align-items:center;justify-content:space-between;padding:0 14px;';
    title = document.createElement('span');
    title.textContent = '许可证文本';
    title.style.cssText = 'color:#444;font-size:14px;';
    var close = document.createElement('button');
    close.textContent = '✕ 关闭';
    close.style.cssText = 'border:none;background:transparent;color:#444;font-size:16px;' +
      'cursor:pointer;padding:4px 8px;';
    close.onclick = function () {
      mask.style.display = 'none';
    };
    bar.appendChild(title);
    bar.appendChild(close);
    iframe = document.createElement('iframe');
    iframe.style.cssText = 'flex:1;border:none;width:100%;background:#fff;';
    box.appendChild(bar);
    box.appendChild(iframe);
    mask.appendChild(box);
    // 点遮罩（框外）关闭；框内点击不关
    mask.addEventListener('click', function (e) {
      if (e.target === mask) {
        mask.style.display = 'none';
      }
    });
    document.body.appendChild(mask);
  }

  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a') : null;
    if (!a) {
      return;
    }
    var href = a.getAttribute('href') || '';
    if (a.getAttribute('target') !== '_blank') {
      return;
    }
    if (!/^http:\/\/localhost\/onlyoffice\//.test(href)) {
      return; // 仅本地同源资源弹层；其余交给浏览器默认行为
    }
    e.preventDefault();
    e.stopPropagation();
    ensure();
    // 标题固定（取链接整文会把「（点击查看全文）」等链接文案带进标题栏——2026-09-07 用户指出）
    title.textContent = '许可证文本';
    iframe.srcdoc = '<pre style="white-space:pre-wrap;padding:20px 24px;font:12px/1.6 monospace;color:#333;">加载中…</pre>';
    mask.style.display = 'block';
    fetch(href)
      .then(function (r) {
        return r.text();
      })
      .then(function (txt) {
        iframe.srcdoc = '<pre style="white-space:pre-wrap;padding:20px 24px;' +
          'font:12px/1.6 monospace;color:#333;">' + esc(txt) + '</pre>';
      })
      .catch(function () {
        iframe.srcdoc = '<pre style="padding:20px 24px;color:#c00;">加载失败：' + href + '</pre>';
      });
  }, true);
})();
