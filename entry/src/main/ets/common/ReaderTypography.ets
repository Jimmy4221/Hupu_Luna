import { uiAppearance } from '@kit.ArkUI';

/** Reader sizing shared by post replies and esports ratings. Choice 0 follows device accessibility settings. */
export class ReaderTypography {
  static fontSize(base: number, scaleChoice: number): number {
    if (scaleChoice > 0) {
      const customScales: number[] = [1, 0.9, 1, 1.15, 1.3];
      return base * (customScales[scaleChoice] ?? 1);
    }
    try {
      const scale: number = uiAppearance.getFontScale();
      return base * (Number.isFinite(scale) && scale > 0 ? scale : 1);
    } catch (e) {
      return base;
    }
  }

  static fontWeight(base: number, weightChoice: number): number {
    if (weightChoice === 1) return 400;
    if (weightChoice === 2) return 500;
    if (weightChoice === 3) return 700;
    try {
      const scale: number = uiAppearance.getFontWeightScale();
      const adjusted: number = Math.round((base * (Number.isFinite(scale) && scale > 0 ? scale : 1)) / 100) * 100;
      return Math.max(100, Math.min(900, adjusted));
    } catch (e) {
      return base;
    }
  }
}
