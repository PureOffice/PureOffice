import resourceManager from '@ohos.resourceManager';

/**
 * i18n.ets —— 宿主原生 UI 文案的取值入口。
 *
 * 语言**不由本模块决定**：资源目录 base/（英文兜底）与 zh_CN/ 由 ArkTS 按系统
 * locale 自动选择，故这里没有任何语言判断代码。新增语言 = 加一个
 * resources/<lang>/element/string.json 目录，代码零改动。
 *
 * 为什么用「运行时取值返回 string」而不是直接把 Resource 交给 UI 组件：
 * 有一批消费方只吃 string——picker 的 fileSuffixFilters、DocTabCtx.title 这类
 * 数据字段、userFonts 的 {ok, msg} 返回值。若 UI 组件走 Resource、这些走取值，
 * 同一份代码就有两套类型，容易漏改也容易漂移；统一成 string 后调用点形态一致。
 */

let _rm: resourceManager.ResourceManager | null = null;

/** 注入资源管理器。EntryAbility.onCreate 调用——它早于任何页面构造，
 *  且不依赖 getContext() 在模块级函数中的运行时栈语义。 */
export function bindResourceManager(rm: resourceManager.ResourceManager): void {
  _rm = rm;
}

/** 资源 → 当前系统语言下的文案；args 按顺序替换资源串里的 %s / %d。
 *  取值失败返回空串（宁可露出空白，也不要回退成另一种语言的中英混排）。 */
export function t(res: Resource, ...args: (string | number)[]): string {
  if (_rm === null) { return ''; }
  try {
    // 必须展开：getStringSync 只有 (resId, ...args) 形式的重载，
    // 传数组会落到「参数类型不匹配」（编译期报 No overload matches）
    return _rm.getStringSync(res.id, ...args);
  } catch (e) {
    return '';
  }
}
