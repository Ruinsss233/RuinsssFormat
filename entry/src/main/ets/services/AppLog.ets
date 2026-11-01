import { fileIo as fs } from '@kit.CoreFileKit';

const MAX_MEMORY_LINES: number = 600;
const MAX_FILE_BYTES: number = 512 * 1024;
const LOAD_LINES: number = 300;

function two(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

function stamp(): string {
  const now: Date = new Date();
  return now.getFullYear().toString() + '-' + two(now.getMonth() + 1) + '-' + two(now.getDate()) +
    ' ' + two(now.getHours()) + ':' + two(now.getMinutes()) + ':' + two(now.getSeconds());
}

/**
 * Lightweight, local-only application log.
 *
 * It intentionally keeps only a bounded amount of text in memory and on disk. The log is meant
 * for diagnosing media/picker problems, so it never contains the video itself.
 */
export class AppLog {
  private static lines: string[] = [];
  private static filePath: string = '';
  private static initialized: boolean = false;

  static init(filesDir: string): void {
    if (AppLog.initialized && AppLog.filePath.length > 0) {
      return;
    }
    if (filesDir.length === 0) {
      return;
    }
    AppLog.filePath = filesDir + '/ruinsss-format.log';
    AppLog.initialized = true;
    try {
      if (fs.accessSync(AppLog.filePath)) {
        const stat: fs.Stat = fs.statSync(AppLog.filePath);
        if (stat.size > MAX_FILE_BYTES) {
          fs.truncateSync(AppLog.filePath, 0);
        } else if (stat.size > 0) {
          const text: string = fs.readTextSync(AppLog.filePath);
          const loaded: string[] = text.split('\n').filter((line: string) => line.length > 0);
          AppLog.lines = loaded.slice(-LOAD_LINES);
        }
      }
    } catch (e) {
      // Logging must never prevent the app from starting.
      AppLog.lines = [];
    }
  }

  private static persist(line: string): void {
    if (AppLog.filePath.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(AppLog.filePath)) {
        const stat: fs.Stat = fs.statSync(AppLog.filePath);
        if (stat.size > MAX_FILE_BYTES) {
          fs.truncateSync(AppLog.filePath, 0);
        }
      }
      const file: fs.File = fs.openSync(AppLog.filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, line + '\n');
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      // Ignore write failures: the in-memory log is still copyable.
    }
  }

  private static add(level: string, tag: string, message: string): void {
    const clean: string = message.replace(/\r/g, ' ').replace(/\n/g, ' ');
    const line: string = stamp() + '  ' + level + '  [' + tag + ']  ' + clean;
    AppLog.lines.push(line);
    if (AppLog.lines.length > MAX_MEMORY_LINES) {
      AppLog.lines = AppLog.lines.slice(-MAX_MEMORY_LINES);
    }
    console.info('[Ruinsss] ' + line);
    AppLog.persist(line);
  }

  static info(tag: string, message: string): void {
    AppLog.add('I', tag, message);
  }

  static warn(tag: string, message: string): void {
    AppLog.add('W', tag, message);
  }

  static error(tag: string, message: string): void {
    AppLog.add('E', tag, message);
  }

  static count(): number {
    return AppLog.lines.length;
  }

  static tail(maxLines: number): string {
    if (AppLog.lines.length === 0) {
      return '暂无日志。';
    }
    const start: number = Math.max(0, AppLog.lines.length - maxLines);
    return AppLog.lines.slice(start).join('\n');
  }

  static exportText(): string {
    const header: string = 'Ruinsss格式快转 V1.0.0 诊断日志\n' +
      '导出时间：' + stamp() + '\n' +
      '----------------------------------------\n';
    return header + (AppLog.lines.length > 0 ? AppLog.lines.join('\n') : '暂无日志。');
  }

  static clear(): void {
    AppLog.lines = [];
    if (AppLog.filePath.length > 0) {
      try {
        if (fs.accessSync(AppLog.filePath)) {
          fs.truncateSync(AppLog.filePath, 0);
        }
      } catch (e) {
        // Keep the in-memory clear even if the sandbox file cannot be truncated.
      }
    }
  }
}
