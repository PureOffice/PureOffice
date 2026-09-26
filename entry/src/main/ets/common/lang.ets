/**
 * lang.ets —— 界面语言跟随系统（设计 docs/superpowers/specs/2026-09-25-
 * app-language-follow-system-design.md）。
 *
 * 语言只在宿主解析这一处，产出「ONLYOFFICE 语言短码」喂三个消费方：欢迎页 URL、
 * 编辑器页 URL、宿主读官方语言包（新建文档默认名）。短码对页面侧归一化（webapps/
 * apps/common/locale.js 的 _requireLang）幂等，故两边天然一致——这是「界面英文但
 * 新建文档名中文」这类不一致的根治点。
 *
 * 为什么宿主必须先归一化、不能把系统 locale 原样塞进 URL：页面 _requireLang 只
 * 保留 ['pt-pt','zh-tw','sr-cyrl'] 三个四字母码，其余一律取语言首段——不归一的话
 * 'sr-Cyrl-RS' 会丢西里尔分支。中文系（zh-Hans/Hant/TW/HK/MO）一律收敛为 'zh'
 *（简体），zh-tw 通路在官方包上不可用（见 systemLang 内注释）。
 *
 * 回退：不在随包 46 种内时按原值传给页面，页面 fetch locale/<lang>.json 失败后回退
 * defLang —— 构建期占位符 {{DEFAULT_LANG}} 未被替换，运行时等于 'en'（英文）。
 */
import i18n from '@ohos.i18n';

/** 页面 _requireLang 保留的四字母语言码（与其 _4letterLangs 同内容同序）。
 * 'zh-tw' 仅作页面行为镜像——宿主侧中文系一律归 'zh'（见 systemLang），不再产出 */
const FOUR_LETTER: string[] = ['pt-pt', 'zh-tw', 'sr-cyrl'];

let cached: string = '';

/**
 * 系统语言 → ONLYOFFICE 语言短码（如 'zh' / 'zh-tw' / 'en' / 'ja'）。
 * 进程内只算一次：系统语言在应用生命周期内不变，而 URL 构造会多次调用。
 */
export function systemLang(): string {
  if (cached.length > 0) {
    return cached;
  }
  let loc: string = '';
  try {
    // API 20 起 getSystemLocale() 废弃，用 Locale 实例（本项目 API 23）
    const l = i18n.System.getSystemLocaleInstance();
    const script: string = l.script ?? '';
    const region: string = l.region ?? '';
    // 中文系一律简体（'zh'），不分流繁体：zh-tw.json 与 zh.json 键集不等，
    // DE Statusbar 的 app:ready 链会拿到 undefined hint（Button.js 的 hint[0]
    // 无判空）抛 TypeError，加载遮罩永挂——官方语言包补齐前 zh-tw 不可用。
    if (l.language === 'zh') {
      cached = 'zh';
      return cached;
    }
    // 拼成 BCP-47 全串再取前两段（与页面 _requireLang 的 split 同形）。**必须带
    // script 段**：'sr-Cyrl-RS' 的前两段是 'sr-cyrl'（四字母码，页面保留），丢掉
    // script 只剩 'sr-rs' → 取首段 'sr'，塞尔维亚语会掉进非西里尔分支。
    loc = l.language + (script.length > 0 ? '-' + script : '')
      + (region.length > 0 ? '-' + region : '');
  } catch (e) {
    cached = 'en';   // 取不到系统语言：英文（与页面 defLang 回退一致）
    return cached;
  }
  const parts: string[] = loc.toLowerCase().split(/[-_]/);
  const two: string = parts[0] + (parts.length > 1 ? '-' + parts[1] : '');
  const i: number = FOUR_LETTER.indexOf(two);
  cached = i < 0 ? parts[0] : FOUR_LETTER[i];
  return cached;
}
