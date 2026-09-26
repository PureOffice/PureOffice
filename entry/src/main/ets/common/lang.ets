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
 * 保留 ['pt-pt','zh-tw','sr-cyrl'] 三个四字母码，其余一律取语言首段——于是
 * 'zh-Hant-TW' → 'zh-hant' → 不在表内 → 'zh'，**繁体被静默降级成简体**。繁体必须
 * 在宿主侧先纠正为 'zh-tw'；判据取 script 与地区码双份（系统 locale 可能写
 * 'zh-Hant-TW'，也可能只写 'zh-TW' 不带 script）。
 *
 * 回退：不在随包 46 种内时按原值传给页面，页面 fetch locale/<lang>.json 失败后回退
 * defLang —— 构建期占位符 {{DEFAULT_LANG}} 未被替换，运行时等于 'en'（英文）。
 */
import i18n from '@ohos.i18n';

/** 页面 _requireLang 保留的四字母语言码（与其 _4letterLangs 同内容同序） */
const FOUR_LETTER: string[] = ['pt-pt', 'zh-tw', 'sr-cyrl'];

/** 繁体地区码：仅在 locale 无 script 标记时作惯例推断（有 script 以 script 为准） */
const TRAD_REGIONS: string[] = ['TW', 'HK', 'MO'];

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
    // script 是书字变体的最强信号：Hant→繁、Hans→简，唯 script 独尊——地区判据
    // 只在无 script 时作惯例兜底（'zh-TW' 不带 script，只能按地区推断繁体）。
    // 若地区无视 script（曾写 `script==='Hant' || region∈…`），zh-Hans-HK
    //（简体中文+香港地区）会被误判成繁体——BCP-47 语义 script 优先于 region，
    // 港澳有大量简体用户。
    if (script === 'Hant' || (script.length === 0 && TRAD_REGIONS.indexOf(region) >= 0)) {
      cached = 'zh-tw';
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
