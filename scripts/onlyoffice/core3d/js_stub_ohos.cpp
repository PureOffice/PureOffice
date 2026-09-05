// js_stub_ohos.cpp — doctrenderer JS 引擎接入层的 OHOS 无引擎桩
//
// 背景：doctrenderer 编译面含 CJSContext/CJSObject/CJSValue 等 JS 引擎接入类，
// 其实现由后端引擎（v8/jsc）提供；OHOS 转换链（x2t → libx2t.a）不触 JS 运行时
//（POC-2 结论：宏重算在编辑器/DocBuilder 运行期，x2t 剥除 V8/JSC 触面）。
// 本桩提供被 doctrenderer 编译单元实际引用的调用面（静态库懒链接，只实现被引
// 用的符号），全部为空实现/空值返回。接口签名以 js_base.h 为准（release/v9.4.0）。
//
// 来源：gen_cmake.py 引用（CORE_ROOT/DesktopEditor/doctrenderer/js_internal/
// js_stub_ohos.cpp 语义，2026-09-05 重建时发现文件缺失，重制于此并随仓库入库）。

#include <string>
#include "js_base.h"

using namespace NSJSBase;

// ---- CJSContext（主要调用面，空实现/空返回值）----

CJSContext::CJSContext(const bool& bIsInitialize)
{
}

CJSContext::~CJSContext()
{
}

void CJSContext::Initialize(const std::wstring& snapshotPath)
{
}

void CJSContext::Dispose()
{
}

bool CJSContext::isSnapshotUsed()
{
	return false;
}

JSSmart<CJSTryCatch> CJSContext::GetExceptions()
{
	return NULL;
}

JSSmart<CJSObject> CJSContext::GetGlobal()
{
	return NULL;
}

void CJSContext::Enter()
{
}

void CJSContext::Exit()
{
}

bool CJSContext::IsEntered()
{
	return false;
}

bool CJSContext::generateSnapshot(const std::string& script, const std::wstring& snapshotPath)
{
	return false;
}

JSSmart<CJSValue> CJSContext::runScript(const std::string& script, JSSmart<CJSTryCatch> exception, const std::wstring& scriptPath)
{
	return NULL;
}

JSSmart<CJSValue> CJSContext::JSON_Parse(const char* jsonContent)
{
	return NULL;
}

std::string CJSContext::JSON_Stringify(JSSmart<CJSValue> value)
{
	return "";
}

void CJSContext::MoveToThread(ASC_THREAD_ID* id)
{
}

void CJSContext::AddEmbedCreator(const std::string& name, EmbedObjectCreator creator, const bool& isAllowedInJS)
{
}

CJSValue* CJSContext::createUndefined()
{
	return NULL;
}

CJSValue* CJSContext::createNull()
{
	return NULL;
}

CJSValue* CJSContext::createBool(const bool& value)
{
	return NULL;
}

CJSValue* CJSContext::createInt(const int& value)
{
	return NULL;
}

CJSValue* CJSContext::createUInt(const unsigned int& value)
{
	return NULL;
}

CJSValue* CJSContext::createDouble(const double& value)
{
	return NULL;
}

CJSValue* CJSContext::createString(const char* value, const int& length)
{
	return NULL;
}

CJSValue* CJSContext::createString(const wchar_t* value, const int& length)
{
	return NULL;
}

CJSValue* CJSContext::createString(const std::string& value)
{
	return NULL;
}

CJSValue* CJSContext::createString(const std::wstring& value)
{
	return NULL;
}

CJSObject* CJSContext::createObject()
{
	return NULL;
}

CJSArray* CJSContext::createArray(const int& count)
{
	return NULL;
}

CJSTypedArray* CJSContext::createUint8Array(BYTE* data, int count, const bool& isExternalize)
{
	return NULL;
}

JSSmart<CJSObject> CJSContext::createEmbedObject(const std::string& name)
{
	return NULL;
}

JSSmart<CJSContext> CJSContext::GetCurrent()
{
	return NULL;
}

void CJSContext::ExternalInitialize(const std::wstring& sDirectory)
{
}

void CJSContext::ExternalDispose()
{
}

bool CJSContext::IsSupportNativeTypedArrays()
{
	return false;
}

// ---- CJSContextScope / CJSLocalScope ----

CJSContextScope::CJSContextScope(JSSmart<CJSContext> context)
{
}

CJSContextScope::~CJSContextScope()
{
}

CJSLocalScope::CJSLocalScope()
{
}

CJSLocalScope::~CJSLocalScope()
{
}

// ---- CJSObject / CJSArray / CJSFunction（backend 提供的对象面，空实现）----

CJSObject::CJSObject()
{
}

CJSObject::~CJSObject()
{
}

void CJSObject::set(const char* name, JSSmart<CJSValue> value)
{
}

std::vector<std::string> CJSObject::getPropertyNames()
{
	return std::vector<std::string>();
}

CJSArray::CJSArray()
{
}

CJSArray::~CJSArray()
{
}

CJSFunction::CJSFunction()
{
}

CJSFunction::~CJSFunction()
{
}

CJSTryCatch::CJSTryCatch()
{
}

CJSTryCatch::~CJSTryCatch()
{
}

// ---- CJSEmbedObject 面（docbuilder/embed 引用）----

CJSEmbedObject::CJSEmbedObject()
{
}

CJSEmbedObject::~CJSEmbedObject()
{
}

bool CJSEmbedObject::GetExternalize()
{
	return false;
}

void CJSEmbedObject::SetExternalize(const bool& isExternalize)
{
}

CJSEmbedObjectAdapterBase::CJSEmbedObjectAdapterBase()
{
}

CJSEmbedObjectAdapterBase::~CJSEmbedObjectAdapterBase()
{
}

CJSEmbedObjectAdapterBase* CJSEmbedObject::getAdapter()
{
	return NULL;
}

void* CJSEmbedObject::getObject()
{
	return NULL;
}

// CJSDataBuffer 实现已在 js_base.cpp（Copy/Free/ctor），无需重复。

// ---- embed 类元方法 + NSAllocator（V8/JSC backend 的 register 面，无引擎 stub）----
// 官方构建里 embed 类的 getName/getCreator（DECLARE_EMBED_METHODS 展开，js_base_embed.pri
// 的 ADD_FILES_FOR_EMBEDDED_CLASS_HEADER）由 embed/v8/*.cpp（V8 backend）实现；本构建
// 无 JS 引擎（静态库），不编 v8_*.cpp，但 doctrenderer.cpp/EmbedDrawingFile 等 TU 经
// CJSContext::Embed<> 模板实例化引用这些符号（HAP 链接 2026-09-05 实测 undefined）。
// 转换链不触这些入口（POC-2 无引擎既定裁剪），填空/默认实现满足链接即可。

namespace NSJSBase
{
namespace NSAllocator
{
unsigned char* Alloc(const size_t& size)
{
    return new unsigned char[size];
}

void Free(unsigned char* data, const size_t& size)
{
    delete[] data;
}
}
}

// ---- embed 类元方法（DECLARE_EMBED_METHODS：getName/getCreator，无引擎 stub 实现）----

#include "embed/GraphicsEmbed.h"
#include "embed/HashEmbed.h"
#include "embed/MemoryStreamEmbed.h"
#include "embed/NativeBuilderEmbed.h"
#include "embed/NativeBuilderDocumentEmbed.h"
#include "embed/NativeControlEmbed.h"
#include "embed/TextMeasurerEmbed.h"
#include "embed/ZipEmbed.h"
#include "embed/DrawingFileEmbed.h"

std::string CGraphicsEmbed::getName() { return "CGraphicsEmbed"; }
CJSEmbedObject* CGraphicsEmbed::getCreator() { return new CGraphicsEmbed(); }

std::string CHashEmbed::getName() { return "CHashEmbed"; }
CJSEmbedObject* CHashEmbed::getCreator() { return new CHashEmbed(); }

std::string CMemoryStreamEmbed::getName() { return "CMemoryStreamEmbed"; }
CJSEmbedObject* CMemoryStreamEmbed::getCreator() { return new CMemoryStreamEmbed(); }

std::string CBuilderEmbed::getName() { return "CBuilderEmbed"; }
CJSEmbedObject* CBuilderEmbed::getCreator() { return new CBuilderEmbed(); }

std::string CBuilderDocumentEmbed::getName() { return "CBuilderDocumentEmbed"; }
CJSEmbedObject* CBuilderDocumentEmbed::getCreator() { return new CBuilderDocumentEmbed(); }

std::string CNativeControlEmbed::getName() { return "CNativeControlEmbed"; }
CJSEmbedObject* CNativeControlEmbed::getCreator() { return new CNativeControlEmbed(); }

std::string CTextMeasurerEmbed::getName() { return "CTextMeasurerEmbed"; }
CJSEmbedObject* CTextMeasurerEmbed::getCreator() { return new CTextMeasurerEmbed(); }

std::string CZipEmbed::getName() { return "CZipEmbed"; }
CJSEmbedObject* CZipEmbed::getCreator() { return new CZipEmbed(); }

std::string CDrawingFileEmbed::getName() { return "CDrawingFileEmbed"; }
CJSEmbedObject* CDrawingFileEmbed::getCreator() { return new CDrawingFileEmbed(); }

// DECLARE_EMBED_METHODS 里 getAdapter() override 只声明无实现（官方实现在 v8_*.cpp
// backend 面）；子类经 new 实例化时 vtable 需它 → 全部 stub 定义（返回 NULL）。
CJSEmbedObjectAdapterBase* CGraphicsEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CHashEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CMemoryStreamEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CBuilderEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CBuilderDocumentEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CNativeControlEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CTextMeasurerEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CZipEmbed::getAdapter() { return NULL; }
CJSEmbedObjectAdapterBase* CDrawingFileEmbed::getAdapter() { return NULL; }

#include "embed/PointerEmbed.h"

// PointerEmbed.h:67 的 createObject 声明无实现（官方 v8 backend 宏展开提供），
// stub 空返回。
JSSmart<CJSValue> CPointerEmbedObject::createObject()
{
    return JSSmart<CJSValue>();
}
