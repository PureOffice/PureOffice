# ONLYOFFICE convertershell —— x2t 内核 NAPI 模块（arm64 OHOS）
# 由 hvigor/DevEco 以 ohos.toolchain.cmake 驱动；亦可独立构建（见 scripts/onlyoffice/build_convertershell.sh 说明）
cmake_minimum_required(VERSION 3.12)
project(convertershell LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# NAPI 模块名（MODULE_NAME 与 .so 文件名一致）
add_definitions(-DNODE_GYP_MODULE_NAME=convertershell)

# 与 core 静态库编译期一致的关键选项
add_compile_options(-fsigned-char -fPIC -Wno-unused-result)

# ---------- core 静态库（qmake->CMake 转换产物） ----------
set(CORE3D "${CMAKE_CURRENT_SOURCE_DIR}/../../../../build/core3d/build")

# ---------- 外部静态库（均在 QMAKE_CORE_3DPARTY 上交叉编译） ----------
set(ICU_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/core/Common/3dParty/icu/android/build/ohos_arm64")
set(BOOST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/core/Common/3dParty/boost/build/ohos_arm64/lib")
set(CRYPTOPP "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/core/Common/3dParty/cryptopp/libcryptopp.a")
set(OPENSSL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/core/Common/3dParty/openssl/build/ohos_arm64/lib")

add_library(convertershell SHARED convertershell.cpp ohos_compat.cpp)

# core 各静态库间存在同名等价实现（如 replace_all），取首个定义即可
target_link_options(convertershell PRIVATE -Wl,--allow-multiple-definition)

target_link_libraries(convertershell PRIVATE
    # core 全部 26 个静态库（官方 x2t 链接顺序）
    "${CORE3D}/libx2t.a"
    # Android 官方 x2t 链接集补充（iWork/HTML/MD/签名/ECMA 加密）
    "${CORE3D}/libHtmlFile2.a"
    "${CORE3D}/libIWorkFile.a"
    "${CORE3D}/libStarMathConverter.a"
    "${CORE3D}/libooxmlsignature.a"
    "${CORE3D}/libooxml_crypt.a"
    "${CORE3D}/libgraphics.a"
    "${CORE3D}/libkernel.a"
    "${CORE3D}/libkernel_network.a"
    "${CORE3D}/libUnicodeConverter.a"
    # CryptoPPLib = 3dParty/cryptopp，见下方外部库区
    "${CORE3D}/libFb2File.a"
    "${CORE3D}/libPdfFile.a"
    "${CORE3D}/libEpubFile.a"
    "${CORE3D}/libXpsFile.a"
    "${CORE3D}/libOFDFile.a"
    "${CORE3D}/libDjVuFile.a"
    "${CORE3D}/libdoctrenderer.a"
    "${CORE3D}/libDocxRenderer.a"
    "${CORE3D}/libHWPFile.a"
    "${CORE3D}/libVbaFormatLib.a"
    "${CORE3D}/libOdfFormatLib.a"
    "${CORE3D}/libDocFormatLib.a"
    "${CORE3D}/libPPTFormatLib.a"
    "${CORE3D}/libRtfFormatLib.a"
    "${CORE3D}/libTxtXmlFormatLib.a"
    "${CORE3D}/libBinDocument.a"
    "${CORE3D}/libPPTXFormatLib.a"
    "${CORE3D}/libDocxFormatLib.a"
    "${CORE3D}/libXlsbFormatLib.a"
    "${CORE3D}/libXlsFormatLib.a"
    "${CORE3D}/libCompoundFileLib.a"
    # ICU（顺序: i18n → uc → data，静态库依赖序）
    "${ICU_DIR}/lib/libicui18n.a"
    "${ICU_DIR}/lib/libicuuc.a"
    "${ICU_DIR}/lib/libicudata.a"
    # boost
    "${BOOST_DIR}/libboost_date_time.a"
    "${BOOST_DIR}/libboost_filesystem.a"
    "${BOOST_DIR}/libboost_regex.a"
    "${BOOST_DIR}/libboost_system.a"
    # crypto++（依赖 boost + 自含）
    "${CRYPTOPP}"
    # openssl: ssl 依赖 crypto
    "${OPENSSL_DIR}/libssl.a"
    "${OPENSSL_DIR}/libcrypto.a"
    # OHOS 系统库（liblog/libace_napi 为 .z.so 后缀，需全路径）
    "/apps/harmony/sdk/default/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libhilog_ndk.z.so"
    "/apps/harmony/sdk/default/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libace_napi.z.so"
    z
    dl
)
