import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x7333;

export class Log {
  static d(tag: string, message: string): void {
    hilog.debug(DOMAIN, 'T3Code', '[%{public}s] %{public}s', tag, message);
  }

  static i(tag: string, message: string): void {
    hilog.info(DOMAIN, 'T3Code', '[%{public}s] %{public}s', tag, message);
  }

  static w(tag: string, message: string): void {
    hilog.warn(DOMAIN, 'T3Code', '[%{public}s] %{public}s', tag, message);
  }

  static e(tag: string, message: string): void {
    hilog.error(DOMAIN, 'T3Code', '[%{public}s] %{public}s', tag, message);
  }
}
