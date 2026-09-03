// POC-2: OHOS musl libc 缺少非标准 glibc 扩展 gcvt —— 本地兼容实现。
// 链接进 kernel 静态库（底层基座，任意上层链接均可得此符号）。
#include <stdio.h>

extern "C" char* local_gcvt(double value, int ndigit, char* buf)
{
    snprintf(buf, 128, "%.*g", ndigit, value);
    return buf;
}
