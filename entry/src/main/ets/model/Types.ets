/** Data contracts shared by the native engine, file service and UI. */

export class AudioMeta {
  present: boolean = false;
  trackIndex: number = 0;
  mime: string = '';
  codec: string = '';
  sampleRate: number = 0;
  channels: number = 0;
  bitrate: number = 0;
  profile: number = -1;
  adts: number = 0;
  hasConfig: boolean = false;
  suggestedFormat: string = 'none';
  extension: string = '';
  canExtract: boolean = false;
  reason: string = '';
}

export class VideoMeta {
  present: boolean = false;
  mime: string = '';
  codec: string = '';
  width: number = 0;
  height: number = 0;
  frameRate: number = 0;
}

export class ProbeResult {
  ok: boolean = false;
  error: string = '';
  durationUs: number = 0;
  trackCount: number = 0;
  sizeBytes: number = 0;
  audio: AudioMeta = new AudioMeta();
  video: VideoMeta = new VideoMeta();
}

export class ExtractProgress {
  state: string = 'idle';
  running: boolean = false;
  percent: number = 0;
  processedUs: number = 0;
  totalUs: number = 0;
  bytes: number = 0;
  elapsedMs: number = 0;
  speedBps: number = 0;
  error: string = '';
}

export class ExtractResult {
  ok: boolean = false;
  cancelled: boolean = false;
  error: string = '';
  format: string = '';
  bytes: number = 0;
  durationUs: number = 0;
  elapsedMs: number = 0;
}

export class HistoryItem {
  id: string = '';
  name: string = '';
  sourceName: string = '';
  size: number = 0;
  durationUs: number = 0;
  codec: string = '';
  format: string = '';
  savedAt: number = 0;
  outputUri: string = '';
}

/**
 * The output format is the file extension, not the source codec. Older builds
 * stored the source codec (often AAC) in HistoryItem.format; derive the real
 * container from the saved file name so existing records display correctly.
 */
export function historyFormat(item: HistoryItem): string {
  const lower: string = item.name.toLowerCase();
  if (lower.endsWith('.flac')) {
    return 'flac';
  }
  if (lower.endsWith('.mp3')) {
    return 'mp3';
  }
  if (lower.endsWith('.m4a')) {
    return 'm4a';
  }
  if (lower.endsWith('.aac')) {
    return 'aac';
  }
  if (lower.endsWith('.wav')) {
    return 'wav';
  }
  if (lower.endsWith('.aiff') || lower.endsWith('.aif')) {
    return 'aiff';
  }
  if (lower.endsWith('.ogg')) {
    return 'ogg';
  }
  if (lower.endsWith('.mp4')) {
    return 'mp4';
  }
  if (lower.endsWith('.mkv')) {
    return 'mkv';
  }
  if (lower.endsWith('.mov')) {
    return 'mov';
  }
  return item.format.length > 0 ? item.format : 'audio';
}

/** Parse the JSON emitted by ruinsss_media.probe(). */
export function parseProbe(text: string): ProbeResult {
  try {
    const value: ProbeResult = JSON.parse(text) as ProbeResult;
    if (value === null || value === undefined) {
      return new ProbeResult();
    }
    if (value.audio === undefined || value.audio === null) {
      value.audio = new AudioMeta();
    }
    if (value.video === undefined || value.video === null) {
      value.video = new VideoMeta();
    }
    return value;
  } catch (e) {
    const failed: ProbeResult = new ProbeResult();
    failed.error = '无法读取视频信息';
    return failed;
  }
}

export function parseProgress(text: string): ExtractProgress {
  try {
    const value: ExtractProgress = JSON.parse(text) as ExtractProgress;
    return value === null || value === undefined ? new ExtractProgress() : value;
  } catch (e) {
    return new ExtractProgress();
  }
}

export function parseExtract(text: string): ExtractResult {
  try {
    const value: ExtractResult = JSON.parse(text) as ExtractResult;
    return value === null || value === undefined ? new ExtractResult() : value;
  } catch (e) {
    const failed: ExtractResult = new ExtractResult();
    failed.error = '无法读取提取结果';
    return failed;
  }
}

export function parseHistory(text: string): HistoryItem[] {
  try {
    const value: HistoryItem[] = JSON.parse(text) as HistoryItem[];
    if (!Array.isArray(value)) {
      return [];
    }
    return value;
  } catch (e) {
    return [];
  }
}

/* ------------------------------------------------------------------ */
/* Formatting                                                         */
/* ------------------------------------------------------------------ */

export function formatBytes(bytes: number): string {
  if (bytes === undefined || bytes === null || !isFinite(bytes) || bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return Math.round(bytes).toString() + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb.toFixed(1) + ' KB';
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return mb.toFixed(1) + ' MB';
  }
  const gb: number = mb / 1024;
  return gb.toFixed(2) + ' GB';
}

export function formatDuration(us: number): string {
  if (us === undefined || us === null || !isFinite(us) || us <= 0) {
    return '--:--';
  }
  const total: number = Math.floor(us / 1000000);
  const hours: number = Math.floor(total / 3600);
  const minutes: number = Math.floor((total % 3600) / 60);
  const seconds: number = total % 60;
  if (hours > 0) {
    return hours.toString() + ':' + pad2(minutes) + ':' + pad2(seconds);
  }
  return pad2(minutes) + ':' + pad2(seconds);
}

export function formatEta(remainingUs: number): string {
  if (remainingUs <= 0 || !isFinite(remainingUs)) {
    return '计算中';
  }
  const total: number = Math.ceil(remainingUs / 1000000);
  if (total < 60) {
    return total.toString() + ' 秒';
  }
  const minutes: number = Math.floor(total / 60);
  const seconds: number = total % 60;
  if (minutes < 60) {
    return seconds > 0 ? minutes.toString() + ' 分 ' + seconds.toString() + ' 秒' :
      minutes.toString() + ' 分钟';
  }
  const hours: number = Math.floor(minutes / 60);
  return hours.toString() + ' 小时 ' + (minutes % 60).toString() + ' 分';
}

export function formatSpeed(bps: number): string {
  if (bps <= 0 || !isFinite(bps)) {
    return '0 KB/s';
  }
  const kb: number = bps / 1024;
  if (kb < 1) {
    return Math.max(1, Math.round(bps)).toString() + ' B/s';
  }
  if (kb < 1024) {
    return kb.toFixed(1) + ' KB/s';
  }
  return (kb / 1024).toFixed(1) + ' MB/s';
}

export function formatClock(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const date: Date = new Date(ms);
  return pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) + ' ' +
    pad2(date.getHours()) + ':' + pad2(date.getMinutes());
}

export function sampleRateText(hz: number): string {
  if (hz <= 0) {
    return '--';
  }
  return (hz / 1000).toFixed(1) + ' kHz';
}

export function bitrateText(bps: number): string {
  if (bps <= 0) {
    return '--';
  }
  return Math.round(bps / 1000).toString() + ' kbps';
}

export function channelText(channels: number): string {
  if (channels === 1) {
    return '单声道';
  }
  if (channels === 2) {
    return '立体声';
  }
  if (channels > 2) {
    return channels.toString() + ' 声道';
  }
  return '--';
}

export function resolutionText(width: number, height: number): string {
  if (width <= 0 || height <= 0) {
    return '';
  }
  return width.toString() + '×' + height.toString();
}

/** File name without directory or extension. */
export function baseName(name: string): string {
  let s: string = name;
  if (s.length === 0) {
    return '未命名视频';
  }
  const slash: number = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
  if (slash >= 0 && slash + 1 < s.length) {
    s = s.substring(slash + 1);
  }
  const dot: number = s.lastIndexOf('.');
  if (dot > 0) {
    s = s.substring(0, dot);
  }
  return s.length > 0 ? s : '未命名视频';
}

export function safeFileName(name: string): string {
  let out: string = '';
  for (let i = 0; i < name.length; i++) {
    const ch: string = name.charAt(i);
    if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' ||
      ch === '"' || ch === '<' || ch === '>' || ch === '|') {
      out += '_';
    } else {
      out += ch;
    }
  }
  out = out.trim();
  if (out.length > 56) {
    out = out.substring(0, 56);
  }
  return out.length > 0 ? out : '音频';
}

export function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

export function errorText(e: Object): string {
  if (e === null || e === undefined) {
    return '未知错误';
  }
  const err: Error = e as Error;
  if (err.message !== undefined && err.message.length > 0) {
    return err.message;
  }
  return e.toString();
}
