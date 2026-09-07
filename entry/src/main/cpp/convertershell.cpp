/*
 * ONLYOFFICE x2t 转换内核 —— OHOS/arm64 NAPI 桥（B 架构: ArkWeb 侧 JS 调用）
 *
 * 导出接口:
 *   convert(xml: string): Promise<number>  异步后台线程执行转换（正式接口）
 *   convertSync(xml: string): number       同步转换（调试/诊断用）
 *   version(): string                     内核版本串
 *
 * xml 为 x2t 命令行同款参数 XML（UTF-16 字符串来自 napi），示例:
 *   <Convert><m_sFileFrom>/data/xxx/in.docx</m_sFileFrom><m_sFileTo>/data/xxx/out.pdf</m_sFileTo></Convert>
 * 返回值为 x2t 原始错误码: 0 = 成功（SUCCEEDED_X2T），非 0 为失败；
 * 0x8004350=AVS_FILEUTILS_ERROR_CONVERT 是「转换出错」失败码（正式错误码见
 * Common/OfficeFileErrorDescription.h；ROW/CELLLIMITS 按部分成功处理）。
 * 注意: m_sFileName 缺省时按 from/to 扩展名自动探测格式，txt/csv 等需显式 m_nFormatFrom。
 */
#include "napi/native_api.h"
#include "hilog/log.h"

#include <string>
#include <fstream>
#include <cstring>
#include <wchar.h>
#include <sys/stat.h>
#include <unistd.h>

// 与 libx2t.a 中符号一致（见 X2tConverter/src/ASCConverters.h:337）
namespace NExtractTools
{
    typedef unsigned int _UINT32;
    _UINT32 FromXml(const std::wstring& xml);
}

static const char* const CS_LOG_TAG = "convertershell";

// napi 字符串为 UTF-16；Asc 内核（OHOS/libc++ wchar_t=32bit）的 wstring 语义是 UTF-32 码点
// （见 CXmlNode::FromXmlString: GetUtf8StringFromUnicode2 按码点解释）
static std::wstring Utf16ToWString(const char16_t* u16, size_t nLen)
{
    std::wstring out;
    out.reserve(nLen);
    for (size_t i = 0; i < nLen; ++i)
    {
        const char16_t c = u16[i];
        if (c >= 0xD800 && c <= 0xDBFF && (i + 1) < nLen &&
            u16[i + 1] >= 0xDC00 && u16[i + 1] <= 0xDFFF)
        {
            // 代理对 -> 码点
            out.push_back(static_cast<wchar_t>(0x10000 + ((c - 0xD800) << 10) + (u16[i + 1] - 0xDC00)));
            ++i;
        }
        else if (c >= 0xD800 && c <= 0xDFFF)
        {
            // 孤立代理 -> 替换符
            out.push_back(static_cast<wchar_t>(0xFFFD));
        }
        else
        {
            out.push_back(static_cast<wchar_t>(c));
        }
    }
    return out;
}

static bool GetStringArg(napi_env env, napi_value value, std::wstring& out)
{
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type != napi_string)
        return false;

    size_t nLen = 0;
    napi_get_value_string_utf16(env, value, nullptr, 0, &nLen);
    out.resize(0);
    if (nLen > 0)
    {
        std::u16string buf;
        buf.resize(nLen);
        size_t nCopied = 0;
        napi_get_value_string_utf16(env, value, buf.data(), nLen + 1, &nCopied);
        buf.resize(nCopied);
        out = Utf16ToWString(buf.data(), buf.size());
    }
    return true;
}

// 线程池 worker 共享数据：转换在 napi 线程池执行（x2t 往往秒级~分钟级，不能阻塞 UI 线程）
struct ConvertWork
{
    napi_env env;
    napi_async_work work;
    napi_deferred deferred;
    std::wstring xml;
    unsigned int result;
};

static void ConvertExecute(napi_env env, void* data)
{
    ConvertWork* cw = static_cast<ConvertWork*>(data);
    cw->result = NExtractTools::FromXml(cw->xml);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, CS_LOG_TAG,
                 "x2t convert done, result=0x%{public}x", cw->result);
}

static void ConvertComplete(napi_env env, napi_status status, void* data)
{
    ConvertWork* cw = static_cast<ConvertWork*>(data);
    napi_value res;
    napi_create_uint32(env, cw->result, &res);
    napi_resolve_deferred(env, cw->deferred, res);
    napi_delete_async_work(env, cw->work);
    delete cw;
}

static napi_value ConvertSyncJn(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::wstring xml;
    if (argc < 1 || !GetStringArg(env, args[0], xml))
    {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    const unsigned int result = NExtractTools::FromXml(xml);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, CS_LOG_TAG,
                 "x2t convertSync done, result=0x%{public}x", result);

    napi_value res;
    napi_create_uint32(env, result, &res);
    return res;
}

static napi_value ConvertAsyncJn(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::wstring xml;
    if (argc < 1 || !GetStringArg(env, args[0], xml))
    {
        napi_value res;
        napi_create_uint32(env, 0xFFFFFFFF, &res);
        return res; // 参数错误: 返回失败码（0xFFFFFFFF 非内核错误码）
    }

    ConvertWork* cw = new ConvertWork();
    cw->env = env;
    cw->work = nullptr;
    cw->deferred = nullptr;
    cw->xml = xml;
    cw->result = 0;

    napi_value promise;
    napi_create_promise(env, &cw->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "x2t convert", NAPI_AUTO_LENGTH, &resourceName);

    napi_create_async_work(env, nullptr, resourceName, ConvertExecute, ConvertComplete,
                           cw, &cw->work);
    napi_queue_async_work(env, cw->work);

    return promise;
}

static napi_value VersionJn(napi_env env, napi_callback_info info)
{
    // 内核版本串（与 DesktopEditors 发行版对齐）
    napi_value res;
    napi_create_string_utf8(env, "7.5 (x2t arm64-ohos 6.1.0.23)", NAPI_AUTO_LENGTH, &res);
    return res;
}

// —— 系统字体读取（2026-09-07 系统字体桥 v2）——
// ArkTS fileIo 对 /system/fonts 只报 ENOENT（API 域白名单，非真实不存在）；
// wine（wineohos dlls/win32u/freetype.c ReadFontDir）native 层读同路径成功
// —— 故读数落 native（本 NAPI 与 wine 同属 app 进程 native 层）。
// 返回：ArrayBuffer（字体字节流）| undefined（打开失败，OH_LOG 留痕）。
// 文件名仅允许纯名（禁 / 与 ..）。
static napi_value ReadSystemFontJn(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    if (argc < 1)
        return undefined;

    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_string)
        return undefined;

    size_t nLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &nLen);
    std::string name(nLen + 1, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, args[0], name.data(), nLen + 1, &copied);
    name.resize(copied);
    if (name.empty() || name.find('/') != std::string::npos ||
        name.find("..") != std::string::npos)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, CS_LOG_TAG, "readSystemFont bad name: %{public}s",
                     name.c_str());
        return undefined;
    }

    std::string path = "/system/fonts/" + name;
    // wine（同设备普通应用进程）opendir("/system/fonts") 成功 = 沙箱并未禁
    // 系统目录；本次取 errno 精确定性（ENOENT=不存在/域屏蔽；EACCES=权限）。
    struct stat st0;
    if (::stat("/system/fonts", &st0) != 0)
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, CS_LOG_TAG,
                     "readSystemFont stat /system/fonts fail errno=%{public}d %{public}s",
                     errno, strerror(errno));
    else
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, CS_LOG_TAG,
                     "readSystemFont /system/fonts stat ok mode=0%{public}o",
                     static_cast<unsigned>(st0.st_mode));
    struct stat st;
    if (::stat(path.c_str(), &st) != 0)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, CS_LOG_TAG,
                     "readSystemFont stat %{public}s fail errno=%{public}d %{public}s",
                     path.c_str(), errno, strerror(errno));
        return undefined;
    }
    if (::access(path.c_str(), R_OK) != 0)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, CS_LOG_TAG,
                     "readSystemFont access %{public}s fail errno=%{public}d %{public}s",
                     path.c_str(), errno, strerror(errno));
        return undefined;
    }
    std::ifstream f(path, std::ios::binary);
    if (!f)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, CS_LOG_TAG,
                     "readSystemFont open fail: %{public}s", path.c_str());
        return undefined;
    }
    std::string data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, CS_LOG_TAG,
                 "readSystemFont ok: %{public}s (%{public}u bytes)", path.c_str(),
                 static_cast<unsigned int>(data.size()));

    void* buf = nullptr;
    napi_value ab = nullptr;
    napi_create_arraybuffer(env, data.size(), &buf, &ab);
    std::memcpy(buf, data.data(), data.size());
    return ab;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"convert", nullptr, ConvertAsyncJn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"convertSync", nullptr, ConvertSyncJn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, VersionJn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readSystemFontSync", nullptr, ReadSystemFontJn, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    // OHOS NAPI 加载按 so 文件名（含 lib 前缀/扩展名）匹配模块注册表，
    // 与 import specifier 'libconvertershell.so' 保持一致
    .nm_modname = "libconvertershell.so",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterConvertershellModule(void)
{
    napi_module_register(&g_module);
}
