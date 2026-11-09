import { window } from '@kit.ArkUI';

/** Temporarily follow device rotation while a video is in fullscreen playback. */
export class VideoOrientation {
  static async enterLandscape(): Promise<void> {
    await VideoOrientation.set(window.Orientation.USER_ROTATION_LANDSCAPE);
  }

  static async restorePortrait(): Promise<void> {
    await VideoOrientation.set(window.Orientation.USER_ROTATION_PORTRAIT);
  }

  private static async set(orientation: window.Orientation): Promise<void> {
    try {
      const stored: Object | undefined = AppStorage.get<Object>('mainWindow');
      if (stored !== undefined) {
        await (stored as window.Window).setPreferredOrientation(orientation);
      }
    } catch (e) {
      // Keep video playback available if the platform denies a rotation change.
    }
  }
}
