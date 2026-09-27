/**
 * knockShare.ets —— Share Kit 碰一碰传送的注册与能力声明（设计
 * docs/superpowers/specs/2026-09-27-knock-share-design.md）。
 *
 * 职责单一：注册/解除、能力表、后缀→UTD 映射。收发业务（插入图片/打开
 * 文档/导出发送）在 EditorPage——本模块不持有页面状态。
 *
 * 生命周期纪律：onPageShow 注册、onPageHide 必须解除——后台持注册是
 * 官方样例明示的错误态。
 *
 * 接收能力（dataReceive）= MEDIA/FILE 顶层父类型（对齐官方 KnockFileShare
 * 样例——精确 UTD 声明会让 UDMF 的 BelongsTo 匹配失败，见 utdOfExt 注释）；
 * 发送侧 utd 用系统 API 按扩展名动态取。对端发来的类型与能力不匹配时系统走
 * 华为分享默认接收（落系统目录）——官方兜底语义，不是错误，本层不处理。
 */
import { harmonyShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';

/** dataReceive 能力表——**对齐官方 KnockFileShare 样例**（MEDIA/FILE 顶层父类型，
 *  手机端分享的图片/文件 utd 归一后均可命中；曾用 IMAGE 精确声明与 9 格式精确
 *  UTD 逐条声明，均出现两端 ServiceExtension 握手超时）。 */
export function recvCapabilities(): harmonyShare.RecvCapability[] {
  const caps: harmonyShare.RecvCapability[] = [
    { utd: utd.UniformDataType.MEDIA, maxSupportedCount: 5 },
    { utd: utd.UniformDataType.FILE, maxSupportedCount: 5 },
  ];
  return caps;
}

/** 设备是否具备碰一碰能力（syscap 探测；不支持时不注册——轻碰无响应
 *  即官方语义，应用侧无需替代 UI） */
export function knockSupported(): boolean {
  return canIUse('SystemCapability.Collaboration.HarmonyShare');
}

export interface KnockReceivable {
  /** 收到可接收数据（target 须在本回调内 receive/reject，不可持有跨事件） */
  onReceivable: (target: harmonyShare.ReceivableTarget) => void;
  /** 对端碰一碰请求分享（宿主导出临时文件后 target.share） */
  onKnock: (target: harmonyShare.SharableTarget) => void;
}

let registered = false;
let sendOn = false;
let receivable: KnockReceivable | null = null;
// on/off 以同一 capabilityRegistry 对象为键——解除必须复用注册时的引用，
// 现造结构会解除失败（回调残留=后台仍被系统唤醒，比不注册更糟）
let sendReg: harmonyShare.SendCapabilityRegistry | null = null;
let recvReg: harmonyShare.RecvCapabilityRegistry | null = null;

/**
 * 注册碰一碰接收（dataReceive 恒挂；发送注册由 knockSetSend 按需挂）。
 * windowId=主窗口（单窗口应用恒定）。幂等：重复注册前先解除。
 *
 * 发送与接收分开注册是系统选端语义的要求：系统按「哪端前台注册了发送
 * 能力」判定分享端——无文档的一端若仍挂发送注册，系统会把碰撞回调判给
 * 它（而非有文档的对端），它又无内容可发，传输就断了。
 */
export function knockRegister(winId: number, recv: KnockReceivable,
  log: (m: string) => void): void {
  if (!knockSupported()) {
    log('KNOCK_REG_SKIP no-syscap');
    return;
  }
  knockUnregister(log);
  receivable = recv;
  recvReg = {
    windowId: winId,
    capabilities: recvCapabilities(),
  };
  harmonyShare.on('dataReceive', recvReg,
    (target: harmonyShare.ReceivableTarget) => {
      log('KNOCK_EVENT dataReceive');
      if (receivable !== null) {
        receivable.onReceivable(target);
      }
    });
  registered = true;
  log('KNOCK_REG win=' + winId);
}

/**
 * 挂/撤发送注册（knockShare）。幂等：状态不变时 no-op。
 * on=true 声明本端有可分享内容（有打开的文档），系统才会在碰撞时把
 * 发送回调判给本端；on=false 回到纯接收姿态。
 */
export function knockSetSend(on: boolean, winId: number,
  log: (m: string) => void): void {
  if (!registered || sendOn === on) {
    return;
  }
  try {
    if (on) {
      sendReg = { windowId: winId };
      harmonyShare.on('knockShare', sendReg, (target: harmonyShare.SharableTarget) => {
        log('KNOCK_EVENT knockShare');
        if (receivable !== null) {
          receivable.onKnock(target);
        }
      });
    } else if (sendReg !== null) {
      harmonyShare.off('knockShare', sendReg);
      sendReg = null;
    }
    sendOn = on;
    log('KNOCK_SEND_REG ' + (on ? 'on' : 'off'));
  } catch (e) {
    log('KNOCK_SEND_REG_ERR ' + String(e));
  }
}

/** 解除注册（onPageHide 必调；未注册时 no-op）。解除失败保持 registered，
 *  下次注册重试（见 sendReg/recvReg 注释）。 */
export function knockUnregister(log: (m: string) => void): void {
  if (!registered) {
    return;
  }
  let ok = true;
  try {
    if (sendReg !== null) {
      harmonyShare.off('knockShare', sendReg);
    }
    if (recvReg !== null) {
      harmonyShare.off('dataReceive', recvReg);
    }
  } catch (e) {
    ok = false;
    log('KNOCK_OFF_ERR ' + String(e));
  }
  if (ok) {
    sendReg = null;
    recvReg = null;
    receivable = null;
    registered = false;
    sendOn = false;
    log('KNOCK_UNREG');
  }
}
