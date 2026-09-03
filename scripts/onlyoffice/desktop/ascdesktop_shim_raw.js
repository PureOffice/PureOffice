window.AscDesktopEditor.CreateEditorApi = function(api) {
api && api.asc_registerCallback('asc_onGetEditorPermissions', function(e) { window.AscDesktopEditor.CheckCloudFeatures(e.asc_getLicenseType()); });
window.AscDesktopEditor._CreateEditorApi();
};
window.AscDesktopEditor.sendSystemMessage = function(arg) {
  window.AscDesktopEditor.isSendSystemMessage = true;
  // expand system message
  arg.url = window.AscDesktopEditor._getMainUrl();
  window.AscDesktopEditor._sendSystemMessage(JSON.stringify(arg));
};
window.AscDesktopEditor.GetHash = function(arg, callback) {
  window.AscDesktopEditor.getHashCallback = callback;
  window.AscDesktopEditor._GetHash(arg);
};
window.AscDesktopEditor.CallInAllWindows = function(arg) {
  window.AscDesktopEditor._CallInAllWindows("(" + arg.toString() + ")();");
};
window.AscDesktopEditor.OpenFileCrypt = function(name, url, callback) {
  window.AscDesktopEditor.openFileCryptCallback = callback;
  window.AscDesktopEditor._OpenFileCrypt(name, url);
};
window.AscDesktopEditor.OpenFilenameDialog = function(filter, ismulti, callback) {
  if (window.on_native_open_filename_dialog) return;
  window.on_native_open_filename_dialog = callback;
  window.AscDesktopEditor._OpenFilenameDialog(filter, ismulti);
};
window.AscDesktopEditor.SaveFilenameDialog = function(filter, callback, content) {
  window.on_native_save_filename_dialog = callback;
  window.AscDesktopEditor._SaveFilenameDialog(filter, content);
};
window.AscDesktopEditor.DownloadFiles = function(filesSrc, filesDst, callback, params) {
  if (filesSrc.length == 0) return callback({});
  window.on_native_download_files = callback;
  window.AscDesktopEditor._DownloadFiles(filesSrc, filesDst, params);
};
window.AscDesktopEditor.SetCryptoMode = function(password, mode, callback) {
  window.on_set_crypto_mode = callback;
  window.AscDesktopEditor._SetCryptoMode(password, mode, callback ? true : false);
};
window.AscDesktopEditor.GetAdvancedEncryptedData = function(password, callback) {
  window.on_get_advanced_encrypted_data = callback;
  window.AscDesktopEditor._GetAdvancedEncryptedData(password);
};
window.AscDesktopEditor.SetAdvancedEncryptedData = function(password, data, callback) {
  window.on_set_advanced_encrypted_data = callback;
  window.AscDesktopEditor._SetAdvancedEncryptedData(password, data);
};
window.AscDesktopEditor.AddVideo = function(file, callback) {
  window.on_add_multimedia_local = callback;
  window.AscDesktopEditor._AddVideo(file);
};
window.AscDesktopEditor.AddAudio = function(file, callback) {
  window.on_add_multimedia_local = callback;
  window.AscDesktopEditor._AddAudio(file);
};
window.AscDesktopEditor.ImportAdvancedEncryptedData = function(callback) {
  window.AscDesktopEditor.OpenFilenameDialog('Key File (*docx);;All files (*.*)', false, function(files) {
	var file = Array.isArray(files) ? files[0] : files;
	if (file)
	{
	  var ret = window.AscDesktopEditor._ImportAdvancedEncryptedData(file);
	  if (callback) callback(ret);
	}
  });
};
window.AscDesktopEditor.ExportAdvancedEncryptedData = function() {
  window.AscDesktopEditor.SaveFilenameDialog('privateKey.docx', function(file) {
	if (file)
	{
	  window.AscDesktopEditor._ExportAdvancedEncryptedData(file);
	}
  });
};
window.AscDesktopEditor.CloudCryptFile = function(url, callback) {
  if (window.on_cloud_crypto_upload) { console.log('CloudCryptFile: waiting...'); return; }
  window.AscDesktopEditor.DownloadFiles([url], [], function(files) {
	var _files = [];
	for (var elem in files)
	  _files.push(files[elem]);
	window.on_cloud_crypto_upload = undefined;
	if (_files && 1 == _files.length)
	{
	  window.on_cloud_crypto_upload = callback;
	  window.AscDesktopEditor._CloudCryptoUpload([_files[0]], true);
	}
  }, 1);
};
window.AscDesktopEditor.CloudCryptUpload = function(filter, callback) {
  if (window.on_cloud_crypto_upload) { console.log('CloudCryptUpload: waiting...'); return; }
  var filterOut = filter || ""; if (filterOut == "") filterOut = "any";
  window.AscDesktopEditor.OpenFilenameDialog(filterOut, true, function(files) {
	window.on_cloud_crypto_upload = undefined;
	if (files && 0 < files.length)
	{
	  window.on_cloud_crypto_upload = callback;
	  window.AscDesktopEditor._CloudCryptoUpload(files);
	}
  });
};
window.AscDesktopEditor.loadLocalFile = function(url, callback, start, len) {
  var xhr = new XMLHttpRequest();
  var loadUrl = url;
  if (start !== undefined) loadUrl += ("__ascdesktopeditor__param__" + start);
  if (len !== undefined)
  {
	if (undefined === start) loadUrl += "__ascdesktopeditor__param__0";
	loadUrl += ("__ascdesktopeditor__param__" + len);
  }
  xhr.open("GET", "ascdesktop://fonts/" + loadUrl, true);
  xhr.responseType = "arraybuffer";
  if (xhr.overrideMimeType)
	xhr.overrideMimeType('text/plain; charset=x-user-defined');
  else
	xhr.setRequestHeader('Accept-Charset', 'x-user-defined');
  xhr.onload = function() {
	callback(new Uint8Array(xhr.response));
  };
  xhr.onerror = function() {
	callback(null);
  };
  xhr.send(null);
};
window.AscDesktopEditor.openExternalReference = function(link, callbackError) {
window.AscDesktopEditor._openExternalReferenceCallback = callbackError;
return window.AscDesktopEditor._openExternalReference(link);
};
window.AscDesktopEditor.saveAndOpen = function(content, formatSrc, pathDst, formatDst, callback) {
window.AscDesktopEditor._saveAndOpenCallback = callback;
return window.AscDesktopEditor._saveAndOpen(content, formatSrc, pathDst, formatDst);
};
Object.defineProperty(window.AscDesktopEditor, 'CryptoMode', {
get: function() { return window.AscDesktopEditor.Property_GetCryptoMode(); },
set: function(value) { window.AscDesktopEditor.Property_SetCryptoMode(value); }
});
window.AscDesktopEditor.isSupportBinaryFontsSprite = true;
window.AscDesktopEditor.cloudCryptoCommandMainFrame=function(a,b){window.cloudCryptoCommandMainFrame_callback=b,window.AscDesktopEditor._cloudCryptoCommandMainFrame(window.AscDesktopEditor.GetFrameId(),JSON.stringify(a))},window.AscDesktopEditor.cloudCryptoCommand=function(a,b,c){switch(window.AscDesktopEditor.initCryptoWorker(b.cryptoEngineId),window.cloudCryptoCommandCounter=0,window.cloudCryptoCommandCount=0,window.cloudCryptoCommandParam=b,window.cloudCryptoCommandCallback=c,a){case"share":{var d=Array.isArray(b.file)?b.file:[b.file];window.cloudCryptoCommandCount=d.length,window.AscDesktopEditor.DownloadFiles(d,[],function(a){for(var b in a){let c=a[b],d=window.AscDesktopEditor.isFileSupportCloudCrypt(c,true),e=!1;if(d){let a=window.AscDesktopEditor.getDocumentInfo(c),b=window.cloudCryptoCommandParam;if(""==a){let d=window.AscCrypto.CryptoWorker.createPassword();a=window.AscCrypto.CryptoWorker.generateDocInfo(b.keys,d),e=window.AscDesktopEditor.setDocumentInfo(c,d,a)}else{let d=window.AscCrypto.CryptoWorker.readPassword(a);a=window.AscCrypto.CryptoWorker.generateDocInfo(b.keys,d),e=window.AscDesktopEditor.setDocumentInfo(c,d,a)}}window.AscDesktopEditor.loadLocalFile(c,function(a){window.cloudCryptoCommandCallback({bytes:a,isCrypto:e,url:b}),window.AscDesktopEditor.RemoveFile(c),window.cloudCryptoCommandCounter++,window.cloudCryptoCommandCounter==window.cloudCryptoCommandCount&&(window.cloudCryptoCommandCount=0,delete window.cloudCryptoCommandParam,delete window.cloudCryptoCommandCallback)})}},1);break}case"upload":{var e=b.filter||"any",f=b.keys||[],g=window.AscCrypto.CryptoWorker.User;f.push({userId:g[2],publicKey:g[1]}),window.AscDesktopEditor.OpenFilenameDialog(e,!0,function(a){Array.isArray(a)||(a=[a]),window.cloudCryptoCommandCount=a.length;for(var b=0;b<a.length;b++){let c=a[b],d=window.AscDesktopEditor.isFileSupportCloudCrypt(c),e=window.AscDesktopEditor.isFileCrypt(c),g="";if(d&&!e){let a=window.AscCrypto.CryptoWorker.createPassword();docinfo=window.AscCrypto.CryptoWorker.generateDocInfo(f,a),g=window.AscDesktopEditor.setDocumentInfo(c,a,docinfo,!0)}let h=""!=g,i=b;window.AscDesktopEditor.loadLocalFile(h?g:c,function(a){var b=c,d=b.lastIndexOf("/");-1!=d&&(b=b.substring(d+1)),d=b.lastIndexOf("\\"),-1!=d&&(b=b.substring(d+1)),window.cloudCryptoCommandCallback({bytes:a,isCrypto:h,name:b,index:i,count:window.cloudCryptoCommandCount}),h&&window.AscDesktopEditor.RemoveFile(g),window.cloudCryptoCommandCounter++,window.cloudCryptoCommandCounter==window.cloudCryptoCommandCount&&(window.cloudCryptoCommandCount=0,delete window.cloudCryptoCommandParam,delete window.cloudCryptoCommandCallback)})}});break}default:{c(null),delete window.cloudCryptoCommandParam,delete window.cloudCryptoCommandCallback;break}}};
window.AscDesktopEditor.convertFile = function(path, format, callback) {
window.on_convert_file_callback = function(folder) { callback(window.AscDesktopEditor._onConvertFile(folder)); };
if (path && path.indexOf && (0 === path.indexOf('https://') || 0 === path.indexOf('http://') || 0 === path.indexOf('www.'))) {
window.AscDesktopEditor.DownloadFiles([path], [], function(_files) {
var files = []; for (var _elem in _files) { files.push(_files[_elem]); }
window.AscDesktopEditor._convertFile((files && files[0]) ? files[0] : '', format);
});
} else {
window.AscDesktopEditor._convertFile(path, format);
}
};
window.AscDesktopEditor.convertFileExternal = function(path, format, callback) {
if (!window._external_converter_counter) window._external_converter_counter = 0;
window._external_converter_counter++;
window._external_converters = window._external_converters || {};
window._external_converters[window._external_converter_counter] = function(path, code) { callback(window.AscDesktopEditor._onConvertFileExternal(path, code)); };
if (path && path.indexOf && (0 === path.indexOf('https://') || 0 === path.indexOf('http://') || 0 === path.indexOf('www.'))) {
window.AscDesktopEditor.DownloadFiles([path], [], function(_files) {
var files = []; for (var _elem in _files) { files.push(_files[_elem]); }
window.AscDesktopEditor._convertFileExternal((files && files[0]) ? files[0] : '', format, window._external_converter_counter);
});
} else {
window.AscDesktopEditor._convertFileExternal(path, format, window._external_converter_counter);
}
};
window.AscDesktopEditor.getPortalsList = function() { var ret = []; try { var portals = JSON.parse(localStorage.getItem("portals")); for (var i = 0, len = portals.length; i < len; i++) { ret.push(portals[i].portal); ret.push(portals[i].provider); } } catch(err) { ret = []; } console.log(ret);window.AscDesktopEditor.setPortalsList(ret); };
!function(){window.AscSimpleRequest=window.AscSimpleRequest||{};var r=0,o={};window.AscSimpleRequest.createRequest=function(e){var t;o[++r]={id:r,complete:e.complete,error:e.error,progress:e.progress},e.timeout&&(o[t=r].timer=setTimeout(function(){o[t]&&(o[t].error&&o[t].error({status:"error",statusCode:404},"error"),delete o[t])},e.timeout)),window.AscDesktopEditor.sendSimpleRequest(r,e)},window.AscSimpleRequest._onSuccess=function(e,t){let r=o[e];r&&(r.timer&&clearTimeout(r.timer),r.complete&&r.complete(t,t.status),delete o[e])},window.AscSimpleRequest._onError=function(e,t){let r=o[e];r&&(r.timer&&clearTimeout(r.timer),r.error&&r.error(t,t.status),delete o[e])},window.AscSimpleRequest._onProgress=function(e,t){let r=o[e];r&&(r.timer&&clearTimeout(r.timer),r.progress&&r.progress(t,t.status))}}();window.AscDesktopEditor.getViewportSettings=function(){return JSON.parse(window.AscDesktopEditor._getViewportSettings());};window.AscDesktopEditor._events={};window.AscDesktopEditor.attachEvent=function(name,callback){if(undefined===window.AscDesktopEditor._events[name]){window.AscDesktopEditor._events[name]=[];}window.AscDesktopEditor._events[name].push(callback);};window.AscDesktopEditor.LocalFileTemplates=function(e){window.__lang_checker_templates__=e||"",window.__resize_checker_templates__||(window.__resize_checker_templates__=!0,window.addEventListener("resize",function(){window.AscDesktopEditor._LocalFileTemplates(window.__lang_checker_templates__,(100*window.devicePixelRatio)>>0)})),window.AscDesktopEditor._LocalFileTemplates(window.__lang_checker_templates__,(100*window.devicePixelRatio)>>0)};