#!/usr/bin/env python3
# ONLYOFFICE core 第三方源码官方补丁（等价 apple/html/md 的 fetch.py 中 replaceInFile）
# 每项：文件、查找串、替换串（官方字符串精确一致）
import os

CORE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'third_party', 'core'))

PATCHES = [
    # ---- html/gumbo-parser：gumbo tag.c 的 isspace 未转型（负数 UB，官方修复）----
    ("Common/3dParty/html/gumbo-parser/src/tag.c",
     "isspace(*c)", "isspace((unsigned char)*c)"),

    # ---- apple/glm：`vec<...> v;` 未初始化列表（gcc init 窄化警告/错误）----
    ("Common/3dParty/apple/glm/glm/detail/func_common.inl",
     "vec<L, T, Q> v;", "vec<L, T, Q> v{};"),

    # ---- apple/mdds：std::bool_constant/void_t 的 c++17 兼容垫片 ----
    ("Common/3dParty/apple/mdds/include/mdds/global.hpp",
     "namespace mdds {",
     "#if __cplusplus < 201703L\n"
     "#ifndef _MSC_VER\n"
     "namespace std {\n"
     "  template<bool __v>\n"
     "  using bool_constant = integral_constant<bool, __v>;\n\n"
     "  template <class... _Types>\n"
     "  using void_t = void;\n"
     "}\n"
     "#endif\n"
     "#endif\n\n"
     "namespace mdds {"),

    # ---- apple/librevenge：S_ISREG/S_ISDIR 垫片（windows 条件块，官方照抄）----
    ("Common/3dParty/apple/librevenge/src/lib/RVNGDirectoryStream.cpp",
     "#include <librevenge-stream/librevenge-stream.h>",
     "#include <librevenge-stream/librevenge-stream.h>\n\n"
     "#if !defined(S_ISREG) && defined(S_IFMT) && defined(S_IFREG)\n"
     "#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)\n"
     "#endif\n"
     "#if !defined(S_ISDIR) && defined(S_IFMT) && defined(S_IFDIR)\n"
     "#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)\n"
     "#endif\n"),

    # ---- apple/librevenge：RVNGFileStream wchar_t 构造声明（windows 分支）----
    ("Common/3dParty/apple/librevenge/inc/librevenge-stream/RVNGStreamImplementation.h",
     "explicit RVNGFileStream(const char *filename);",
     "explicit RVNGFileStream(const char *filename);\n"
     "\t#if defined(_WIN32) || defined(_WIN64)\n"
     "\texplicit RVNGFileStream(const wchar_t *filename);\n"
     "\t#endif\n"),

    # ---- apple/librevenge：.cpp 版式（wstat 垫片 + namespace 守卫，官方照抄）----
    ("Common/3dParty/apple/librevenge/src/lib/RVNGStreamImplementation.cpp",
     "namespace librevenge",
     "#if defined(_WIN32) || defined(_WIN64)\n"
     "#include <sys/stat.h>\n\n"
     "static __inline int wstat(wchar_t const* const _FileName, struct stat* const _Stat)\n"
     "{\n"
     "\t_STATIC_ASSERT(sizeof(struct stat) == sizeof(struct _stat64i32));\n"
     "\treturn _wstat64i32(_FileName, (struct _stat64i32*)_Stat);\n"
     "}\n"
     "#endif\n\n"
     "namespace librevenge"),

    # ---- apple/librevenge：.cpp 版式（wchar 构造实现，windows 分支包住）----
    ("Common/3dParty/apple/librevenge/src/lib/RVNGStreamImplementation.cpp",
     "RVNGFileStream::~RVNGFileStream()",
     "#if defined(_WIN32) || defined(_WIN64)\n"
     "RVNGFileStream::RVNGFileStream(const wchar_t *filename) :\n"
     "\tRVNGInputStream(),\n"
     "\td(new RVNGFileStreamPrivate())\n"
     "{\n"
     "\td->file = _wfopen(filename, L\"rb\");\n"
     "\tif (!d->file || ferror(d->file))\n"
     "\t{\n"
     "\t\tdelete d;\n"
     "\t\td = 0;\n"
     "\t\treturn;\n"
     "\t}\n\n"
     "\tstruct stat status;\n"
     "\tconst int retval = wstat(filename, &status);\n"
     "\tif ((0 != retval) || !S_ISREG(status.st_mode))\n"
     "\t{\n"
     "\t\tdelete d;\n"
     "\t\td = 0;\n"
     "\t\treturn;\n"
     "\t}\n\n"
     "\tfseek(d->file, 0, SEEK_END);\n\n"
     "\td->streamSize = (unsigned long) ftell(d->file);\n"
     "\tif (d->streamSize == (unsigned long)-1)\n"
     "\t\td->streamSize = 0;\n"
     "\tif (d->streamSize > (std::numeric_limits<unsigned long>::max)() / 2)\n"
     "\t\td->streamSize = (std::numeric_limits<unsigned long>::max)() / 2;\n"
     "\tfseek(d->file, 0, SEEK_SET);\n"
     "}\n"
     "#endif\n\n"
     "RVNGFileStream::~RVNGFileStream()"),

    # ---- apple/libetonyek：IWORKTable.cpp is_tree_valid 笔误修复 ----
    ("Common/3dParty/apple/libetonyek/src/lib/IWORKTable.cpp",
     "is_tree_valid", "valid_tree"),
]


def patch_once(path, find, repl):
    fp = os.path.join(CORE, path)
    if not os.path.isfile(fp):
        print("SKIP(no file):", path)
        return
    src = open(fp, encoding="utf-8", errors="replace").read()
    if find not in src:
        print("SKIP(no match):", path)
        return
    # 官方 base.replaceInFile 语义：全文替换全部匹配
    open(fp, "w", encoding="utf-8").write(src.replace(find, repl))
    print("PATCHED:", path)


for p in PATCHES:
    patch_once(*p)

# mdds 的 global.hpp 若在全替换后出现重复注入（首行 namespace mdds { 被命中两次注入），
# 属上游语义（官方 CI 同源构建），不处理
print("PATCH_DONE")
