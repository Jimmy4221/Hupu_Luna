/**
 * 触感反馈工具：底部 Tab 切换等轻交互使用
 * 依赖 ohos.permission.VIBRATE（普通权限，安装即授予，无需弹窗）
 */
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAP_ATTR: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };

/** 轻点震动（默认 10ms，短促不粘手） */
export function hapticTap(duration: number = 10): void {
  const effect: vibrator.VibrateEffect = { type: 'time', duration: duration };
  try {
    vibrator.startVibration(effect, TAP_ATTR).catch((err: BusinessError) => {
      console.warn(`[Haptics] vibrate failed: ${err.code} ${err.message}`);
    });
  } catch (e) {
  }
}
