/**
 * Ruinsss格式快转 — V1.0.1
 *
 * One job, done properly: pull the original audio track out of a video,
 * losslessly, with a live progress display and a save-as destination.
 *
 * Visual language: pastel sakura + mint, frosted glass sheets, and a floating
 * "liquid glass" dock at the bottom. The dock is built from native ArkUI glass
 * materials (backgroundBlurStyle + layered translucency + specular border),
 * not a platform API called "LiquidGlass".
 */

import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import {
  AudioMeta, ExtractProgress, HistoryItem, ProbeResult,
  baseName, bitrateText, channelText, errorText, formatBytes, formatClock,
  formatDuration, formatEta, formatSpeed, historyFormat, resolutionText, sampleRateText
} from '../model/Types';
import { AppLog } from '../services/AppLog';
import { BackgroundService } from '../services/BackgroundService';
import { MediaService } from '../services/MediaService';
import { FileService, PickedVideo, SaveTarget } from '../services/FileService';
import { HistoryStore } from '../services/HistoryStore';
import { JobStore, PendingJob } from '../services/JobStore';
import {
  COLOR_BG_BOTTOM, COLOR_BG_MID, COLOR_BG_TOP, COLOR_BLUE, COLOR_BLUE_SOFT,
  COLOR_BLUE_STRONG, COLOR_CARD, COLOR_ERROR,
  COLOR_ERROR_SOFT, COLOR_FAINT, COLOR_GLASS, COLOR_INK, COLOR_LINE, COLOR_MINT,
  COLOR_MINT_SOFT, COLOR_PINK, COLOR_PINK_DARK, COLOR_PINK_SOFT, COLOR_SUB,
  PAGE_PADDING, RADIUS_CARD, SHADOW_CARD, SHADOW_DOCK
} from '../common/Theme';

function cancelLike(e: Object): boolean {
  const be: BusinessError = e as BusinessError;
  if (be.code === 13900042 || be.code === 14000011) {
    return true;
  }
  const message: string = errorText(e).toLowerCase();
  return message.indexOf('cancel') >= 0 || message.indexOf('取消') >= 0;
}

class TouchRipple {
  x: number;
  y: number;
  bornAt: number;

  constructor(x: number, y: number, bornAt: number) {
    this.x = x;
    this.y = y;
    this.bornAt = bornAt;
  }
}

class ChangelogItem {
  version: string;
  title: string;
  details: string[];

  constructor(version: string, title: string, details: string[]) {
    this.version = version;
    this.title = title;
    this.details = details;
  }
}

@Entry
@Component
struct Index {
  @State dockIndex: number = 0;
  @State phase: string = 'idle';
  @State inputUri: string = '';
  @State inputName: string = '';
  @State inputSize: number = 0;
  @State inputFd: number = -1;
  @State durationUs: number = 0;
  @State audioCodec: string = '';
  @State sampleRate: number = 0;
  @State channels: number = 0;
  @State bitrate: number = 0;
  @State suggestedFormat: string = '';
  @State suggestedExt: string = '';
  @State targetFormat: string = 'mp3';
  @State canExtract: boolean = false;
  @State unsupportedReason: string = '';
  @State videoCodec: string = '';
  @State videoWidth: number = 0;
  @State videoHeight: number = 0;
  @State errorMsg: string = '';
  @State progressPercent: number = 0;
  @State processedUs: number = 0;
  @State totalUs: number = 0;
  @State speedBps: number = 0;
  @State processedBytes: number = 0;
  @State elapsedMs: number = 0;
  @State outputName: string = '';
  @State outputUri: string = '';
  @State outputBytes: number = 0;
  @State outputElapsedMs: number = 0;
  @State cancelling: boolean = false;
  @State history: HistoryItem[] = [];
  @State historyLoaded: boolean = false;
  @State logText: string = '';
  @State logCount: number = 0;
  @State backgroundActive: boolean = false;
  @State resumeName: string = '';
  @State convertMode: string = 'audio';
  @State convertPhase: string = 'idle';
  @State convertUri: string = '';
  @State convertName: string = '';
  @State convertSize: number = 0;
  @State convertFd: number = -1;
  @State convertDurationUs: number = 0;
  @State convertAudioCodec: string = '';
  @State convertSampleRate: number = 0;
  @State convertAudioChannels: number = 0;
  @State convertVideoCodec: string = '';
  @State convertWidth: number = 0;
  @State convertHeight: number = 0;
  @State convertTargetFormat: string = 'mp3';
  @State convertVideoTarget: string = 'avc';
  @State convertProgressPercent: number = 0;
  @State convertOutputName: string = '';
  @State convertOutputUri: string = '';
  @State convertOutputBytes: number = 0;
  @State convertElapsedMs: number = 0;
  @State convertError: string = '';
  @State convertCancelling: boolean = false;
  @State convertBackgroundActive: boolean = false;
  @State changelogExpanded: boolean = true;

  private picked: PickedVideo | null = null;
  private target: SaveTarget | null = null;
  private pendingJob: PendingJob | null = null;
  private resumePrompted: boolean = false;
  private timer: number = -1;
  private picking: boolean = false;
  private starting: boolean = false;
  private convertPicked: PickedVideo | null = null;
  private convertTarget: SaveTarget | null = null;
  private convertTimer: number = -1;
  private convertPicking: boolean = false;
  private convertStarting: boolean = false;
  private transcoder: media.AVTranscoder | null = null;
  private transcodeReject: ((error: Error) => void) | null = null;
  private transcodeCancelTimer: number = -1;
  private readonly tabs: number[] = [0, 1, 2, 3, 4];
  private readonly repoUrl: string = 'https://github.com/Ruinsss233/RuinsssFormat';
  private readonly changelog: ChangelogItem[] = [
    new ChangelogItem('Beta 1', '初版落地', [
      '鸿蒙原生 ArkTS + NAPI 音频提取应用，V1.0.0。',
      '像素兔图标、Ruinsss 署名、液态玻璃底栏。',
      '音轨直提、另存为、进度条、10GB+ 文件流式处理。'
    ]),
    new ChangelogItem('Beta 2', '错误码 3 排查', [
      '针对提取时的错误码 3 增加阶段定位。',
      '检查封装格式与编码配置，为后续 FLAC/AAC 修复打底。'
    ]),
    new ChangelogItem('Beta 3', '诊断日志', [
      '新增日志页：最近 60 行、复制全部、清空。',
      '文件选择、探测、保存、提取/转码和错误都写入本地日志。',
      '日志只保存在应用沙箱，不包含文件内容，也不会上传。'
    ]),
    new ChangelogItem('Beta 4', 'MP3 / FLAC 输出', [
      '输出改为 MP3 / FLAC 等主流格式，不再显示 AAC / M4A。',
      '源编码匹配时无损直提；AAC 等源在设备内解码后重新编码。',
      '补齐 FLAC 封装参数与错误码 3 相关处理。'
    ]),
    new ChangelogItem('Beta 5', '后台提取', [
      '提取期间可以切换提取 / 记录 / 日志 / 关于页签。',
      '按返回键或 Home 键可转入后台继续处理。',
      '使用 DATA_TRANSFER 持续任务，并在通知栏显示后台状态。'
    ]),
    new ChangelogItem('Beta 6', '速度显示修复', [
      '写入速度按 B/s、KB/s、MB/s 自适应显示。',
      '修复 MP3 输出约 40KB/s 时显示为 0.0MB 的问题。'
    ]),
    new ChangelogItem('Beta 7', '中断恢复', [
      '持久化源文件、目标位置和任务格式。',
      '重新打开应用时可选择恢复上次提取，无需重新选文件。',
      '受封装器限制，恢复是重新封装到原目标，不是字节级续写。'
    ]),
    new ChangelogItem('Beta 8', 'FLAC 编码器修复', [
      '补齐 FLAC 编码器 bitrate、bits-per-coded-sample、compliance level。',
      '修复提示“无法配置音频编码器”的问题。'
    ]),
    new ChangelogItem('Beta 9', '记录格式修复', [
      '记录徽标按输出文件扩展名显示 MP3 / FLAC。',
      '源编码单独标注为“源 AAC / 源 MP3 / 源 FLAC”。'
    ]),
    new ChangelogItem('Beta 10', '取消误选', [
      '选完视频后新增“取消当前选择”。',
      '不需要退出选择器或强杀应用，可直接回到首页重选。'
    ]),
    new ChangelogItem('Beta 11', '记录定位', [
      '点击记录可跳转到文件所在位置。',
      '直接拉起系统文件管理器并传入文件夹 URI。',
      '文件管理器拉起失败时自动复制文件路径。'
    ]),
    new ChangelogItem('Beta 12', '樱花动态背景', [
      '全部页面改用樱花天空背景图。',
      '手指触摸处生成扩散水波，带多层光环和柔光。',
      '水波只做视觉反馈，不影响提取、页签和按钮操作。'
    ]),
    new ChangelogItem('Beta 13', '更新日志', [
      '内置更新日志，按每次需求推进 Beta 版本。'
    ]),
    new ChangelogItem('Beta 14', '记录定位修正', [
      '不再用音频或 general.file 兜底，避免跳到网易云音乐、邮箱等应用。',
      '点击记录直接拉起系统文件管理器，并传入文件所在文件夹 URI。',
      '文件管理器拉起失败时只复制路径，不再打开音频。'
    ]),
    new ChangelogItem('Beta 15', '转换工作台', [
      '新增音频转音频和视频转视频，入口独立为“转换”页签。',
      '音频转换复用直提/解码转码引擎，输出 MP3 或 FLAC。',
      '视频转换使用系统 AVTranscoder，输出 MP4（H.264 / H.265）。',
      '进度、取消、另存为、后台持续任务和 10GB+ 流式处理一并支持。'
    ]),
    new ChangelogItem('Beta 16', '多格式与作者主页', [
      '音频输出新增 WAV / AAC / AIFF，MP3 / FLAC 继续保留。',
      '视频仍输出 MP4；AVI / MKV / MOV / WMV / FLV 受系统容器限制，暂不支持。',
      '关于页新增 GitHub 作者头像与主页入口（Ruinsss233）。',
      '版本号升级为 V1.0.1。'
    ]),
    new ChangelogItem('Beta 17', '开源地址与一键上传', [
      '关于页新增开源仓库地址，可直接打开或复制。',
      '新增 GitHub 一键提交/推送脚本，支持首次建仓与手动指定仓库。'
    ]),
    new ChangelogItem('Beta 18', 'OGG 无损转封装', [
      '新增 OGG 输出选项；源音轨为 Opus / Vorbis 时可无损直封。',
      'MP3/AAC 等源没有系统 Vorbis/Opus 编码器，界面会明确提示并禁用生成。'
    ]),
    new ChangelogItem('Beta 19', '界面细节', [
      '提取与转换里的视频头像改为完整圆形，图片铺满裁切，不留方形黑边。',
      'MP3 / FLAC 等格式选项统一改为蓝底粉字。',
      '更新日志新增收起 / 展开按钮。'
    ])
  ];
  private rippleCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ripples: TouchRipple[] = [];
  private rippleTimer: number = -1;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  private lastRippleAt: number = 0;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private openGithub(): void {
    this.ctx().openLink('https://github.com/Ruinsss233').catch((e: BusinessError) => {
      this.logWarn('关于', '打开 GitHub 失败：' + errorText(e));
      promptAction.showToast({ message: '无法打开浏览器，已复制主页地址' });
      this.copyText('https://github.com/Ruinsss233', 'GitHub 主页');
    });
  }

  private openRepo(): void {
    this.ctx().openLink(this.repoUrl).catch((e: BusinessError) => {
      this.logWarn('关于', '打开开源仓库失败：' + errorText(e));
      promptAction.showToast({ message: '无法打开浏览器，已复制开源地址' });
      this.copyText(this.repoUrl, '开源地址');
    });
  }

  private spawnRipple(x: number, y: number): void {
    const now: number = Date.now();
    this.ripples.push(new TouchRipple(x, y, now));
    if (this.ripples.length > 14) {
      this.ripples.shift();
    }
    this.ensureRippleLoop();
  }

  private handleRippleTouch(event: TouchEvent): void {
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (event.type === TouchType.Move && now - this.lastRippleAt < 90) {
      return;
    }
    this.lastRippleAt = now;
    const touch: TouchObject = event.touches[0];
    this.spawnRipple(touch.x, touch.y);
  }

  private ensureRippleLoop(): void {
    if (this.rippleTimer >= 0) {
      return;
    }
    this.rippleTimer = setInterval(() => {
      this.drawRipples();
    }, 33);
  }

  private stopRippleLoop(): void {
    if (this.rippleTimer >= 0) {
      clearInterval(this.rippleTimer);
      this.rippleTimer = -1;
    }
    this.ripples = [];
    if (this.canvasWidth > 0 && this.canvasHeight > 0) {
      this.rippleCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    }
  }

  private drawRipples(): void {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.rippleCtx;
    const now: number = Date.now();
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    const alive: TouchRipple[] = [];
    for (let i = 0; i < this.ripples.length; i++) {
      const ripple: TouchRipple = this.ripples[i];
      const age: number = (now - ripple.bornAt) / 1150;
      if (age >= 1) {
        continue;
      }
      alive.push(ripple);
      const eased: number = 1 - Math.pow(1 - age, 3);
      const baseRadius: number = 16 + 128 * eased;
      const alpha: number = 0.52 * Math.pow(1 - age, 1.6);
      for (let ring: number = 0; ring < 3; ring++) {
        const radius: number = baseRadius * (1 - ring * 0.18);
        const ringAlpha: number = alpha * (1 - ring * 0.24);
        ctx.beginPath();
        ctx.arc(ripple.x, ripple.y, radius, 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(255,255,255,${ringAlpha.toFixed(3)})`;
        ctx.lineWidth = ring === 0 ? 1.8 : 1.0;
        ctx.stroke();
      }
      const glow: CanvasGradient = ctx.createRadialGradient(
        ripple.x, ripple.y, 0, ripple.x, ripple.y, baseRadius * 0.9);
      glow.addColorStop(0, `rgba(255,255,255,${(alpha * 0.18).toFixed(3)})`);
      glow.addColorStop(0.72, `rgba(255,214,232,${(alpha * 0.08).toFixed(3)})`);
      glow.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(ripple.x, ripple.y, baseRadius * 0.9, 0, Math.PI * 2);
      ctx.fill();
    }
    this.ripples = alive;
    if (this.ripples.length === 0 && this.rippleTimer >= 0) {
      clearInterval(this.rippleTimer);
      this.rippleTimer = -1;
    }
  }

  aboutToAppear(): void {
    AppLog.init(this.ctx().filesDir);
    AppLog.info('应用', '打开主页面，版本 V1.0.1');
    this.refreshLogs();
    this.loadHistory();
    this.loadPendingJob();
  }

  onPageShow(): void {
    if (this.phase === 'extracting') {
      this.refreshLogs();
      this.startPolling();
    } else if (this.convertPhase === 'working' && this.convertMode === 'audio') {
      this.refreshLogs();
      this.startConvertPolling();
    } else {
      this.maybeOfferResume();
    }
  }

  onPageHide(): void {
    this.stopRippleLoop();
    this.stopConvertPolling();
    if (this.phase === 'extracting') {
      this.stopPolling();
      AppLog.info('后台', '页面进入后台，提取继续');
    }
    if (this.convertPhase === 'working') {
      AppLog.info('后台', '页面进入后台，转换继续');
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.stopConvertPolling();
    this.stopRippleLoop();
    if (this.phase === 'extracting') {
      AppLog.info('后台', '页面离开，提取继续');
      return;
    }
    if (this.convertPhase === 'working') {
      AppLog.info('后台', '页面离开，转换继续');
      return;
    }
    this.closeInput();
    this.closeTarget();
    this.closeConvertInput();
    this.closeConvertTarget();
  }

  private refreshLogs(): void {
    this.logText = AppLog.tail(60);
    this.logCount = AppLog.count();
  }

  private logInfo(tag: string, message: string): void {
    AppLog.info(tag, message);
    this.refreshLogs();
  }

  private logWarn(tag: string, message: string): void {
    AppLog.warn(tag, message);
    this.refreshLogs();
  }

  private logError(tag: string, message: string): void {
    AppLog.error(tag, message);
    this.refreshLogs();
  }

  private async copyText(text: string, label: string): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: label + '已复制' });
    } catch (e) {
      promptAction.showToast({ message: '复制失败：' + errorText(e as Object) });
    }
  }

  private async copyLogs(): Promise<void> {
    await this.copyText(AppLog.exportText(), '日志');
    AppLog.info('日志', '日志已复制到剪贴板');
    this.refreshLogs();
  }

  private clearLogs(): void {
    AppLog.clear();
    AppLog.info('日志', '日志已清空');
    this.refreshLogs();
    promptAction.showToast({ message: '日志已清空' });
  }

  /**
   * Open the system file manager at the folder containing the output file.
   * We deliberately use the file-manager Ability directly instead of the
   * generic viewData route: the latter can match music players or mail apps.
   * No audio player is ever launched from a history row.
   */
  private async revealOutput(item: HistoryItem): Promise<void> {
    if (item.outputUri.length === 0) {
      promptAction.showToast({ message: '这条旧记录没有保存文件位置' });
      return;
    }
    const slash: number = item.outputUri.lastIndexOf('/');
    const folderUri: string = slash > 7 ? item.outputUri.substring(0, slash) : item.outputUri;
    try {
      await this.ctx().startAbility({
        bundleName: 'com.huawei.hmos.filemanager',
        abilityName: 'MainAbility',
        parameters: {
          'fileUri': folderUri
        }
      });
      this.logInfo('记录', '文件管理器定位：' + folderUri);
    } catch (e) {
      this.logError('记录', '文件管理器定位失败：' + errorText(e as Object));
      await this.copyText(item.outputUri, '文件路径');
    }
  }

  private isDirect(): boolean {
    return (this.targetFormat === 'mp3' && this.audioCodec === 'MP3') ||
      (this.targetFormat === 'flac' && this.audioCodec === 'FLAC') ||
      (this.targetFormat === 'ogg' && (this.audioCodec === 'Opus' || this.audioCodec === 'Vorbis'));
  }

  private canStartExtract(): boolean {
    return this.canExtract && (this.targetFormat !== 'ogg' || this.isDirect());
  }

  private formatBadge(): string {
    if (this.targetFormat === 'ogg') {
      return this.isDirect() ? 'OGG 直封' : '当前源不可用';
    }
    return this.isDirect() ? '原音轨直提' : '需要转码';
  }

  private targetNote(): string {
    if (this.isDirect()) {
      return '原音轨直接封装，速度接近硬盘读写';
    }
    if (this.targetFormat === 'ogg') {
      return '系统没有 Vorbis/Opus 编码器：只有源音轨本身是 OGG / Opus / Vorbis 时才能无损转封装为 OGG，MP3/AAC 等源无法生成 OGG。';
    }
    if (this.targetFormat === 'flac') {
      return '解码后重新编码为 FLAC；源为 AAC/MP3 时不会恢复已丢失的细节';
    }
    if (this.targetFormat === 'wav') {
      return '解码为 16-bit PCM WAV，兼容性最好，但体积很大';
    }
    if (this.targetFormat === 'aac') {
      return '解码后重新编码为 AAC 192kbps，适合手机和苹果设备';
    }
    if (this.targetFormat === 'aiff') {
      return '解码为 16-bit PCM AIFF，适合专业音频软件';
    }
    return '解码后重新编码为 MP3 320kbps；适合分享和车载播放';
  }

  private selectFormat(format: string): void {
    if (this.phase === 'extracting') {
      return;
    }
    this.targetFormat = format;
    AppLog.info('格式', '输出格式切换为 ' + format.toUpperCase());
    this.refreshLogs();
  }

  onBackPress(): boolean {
    if (this.phase === 'extracting') {
      this.moveToBackground();
      return true;
    }
    if (this.convertPhase === 'working') {
      this.moveConvertToBackground();
      return true;
    }
    if (this.dockIndex !== 0) {
      this.dockIndex = 0;
      return true;
    }
    if (this.convertPhase !== 'idle') {
      this.resetConvert(true);
      return true;
    }
    if (this.phase !== 'idle') {
      this.resetAll();
      return true;
    }
    return false;
  }

  /* ------------------------------------------------------------------ */
  /* Data                                                               */
  /* ------------------------------------------------------------------ */

  private async loadHistory(): Promise<void> {
    try {
      this.history = await HistoryStore.load(this.ctx());
    } catch (e) {
      this.history = [];
    }
    this.historyLoaded = true;
  }

  private async pickVideo(): Promise<void> {
    if (this.phase === 'extracting' || this.picking) {
      return;
    }
    this.picking = true;
    this.dockIndex = 0;
    this.logInfo('选择', '打开系统文件选择器');
    try {
      const picked: PickedVideo | null = await FileService.pickVideo(this.ctx());
      if (picked === null) {
        this.logInfo('选择', '用户取消选择文件');
        return;
      }
      this.logInfo('选择', '已选择 ' + picked.name + '，' + formatBytes(picked.size));
      this.closeInput();
      this.closeTarget();
      this.picked = picked;
      const file = picked.file;
      if (file === null) {
        this.fail('无法打开这个视频');
        return;
      }
      this.inputFd = file.fd;
      this.inputUri = picked.uri;
      this.inputName = picked.name;
      this.inputSize = picked.size;
      this.phase = 'analyzing';
      this.errorMsg = '';
      this.clearMeta();
      await this.analyze();
    } catch (e) {
      if (!cancelLike(e as Object)) {
        this.fail(errorText(e as Object));
      }
    } finally {
      this.picking = false;
    }
  }

  private async analyze(): Promise<void> {
    try {
      this.logInfo('探测', '开始读取媒体信息，fd=' + this.inputFd.toString() + '，大小=' +
        formatBytes(this.inputSize));
      const probe: ProbeResult = MediaService.probe(this.inputFd, this.inputSize);
      if (!probe.ok) {
        const message: string = probe.error.length > 0 ? probe.error : '无法解析这个视频';
        this.logError('探测', message);
        this.fail(message);
        return;
      }
      this.applyProbe(probe);
      this.logInfo('探测', '音轨=' + this.audioCodec + '，采样率=' + this.sampleRate.toString() +
        '，声道=' + this.channels.toString() + '，封装=' + this.suggestedFormat +
        '，时长=' + formatDuration(this.durationUs));
      this.phase = 'ready';
    } catch (e) {
      this.logError('探测', '读取媒体信息异常：' + errorText(e as Object));
      this.fail(errorText(e as Object));
    }
  }

  private applyProbe(probe: ProbeResult): void {
    this.durationUs = probe.durationUs > 0 ? probe.durationUs : 0;
    this.inputSize = probe.sizeBytes > 0 ? probe.sizeBytes : this.inputSize;
    const audio: AudioMeta = probe.audio;
    this.audioCodec = audio.codec;
    this.sampleRate = audio.sampleRate;
    this.channels = audio.channels;
    this.bitrate = audio.bitrate;
    this.suggestedFormat = audio.suggestedFormat;
    this.suggestedExt = audio.extension;
    this.canExtract = audio.canExtract;
    this.unsupportedReason = audio.reason;
    this.videoCodec = probe.video.present ? probe.video.codec : '';
    this.videoWidth = probe.video.width;
    this.videoHeight = probe.video.height;
    if (this.durationUs <= 0) {
      this.durationUs = 0;
    }
    if (this.suggestedExt.length === 0 && this.suggestedFormat !== 'none') {
      this.suggestedExt = this.suggestedFormat;
    }
  }

  private clearMeta(): void {
    this.durationUs = 0;
    this.audioCodec = '';
    this.sampleRate = 0;
    this.channels = 0;
    this.bitrate = 0;
    this.suggestedFormat = '';
    this.suggestedExt = '';
    this.canExtract = false;
    this.unsupportedReason = '';
    this.videoCodec = '';
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.progressPercent = 0;
    this.processedUs = 0;
    this.totalUs = 0;
    this.speedBps = 0;
    this.processedBytes = 0;
    this.elapsedMs = 0;
  }

  private async startExtract(): Promise<void> {
    if ((this.phase !== 'ready' && this.phase !== 'error') ||
      !this.canExtract || this.inputFd < 0 || this.starting) {
      return;
    }
    if (!this.canStartExtract()) {
      promptAction.showToast({ message: '当前源无法生成 OGG，请换 MP3/FLAC/WAV 等格式' });
      return;
    }
    if (this.convertPhase === 'working' || this.convertStarting) {
      promptAction.showToast({ message: '请先等待当前转换完成' });
      return;
    }
    const extension: string = this.targetFormat;
    this.starting = true;
    let save: SaveTarget | null = null;
    try {
      save = await FileService.chooseSave(this.ctx(), this.inputName, extension);
    } catch (e) {
      if (!cancelLike(e as Object)) {
        this.logError('保存', '打开保存窗口失败：' + errorText(e as Object));
        promptAction.showToast({ message: '无法打开保存窗口：' + errorText(e as Object) });
      } else {
        this.logInfo('保存', '用户取消保存窗口');
      }
      this.starting = false;
      return;
    }
    if (save === null) {
      this.starting = false;
      return;
    }
    if (save.uri === this.inputUri) {
      FileService.closeFile(save.file);
      this.starting = false;
      this.logError('保存', '目标文件不能与源视频相同');
      promptAction.showToast({ message: '不能覆盖源视频，请换一个文件名' });
      return;
    }
    await this.runExtract(save, extension);
  }

  private async runExtract(save: SaveTarget, extension: string): Promise<void> {
    const file = save.file;
    if (file === null) {
      this.starting = false;
      this.fail('无法写入保存位置');
      return;
    }
    this.target = save;
    this.outputUri = save.uri;
    this.outputName = FileService.displayName(save.uri);
    this.logInfo('保存', '目标文件=' + this.outputName + '，格式=' + extension);
    this.outputBytes = 0;
    this.outputElapsedMs = 0;
    this.errorMsg = '';
    this.cancelling = false;
    this.phase = 'extracting';
    this.progressPercent = 0;
    this.processedUs = 0;
    this.totalUs = this.durationUs;
    this.speedBps = 0;
    this.processedBytes = 0;
    this.elapsedMs = 0;

    const job: PendingJob = new PendingJob();
    job.inputUri = this.inputUri;
    job.inputName = this.inputName;
    job.inputSize = this.inputSize;
    job.outputUri = save.uri;
    job.outputName = this.outputName;
    job.format = extension;
    job.durationUs = this.durationUs;
    job.createdAt = Date.now();
    this.pendingJob = job;
    this.resumeName = this.outputName;
    this.resumePrompted = true;
    await JobStore.save(this.ctx(), job);

    const backgroundReady: boolean = await BackgroundService.start(this.ctx());
    this.backgroundActive = backgroundReady;
    if (!backgroundReady) {
      this.logWarn('后台', '持续任务未开启，切后台可能被系统暂停');
      promptAction.showToast({ message: '后台运行申请失败，请保持应用在前台' });
    }
    this.startPolling();

    try {
      const result = await MediaService.extract(
        this.inputFd, this.inputSize, file.fd, extension);
      this.stopPolling();
      if (result.cancelled) {
        this.closeTarget();
        FileService.tryDelete(save.uri);
        this.outputUri = '';
        this.outputName = '';
        this.phase = 'ready';
        this.cancelling = false;
        await this.clearPendingJob(true);
        promptAction.showToast({ message: '已取消提取' });
        return;
      }
      if (!result.ok) {
        this.fail(result.error.length > 0 ? result.error : '提取失败');
        this.closeTarget();
        FileService.tryDelete(save.uri);
        this.outputUri = '';
        await this.clearPendingJob(true);
        return;
      }
      this.closeTarget();
      this.outputBytes = result.bytes > 0 ? result.bytes : FileService.sizeOf(save.uri);
      this.outputElapsedMs = result.elapsedMs;
      if (result.durationUs > 0) {
        this.durationUs = result.durationUs;
      }
      this.phase = 'success';
      this.cancelling = false;
      await this.addHistory(save.uri);
      await this.clearPendingJob(true);
      promptAction.showToast({ message: '提取完成：' + this.outputName });
    } catch (e) {
      this.stopPolling();
      this.closeTarget();
      FileService.tryDelete(save.uri);
      this.outputUri = '';
      this.fail(errorText(e as Object));
      await this.clearPendingJob(true);
    } finally {
      this.starting = false;
      this.stopPolling();
      if (this.backgroundActive) {
        this.backgroundActive = false;
        await BackgroundService.stop(this.ctx());
      }
    }
  }

  private async clearPendingJob(releaseUris: boolean): Promise<void> {
    const job: PendingJob | null = this.pendingJob;
    this.pendingJob = null;
    this.resumeName = '';
    this.resumePrompted = false;
    await JobStore.clear(this.ctx());
    if (releaseUris && job !== null) {
      await FileService.release([job.inputUri, job.outputUri]);
    }
  }

  private async loadPendingJob(): Promise<void> {
    try {
      const job: PendingJob | null = await JobStore.load(this.ctx());
      if (job !== null) {
        this.pendingJob = job;
        this.resumeName = job.outputName.length > 0 ? job.outputName : job.inputName;
        this.logInfo('恢复', '发现未完成任务：' + job.inputName + ' → ' + job.outputName);
      }
    } catch (e) {
      this.pendingJob = null;
    }
    this.maybeOfferResume();
  }

  private maybeOfferResume(): void {
    const job: PendingJob | null = this.pendingJob;
    if (job === null || this.resumePrompted || this.starting || this.phase === 'extracting') {
      return;
    }
    this.resumePrompted = true;
    AlertDialog.show({
      title: '恢复上次提取',
      message: '上次任务未完成：\n' + job.inputName + '\n→ ' + job.outputName +
        '\n\n源文件和目标位置已保留。恢复会重新封装到原文件，不需要重新选择；中途被系统终止的任务无法从字节中间续写。',
      primaryButton: {
        value: '恢复提取',
        action: () => {
          this.resumeJob(job);
        }
      },
      secondaryButton: {
        value: '放弃',
        action: () => {
          this.discardPendingJob(job);
        }
      },
      cancel: () => {
        this.resumePrompted = true;
      }
    });
  }

  private async discardPendingJob(job: PendingJob): Promise<void> {
    this.pendingJob = null;
    this.resumeName = '';
    this.resumePrompted = false;
    await JobStore.clear(this.ctx());
    FileService.tryDelete(job.outputUri);
    await FileService.release([job.inputUri, job.outputUri]);
    this.logInfo('恢复', '已放弃上次未完成任务');
    promptAction.showToast({ message: '已放弃上次任务' });
  }

  private async resumeJob(job: PendingJob): Promise<void> {
    if (this.starting || this.phase === 'extracting') {
      return;
    }
    this.starting = true;
    this.resumePrompted = true;
    try {
      this.closeInput();
      this.closeTarget();
      const picked: PickedVideo = new PickedVideo();
      picked.uri = job.inputUri;
      picked.name = job.inputName;
      picked.size = fileIo.statSync(job.inputUri).size;
      picked.file = fileIo.openSync(job.inputUri, fileIo.OpenMode.READ_ONLY);
      this.picked = picked;
      this.inputFd = picked.file.fd;
      this.inputUri = picked.uri;
      this.inputName = picked.name;
      this.inputSize = picked.size;
      this.phase = 'analyzing';
      this.clearMeta();
      this.logInfo('恢复', '重新打开源文件并读取媒体信息');
      await this.analyze();
      if (this.phase !== 'ready' || !this.canExtract) {
        await this.discardPendingJob(job);
        this.starting = false;
        return;
      }
      this.targetFormat = job.format === 'flac' ? 'flac' : 'mp3';
      const target: SaveTarget = new SaveTarget();
      target.uri = job.outputUri;
      target.name = job.outputName;
      target.file = fileIo.openSync(job.outputUri, fileIo.OpenMode.READ_WRITE);
      this.target = target;
      this.logInfo('恢复', '继续写入原目标文件，格式=' + this.targetFormat.toUpperCase());
      await this.runExtract(target, this.targetFormat);
    } catch (e) {
      this.starting = false;
      this.fail('无法恢复上次任务：' + errorText(e as Object));
      await this.discardPendingJob(job);
    }
  }

  private async addHistory(uri: string): Promise<void> {
    const item: HistoryItem = new HistoryItem();
    item.id = Date.now().toString() + '-' + Math.floor(Math.random() * 1000).toString();
    item.name = this.outputName.length > 0 ? this.outputName : '提取的音频';
    item.sourceName = this.inputName;
    item.size = this.outputBytes;
    item.durationUs = this.durationUs;
    item.codec = this.audioCodec;
    item.format = this.targetFormat;
    item.savedAt = Date.now();
    item.outputUri = uri;
    const next: HistoryItem[] = [item];
    for (let i = 0; i < this.history.length && i < 29; i++) {
      next.push(this.history[i]);
    }
    this.history = next;
    await HistoryStore.save(this.ctx(), this.history);
  }

  private async clearHistory(): Promise<void> {
    this.history = [];
    await HistoryStore.clear(this.ctx());
    promptAction.showToast({ message: '记录已清除' });
  }

  private cancelExtract(): void {
    if (this.phase !== 'extracting' || this.cancelling) {
      return;
    }
    this.cancelling = true;
    MediaService.cancel();
  }

  private moveToBackground(): void {
    this.logInfo('后台', '返回键离开，提取转入后台');
    promptAction.showToast({ message: '提取转入后台继续' });
    this.ctx().moveAbilityToBackground().catch((e: Error) => {
      this.logWarn('后台', '自动转后台失败：' + e.message);
      promptAction.showToast({ message: '无法自动转后台，请按 Home 键' });
    });
  }

  private resetAll(): void {
    if (this.phase === 'extracting') {
      return;
    }
    this.stopPolling();
    this.closeInput();
    this.closeTarget();
    this.phase = 'idle';
    this.dockIndex = 0;
    this.errorMsg = '';
    this.outputUri = '';
    this.outputName = '';
    this.outputBytes = 0;
    this.outputElapsedMs = 0;
    this.cancelling = false;
    this.clearMeta();
  }

  private closeInput(): void {
    if (this.picked !== null) {
      FileService.closeFile(this.picked.file);
      this.picked = null;
    }
    this.inputFd = -1;
    this.inputUri = '';
    this.inputName = '';
    this.inputSize = 0;
  }

  private closeTarget(): void {
    if (this.target !== null) {
      FileService.closeFile(this.target.file);
      this.target = null;
    }
  }

  private fail(message: string): void {
    this.stopPolling();
    this.phase = 'error';
    this.errorMsg = message.length > 0 ? message : '发生了未知错误';
    this.logError('提取', this.errorMsg);
    this.cancelling = false;
  }

  private retry(): void {
    if (this.inputFd >= 0 && this.canExtract) {
      this.phase = 'ready';
      this.startExtract();
      return;
    }
    this.resetAll();
    this.pickVideo();
  }

  /* ------------------------------------------------------------------ */
  /* Conversion                                                         */
  /* ------------------------------------------------------------------ */

  private selectConvertMode(mode: string): void {
    if (this.convertMode === mode) {
      return;
    }
    if (this.convertPhase === 'working' || this.convertPhase === 'analyzing' || this.convertStarting) {
      promptAction.showToast({ message: '当前转换进行中，完成后再切换类型' });
      return;
    }
    this.convertMode = mode;
    this.resetConvert(true);
    this.logInfo('转换', mode === 'audio' ? '切换到音频转音频' : '切换到视频转视频');
  }

  private async pickConvert(): Promise<void> {
    if (this.convertPicking || this.convertStarting || this.convertPhase === 'working' ||
      this.convertPhase === 'analyzing' || this.phase === 'extracting') {
      return;
    }
    this.convertPicking = true;
    this.convertError = '';
    this.convertPhase = 'analyzing';
    this.logInfo('转换', this.convertMode === 'audio' ? '打开音频选择器' : '打开视频选择器');
    try {
      const picked: PickedVideo | null = this.convertMode === 'audio' ?
        await FileService.pickAudio(this.ctx()) : await FileService.pickVideo(this.ctx());
      if (picked === null) {
        this.convertPhase = this.convertFd >= 0 ? 'ready' : 'idle';
        this.logInfo('转换', '用户取消选择文件');
        return;
      }
      const file = picked.file;
      if (file === null) {
        this.failConvert('无法打开这个文件');
        return;
      }
      this.closeConvertInput();
      this.closeConvertTarget();
      this.convertPicked = picked;
      this.convertUri = picked.uri;
      this.convertName = picked.name;
      this.convertSize = picked.size;
      this.convertFd = file.fd;
      this.convertProgressPercent = 0;
      this.convertOutputBytes = 0;
      this.convertElapsedMs = 0;
      this.convertOutputName = '';
      this.convertOutputUri = '';
      this.logInfo('转换', '已选择 ' + picked.name + '，' + formatBytes(picked.size));
      const probe: ProbeResult = MediaService.probe(this.convertFd, this.convertSize);
      if (!probe.ok) {
        this.failConvert(probe.error.length > 0 ? probe.error : '无法解析这个文件');
        return;
      }
      if (this.convertMode === 'audio') {
        if (!probe.audio.present) {
          this.failConvert('这个文件没有可转换的音频轨道');
          return;
        }
        if (!probe.audio.canExtract) {
          this.failConvert(probe.audio.reason.length > 0 ? probe.audio.reason :
            '这个音频编码暂不支持转换');
          return;
        }
      } else if (!probe.video.present) {
        this.failConvert('这个文件没有视频画面，请切换到音频转音频');
        return;
      }
      this.convertDurationUs = probe.durationUs;
      this.convertAudioCodec = probe.audio.present ? probe.audio.codec : '';
      this.convertSampleRate = probe.audio.sampleRate;
      this.convertAudioChannels = probe.audio.channels;
      this.convertVideoCodec = probe.video.present ? probe.video.codec : '';
      this.convertWidth = probe.video.width;
      this.convertHeight = probe.video.height;
      this.convertPhase = 'ready';
      this.logInfo('转换', '媒体信息：' + this.convertSummary() + '，时长=' +
        formatDuration(this.convertDurationUs));
    } catch (e) {
      if (!cancelLike(e as Object)) {
        this.failConvert(errorText(e as Object));
      } else {
        this.convertPhase = this.convertFd >= 0 ? 'ready' : 'idle';
      }
    } finally {
      this.convertPicking = false;
    }
  }

  private convertSummary(): string {
    if (this.convertMode === 'audio') {
      return (this.convertAudioCodec.length > 0 ? this.convertAudioCodec.toUpperCase() : '音频') +
        ' · ' + sampleRateText(this.convertSampleRate) + ' · ' +
        channelText(this.convertAudioChannels);
    }
    const size: string = resolutionText(this.convertWidth, this.convertHeight);
    return (this.convertVideoCodec.length > 0 ? this.convertVideoCodec.toUpperCase() : '视频') +
      (size.length > 0 ? ' · ' + size : '');
  }

  private async startConversion(): Promise<void> {
    if ((this.convertPhase !== 'ready' && this.convertPhase !== 'error') ||
      this.convertFd < 0 || this.convertStarting) {
      return;
    }
    if (this.convertMode === 'audio' && !this.canConvertAudioOutput()) {
      promptAction.showToast({ message: '当前源无法生成 OGG，请换 MP3/FLAC/WAV 等格式' });
      return;
    }
    if (this.phase === 'extracting') {
      promptAction.showToast({ message: '请先等待当前提取完成' });
      return;
    }
    const extension: string = this.convertMode === 'audio' ? this.convertTargetFormat : 'mp4';
    const label: string = this.convertMode === 'audio' ? '转换' : '视频';
    this.convertStarting = true;
    let save: SaveTarget | null = null;
    try {
      save = await FileService.chooseSave(this.ctx(), this.convertName, extension, label);
    } catch (e) {
      if (!cancelLike(e as Object)) {
        this.logError('转换', '打开保存窗口失败：' + errorText(e as Object));
        promptAction.showToast({ message: '无法打开保存窗口：' + errorText(e as Object) });
      } else {
        this.logInfo('转换', '用户取消保存窗口');
      }
      this.convertStarting = false;
      return;
    }
    if (save === null) {
      this.convertStarting = false;
      return;
    }
    if (save.uri === this.convertUri) {
      FileService.closeFile(save.file);
      this.convertStarting = false;
      this.logError('转换', '目标文件不能与源文件相同');
      promptAction.showToast({ message: '不能覆盖源文件，请换一个文件名' });
      return;
    }
    await this.runConversion(save, extension);
  }

  private async runConversion(save: SaveTarget, extension: string): Promise<void> {
    const file = save.file;
    if (file === null) {
      this.convertStarting = false;
      this.failConvert('无法写入保存位置');
      return;
    }
    this.convertTarget = save;
    this.convertOutputUri = save.uri;
    this.convertOutputName = FileService.displayName(save.uri);
    this.convertOutputBytes = 0;
    this.convertElapsedMs = 0;
    this.convertError = '';
    this.convertCancelling = false;
    this.convertProgressPercent = 0;
    this.convertPhase = 'working';
    const startedAt: number = Date.now();
    this.convertStartedAt = startedAt;
    this.logInfo('转换', '开始处理：' + this.convertName + ' → ' + this.convertOutputName +
      '（' + extension.toUpperCase() + '）');

    const backgroundReady: boolean = await BackgroundService.start(this.ctx());
    this.convertBackgroundActive = backgroundReady;
    if (!backgroundReady) {
      this.logWarn('转换', '持续任务未开启，切后台可能被系统暂停');
      promptAction.showToast({ message: '后台运行申请失败，请保持应用在前台' });
    }

    try {
      if (this.convertMode === 'audio') {
        this.startConvertPolling();
        const result = await MediaService.extract(
          this.convertFd, this.convertSize, file.fd, extension);
        this.stopConvertPolling();
        if (result.cancelled) {
          this.closeConvertTarget();
          FileService.tryDelete(save.uri);
          this.convertOutputUri = '';
          this.convertOutputName = '';
          this.convertPhase = 'ready';
          promptAction.showToast({ message: '已取消转换' });
          return;
        }
        if (!result.ok) {
          throw new Error(result.error.length > 0 ? result.error : '转换失败');
        }
        this.convertElapsedMs = result.elapsedMs > 0 ? result.elapsedMs : Date.now() - startedAt;
      } else {
        await this.runVideoTranscode(save);
        this.convertElapsedMs = Date.now() - startedAt;
      }
      this.closeConvertTarget();
      this.convertOutputBytes = FileService.sizeOf(save.uri);
      this.convertProgressPercent = 100;
      this.convertPhase = 'success';
      await this.addConvertHistory(save.uri);
      this.logInfo('转换', '完成：' + this.convertOutputName + '，' +
        formatBytes(this.convertOutputBytes) + '，耗时 ' + this.elapsedText(this.convertElapsedMs));
      promptAction.showToast({ message: '转换完成：' + this.convertOutputName });
    } catch (e) {
      this.stopConvertPolling();
      this.closeConvertTarget();
      FileService.tryDelete(save.uri);
      this.convertOutputUri = '';
      if (this.convertCancelling || cancelLike(e as Object)) {
        this.convertPhase = 'ready';
        this.convertCancelling = false;
        this.logInfo('转换', '已取消转换');
        promptAction.showToast({ message: '已取消转换' });
      } else {
        this.failConvert(errorText(e as Object));
      }
    } finally {
      this.convertStarting = false;
      this.stopConvertPolling();
      this.convertCancelling = false;
      if (this.convertBackgroundActive) {
        this.convertBackgroundActive = false;
        await BackgroundService.stop(this.ctx());
      }
    }
  }

  private async runVideoTranscode(save: SaveTarget): Promise<void> {
    const file = save.file;
    if (file === null) {
      throw new Error('无法写入保存位置');
    }
    const codec: media.CodecMimeType = this.convertVideoTarget === 'hevc' ?
      media.CodecMimeType.VIDEO_HEVC : media.CodecMimeType.VIDEO_AVC;
    const config: media.AVTranscoderConfig = {
      fileFormat: media.ContainerFormatType.CFT_MPEG_4,
      videoCodec: codec,
      videoBitrate: this.convertVideoBitrate()
    };
    if (this.convertAudioCodec.length > 0) {
      config.audioCodec = media.CodecMimeType.AUDIO_AAC;
      config.audioBitrate = 192000;
    }
    this.logInfo('转换', '视频参数：' + this.convertVideoTarget.toUpperCase() + '，' +
      (this.convertVideoBitrate() / 1000000).toFixed(1) + ' Mbps，输出 MP4');
    const transcoder: media.AVTranscoder = await media.createAVTranscoder();
    this.transcoder = transcoder;
    try {
      fileIo.truncateSync(file.fd, 0);
    } catch (e) {
      this.logWarn('转换', '清空目标文件失败，继续写入：' + errorText(e as Object));
    }
    const src: media.AVFileDescriptor = {
      fd: this.convertFd,
      offset: 0,
      length: this.convertSize
    };
    transcoder.fdSrc = src;
    transcoder.fdDst = file.fd;

    try {
      await new Promise<void>((resolve, reject) => {
        this.transcodeReject = reject;
        transcoder.on('progressUpdate', (percent: number) => {
          this.convertProgressPercent = Math.max(0, Math.min(99, percent));
          this.convertElapsedMs = Date.now() - this.convertStartedAt;
        });
        transcoder.on('complete', () => {
          this.transcodeReject = null;
          this.convertProgressPercent = 100;
          resolve();
        });
        transcoder.on('error', (err: BusinessError) => {
          this.transcodeReject = null;
          reject(new Error('视频转码失败（' + err.code.toString() + '）：' + err.message));
        });
        transcoder.prepare(config).then(() => {
          return transcoder.start();
        }).catch((err: Object) => {
          this.transcodeReject = null;
          reject(new Error(errorText(err)));
        });
      });
    } finally {
      this.transcoder = null;
      this.transcodeReject = null;
      if (this.transcodeCancelTimer >= 0) {
        clearTimeout(this.transcodeCancelTimer);
        this.transcodeCancelTimer = -1;
      }
      try {
        await transcoder.release();
      } catch (e) {
        this.logWarn('转换', '释放转码器失败：' + errorText(e as Object));
      }
    }
  }

  private convertStartedAt: number = 0;

  private convertVideoBitrate(): number {
    const height: number = this.convertHeight;
    if (height <= 0) {
      return 8000000;
    }
    if (height <= 480) {
      return 3000000;
    }
    if (height <= 720) {
      return 6000000;
    }
    if (height <= 1080) {
      return 12000000;
    }
    return 24000000;
  }

  private cancelConversion(): void {
    if (this.convertPhase !== 'working' || this.convertCancelling) {
      return;
    }
    this.convertCancelling = true;
    this.logInfo('转换', '用户取消转换');
    if (this.convertMode === 'audio') {
      MediaService.cancel();
      return;
    }
    if (this.transcoder === null) {
      return;
    }
    this.transcoder.cancel().catch((e: Object) => {
      this.logWarn('转换', '取消视频转码失败：' + errorText(e));
    });
    if (this.transcodeCancelTimer >= 0) {
      clearTimeout(this.transcodeCancelTimer);
    }
    this.transcodeCancelTimer = setTimeout(() => {
      this.transcodeCancelTimer = -1;
      if (this.transcodeReject !== null) {
        const reject: (error: Error) => void = this.transcodeReject;
        this.transcodeReject = null;
        reject(new Error('已取消转换'));
      }
    }, 1200);
  }

  private startConvertPolling(): void {
    this.stopConvertPolling();
    this.convertTimer = setInterval(() => {
      try {
        const progress: ExtractProgress = MediaService.progress();
        if (!progress.running && progress.state !== 'extracting') {
          return;
        }
        this.convertProgressPercent = Math.max(0, Math.min(100, progress.percent));
        this.convertOutputBytes = progress.bytes;
        this.convertElapsedMs = progress.elapsedMs;
      } catch (e) {
        // Keep the last visible progress if a transient read fails.
      }
    }, 150);
  }

  private stopConvertPolling(): void {
    if (this.convertTimer >= 0) {
      clearInterval(this.convertTimer);
      this.convertTimer = -1;
    }
  }

  private async addConvertHistory(uri: string): Promise<void> {
    const item: HistoryItem = new HistoryItem();
    item.id = Date.now().toString() + '-' + Math.floor(Math.random() * 1000).toString();
    item.name = this.convertOutputName.length > 0 ? this.convertOutputName : '转换结果';
    item.sourceName = this.convertName;
    item.size = this.convertOutputBytes;
    item.durationUs = this.convertDurationUs;
    item.codec = this.convertMode === 'audio' ? this.convertAudioCodec : this.convertVideoCodec;
    item.format = this.convertMode === 'audio' ? this.convertTargetFormat : 'mp4';
    item.savedAt = Date.now();
    item.outputUri = uri;
    const next: HistoryItem[] = [item];
    for (let i = 0; i < this.history.length && i < 29; i++) {
      next.push(this.history[i]);
    }
    this.history = next;
    await HistoryStore.save(this.ctx(), this.history);
  }

  private failConvert(message: string): void {
    this.stopConvertPolling();
    this.convertPhase = 'error';
    this.convertError = message.length > 0 ? message : '转换失败';
    this.convertCancelling = false;
    this.logError('转换', this.convertError);
    promptAction.showToast({ message: this.convertError });
  }

  private resetConvert(keepChoice: boolean): void {
    if (this.convertPhase === 'working') {
      return;
    }
    this.closeConvertInput();
    this.closeConvertTarget();
    this.stopConvertPolling();
    this.convertPhase = 'idle';
    this.convertError = '';
    this.convertOutputName = '';
    this.convertOutputUri = '';
    this.convertOutputBytes = 0;
    this.convertElapsedMs = 0;
    this.convertProgressPercent = 0;
    this.convertDurationUs = 0;
    this.convertAudioCodec = '';
    this.convertSampleRate = 0;
    this.convertAudioChannels = 0;
    this.convertVideoCodec = '';
    this.convertWidth = 0;
    this.convertHeight = 0;
    this.convertStartedAt = 0;
    if (!keepChoice) {
      this.convertTargetFormat = 'mp3';
      this.convertVideoTarget = 'avc';
    }
  }

  private closeConvertInput(): void {
    if (this.convertPicked !== null) {
      FileService.closeFile(this.convertPicked.file);
      this.convertPicked = null;
    }
    this.convertFd = -1;
    this.convertUri = '';
    this.convertName = '';
    this.convertSize = 0;
  }

  private closeConvertTarget(): void {
    if (this.convertTarget !== null) {
      FileService.closeFile(this.convertTarget.file);
      this.convertTarget = null;
    }
  }

  private moveConvertToBackground(): void {
    this.logInfo('转换', '返回键离开，转换转入后台');
    promptAction.showToast({ message: '转换转入后台继续' });
    this.ctx().moveAbilityToBackground().catch((e: Error) => {
      this.logWarn('转换', '自动转后台失败：' + e.message);
      promptAction.showToast({ message: '无法自动转后台，请按 Home 键' });
    });
  }

  private selectConvertFormat(format: string): void {
    if (this.convertPhase === 'working' || this.convertPhase === 'analyzing') {
      return;
    }
    this.convertTargetFormat = format;
    this.logInfo('转换', '音频输出格式设为 ' + format.toUpperCase());
  }

  private selectConvertVideoCodec(codec: string): void {
    if (this.convertPhase === 'working' || this.convertPhase === 'analyzing') {
      return;
    }
    this.convertVideoTarget = codec;
    this.logInfo('转换', '视频输出编码设为 ' + codec.toUpperCase());
  }

  private canConvertAudioOutput(): boolean {
    return this.convertTargetFormat !== 'ogg' ||
      this.convertAudioCodec === 'Opus' || this.convertAudioCodec === 'Vorbis';
  }

  private convertAudioNote(): string {
    const source: string = this.convertAudioCodec.toUpperCase();
    const target: string = this.convertTargetFormat.toUpperCase();
    if ((source === 'MP3' && target === 'MP3') || (source === 'FLAC' && target === 'FLAC') ||
      (target === 'OGG' && (source === 'OPUS' || source === 'VORBIS'))) {
      return '源编码与目标一致，直接封装，速度接近硬盘读写。';
    }
    if (target === 'OGG') {
      return '系统没有 Vorbis/Opus 编码器：只有源本身是 OGG/Opus/Vorbis 时才能无损转封装为 OGG，MP3/AAC 等源无法生成 OGG。';
    }
    if (target === 'FLAC') {
      return '将在本机解码后重编码为 FLAC 16-bit；有损源不会恢复已丢失的细节。';
    }
    if (target === 'WAV') {
      return '将在本机解码为 16-bit PCM WAV；兼容性最好，但体积很大。';
    }
    if (target === 'AAC') {
      return '将在本机解码后重编码为 AAC 192kbps，适合手机和苹果设备。';
    }
    if (target === 'AIFF') {
      return '将在本机解码为 16-bit PCM AIFF，适合专业音频软件。';
    }
    return '将在本机解码后重编码为 MP3 320kbps，适合分享和车载播放。';
  }

  private convertVideoNote(): string {
    const bitrate: number = this.convertVideoBitrate();
    return '输出 MP4 · ' + (this.convertVideoTarget === 'hevc' ? 'H.265' : 'H.264') +
      ' · ' + (bitrate / 1000000).toFixed(1) + ' Mbps · AAC 192kbps';
  }

  private convertBarWidth(): string {
    const value: number = Math.max(0, Math.min(100, this.convertProgressPercent));
    return value.toFixed(1) + '%';
  }

  private convertPercentText(): string {
    if (this.convertPhase === 'working' && this.convertProgressPercent <= 0) {
      return '处理中';
    }
    return Math.max(0, Math.min(100, this.convertProgressPercent)).toFixed(1) + '%';
  }

  /* ------------------------------------------------------------------ */
  /* Progress                                                           */
  /* ------------------------------------------------------------------ */

  private startPolling(): void {
    this.stopPolling();
    this.timer = setInterval(() => {
      try {
        const progress: ExtractProgress = MediaService.progress();
        if (!progress.running && progress.state !== 'extracting') {
          // Keep the last values visible until the promise settles; the
          // promise handler is the single source of truth for the phase.
          return;
        }
        this.progressPercent = progress.percent < 0 ? 0 : Math.min(100, progress.percent);
        this.processedUs = progress.processedUs;
        this.totalUs = progress.totalUs;
        this.speedBps = progress.speedBps;
        this.processedBytes = progress.bytes;
        this.elapsedMs = progress.elapsedMs;
      } catch (e) {
        // A transient read failure must not end an extraction.
      }
    }, 120);
  }

  private stopPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private etaUs(): number {
    if (this.progressPercent <= 1 || this.elapsedMs <= 0) {
      return 0;
    }
    if (this.progressPercent >= 100) {
      return 0;
    }
    const remainingRatio: number = (100 - this.progressPercent) / this.progressPercent;
    return (this.elapsedMs * 1000) * remainingRatio;
  }

  private percentText(): string {
    if (this.totalUs <= 0 && this.progressPercent <= 0) {
      return '处理中';
    }
    if (this.progressPercent >= 100) {
      return '100%';
    }
    return this.progressPercent.toFixed(1) + '%';
  }

  private progressBarWidth(): string {
    const value: number = Math.max(0, Math.min(100, this.progressPercent));
    return value.toFixed(1) + '%';
  }

  private elapsedText(ms: number): string {
    if (ms < 1000) {
      return ms.toString() + ' ms';
    }
    return (ms / 1000).toFixed(1) + ' 秒';
  }

  private selectDock(index: number): void {
    animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
      this.dockIndex = index;
    });
    if (index === 2 && !this.historyLoaded) {
      this.loadHistory();
    }
    if (index === 3) {
      this.refreshLogs();
    }
  }

  /* ------------------------------------------------------------------ */
  /* UI                                                                 */
  /* ------------------------------------------------------------------ */

  @Builder
  RippleLayer() {
    Canvas(this.rippleCtx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.drawRipples();
      })
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.canvasWidth = newValue.width as number;
        this.canvasHeight = newValue.height as number;
        this.drawRipples();
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  BackgroundLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($r('app.media.bg_sakura'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            ['#A6FFF9FC', 0.0],
            ['#33FFF9FC', 0.38],
            ['#59FFF9FC', 0.72],
            ['#D9FFF9FC', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
      this.RippleLayer()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Header() {
    Row() {
      Image($r('app.media.brand_mark'))
        .width(48)
        .height(48)
        .borderRadius(15)
        .shadow({ radius: 14, color: '#33D95B88', offsetX: 0, offsetY: 6 })
      Column({ space: 3 }) {
        Text('Ruinsss格式快转')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_INK)
        Row({ space: 6 }) {
          Text('AUDIO EXTRACTOR')
            .fontSize(8)
            .letterSpacing(1.1)
            .fontColor(COLOR_FAINT)
          Text('V1.0.1')
            .fontSize(9)
            .fontColor(COLOR_PINK_DARK)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#80FFFFFF')
            .borderRadius(7)
            .border({ width: 1, color: COLOR_LINE })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 11 })
      Column({ space: 2 }) {
        Text('DESIGNED BY')
          .fontSize(7)
          .letterSpacing(0.8)
          .fontColor(COLOR_FAINT)
        Text('Ruinsss')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_SUB)
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 12, bottom: 8 })
  }

  @Builder
  MiniChip(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor(COLOR_SUB)
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor(COLOR_GLASS)
      .borderRadius(9)
      .border({ width: 1, color: COLOR_LINE })
  }

  @Builder
  InfoChip(label: string, background: string, foreground: string) {
    Text(label)
      .fontSize(10)
      .fontColor(foreground)
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .backgroundColor(background)
      .borderRadius(8)
  }

  @Builder
  Hero() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Row()
          .width(18)
          .height(1.5)
          .backgroundColor(COLOR_PINK)
          .borderRadius(1)
        Text('VIDEO  →  AUDIO')
          .fontSize(9)
          .letterSpacing(1.5)
          .fontColor(COLOR_PINK_DARK)
      }
      .margin({ top: 4 })
      Text('把视频里的声音，\n干净地留下来。')
        .fontSize(30)
        .lineHeight(40)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text('优先原音轨直提；需要时在设备内转为 MP3 / FLAC。\n大文件也能从容处理。')
        .fontSize(12)
        .lineHeight(21)
        .fontColor(COLOR_SUB)
      Row({ space: 7 }) {
        this.MiniChip('⚡ 极速直提')
        this.MiniChip('♪ 原音质')
        this.MiniChip('⌂ 纯本地')
      }
      .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 4 })
  }

  @Builder
  PickerCard() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(100)
          .height(100)
          .backgroundColor('#1FF27EA8')
          .borderRadius(50)
        Circle()
          .width(82)
          .height(82)
          .backgroundColor('#66FFFFFF')
          .borderRadius(41)
        Image($r('app.media.app_icon'))
          .width(76)
          .height(76)
          .borderRadius(38)
          .objectFit(ImageFit.Cover)
          .clip(true)
          .backgroundColor(Color.White)
          .shadow({ radius: 16, color: '#33C77799', offsetX: 0, offsetY: 8 })
      }
      .height(108)
      Text('选择一个视频')
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_INK)
        .margin({ top: 8 })
      Text('MP4 · MKV · MOV · AVI · TS · FLV')
        .fontSize(10)
        .fontColor(COLOR_FAINT)
        .margin({ top: 6 })
      Row({ space: 7 }) {
        Text('浏览本地文件')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
        Text('›')
          .fontSize(18)
          .fontColor(Color.White)
      }
      .padding({ left: 20, right: 17, top: 10, bottom: 10 })
      .backgroundColor(COLOR_PINK)
      .borderRadius(17)
      .margin({ top: 17 })
      .shadow({ radius: 14, color: '#40D95B88', offsetX: 0, offsetY: 7 })
      Text('不限文件大小 · 10GB 也轻松')
        .fontSize(9)
        .fontColor(COLOR_FAINT)
        .margin({ top: 13 })
    }
    .width('100%')
    .padding({ top: 18, bottom: 18, left: 18, right: 18 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .linearGradient({
      angle: 145,
      colors: [['#E6FFFFFF', 0.0], ['#B8FFF0F6', 1.0]]
    })
    .shadow(SHADOW_CARD)
    .onClick(() => {
      this.pickVideo();
    })
  }

  @Builder
  PrivacyNote() {
    Row({ space: 7 }) {
      Text('●')
        .fontSize(7)
        .fontColor(COLOR_MINT)
      Text('所有处理都在本机完成，视频不会离开你的设备')
        .fontSize(10)
        .fontColor(COLOR_FAINT)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 2 })
  }

  @Builder
  AnalyzingCard() {
    Column({ space: 13 }) {
      LoadingProgress()
        .width(50)
        .height(50)
        .color(COLOR_PINK)
      Text('正在读取视频…')
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_INK)
      Text(this.inputName)
        .fontSize(11)
        .fontColor(COLOR_SUB)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
      Text('正在识别音轨、编码与时长')
        .fontSize(10)
        .fontColor(COLOR_FAINT)
    }
    .width('100%')
    .padding({ top: 34, bottom: 32, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  FileCard() {
    Column({ space: 12 }) {
      Row() {
        Image($r('app.media.app_icon'))
          .width(46)
          .height(46)
          .borderRadius(23)
          .objectFit(ImageFit.Cover)
          .clip(true)
          .backgroundColor(Color.White)
        Column({ space: 4 }) {
          Text(this.inputName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 5 }) {
            Text(formatBytes(this.inputSize))
              .fontSize(10)
              .fontColor(COLOR_SUB)
            Text('·')
              .fontSize(10)
              .fontColor(COLOR_FAINT)
            Text(formatDuration(this.durationUs))
              .fontSize(10)
              .fontColor(COLOR_SUB)
            if (this.videoWidth > 0) {
              Text('·')
                .fontSize(10)
                .fontColor(COLOR_FAINT)
              Text(resolutionText(this.videoWidth, this.videoHeight))
                .fontSize(10)
                .fontColor(COLOR_SUB)
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 11 })
        Text('更换')
          .fontSize(10)
          .fontColor(COLOR_PINK_DARK)
          .padding({ left: 8, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.pickVideo();
          })
      }
      Divider()
        .strokeWidth(0.5)
        .color('#26D95B88')
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.videoCodec.length > 0) {
          this.InfoChip(this.videoCodec, '#14F27EA8', COLOR_PINK_DARK)
        }
        if (this.audioCodec.length > 0) {
          this.InfoChip(this.audioCodec, '#145FC7AD', '#2E917B')
        }
        this.InfoChip('本地视频', '#10000000', COLOR_SUB)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
    .shadow({ radius: 20, color: '#14A56A8A', offsetX: 0, offsetY: 9 })
  }

  @Builder
  Metric(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(9)
        .fontColor(COLOR_FAINT)
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_INK)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  AudioInfoCard() {
    Column({ space: 13 }) {
      Row() {
        Text('音频信息')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Blank()
        Text(this.isDirect() ? '无损直提' : '解码转码')
          .fontSize(9)
          .fontColor(this.isDirect() ? '#2E917B' : COLOR_PINK_DARK)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.isDirect() ? COLOR_MINT_SOFT : COLOR_PINK_SOFT)
          .borderRadius(7)
      }
      Row({ space: 6 }) {
        this.Metric('编码', this.audioCodec)
        this.Metric('采样率', sampleRateText(this.sampleRate))
        this.Metric('声道', channelText(this.channels))
      }
      Row({ space: 6 }) {
        this.Metric('码率', bitrateText(this.bitrate))
        this.Metric('时长', formatDuration(this.durationUs))
        this.Metric('输出', this.targetFormat.toUpperCase())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#8CFFFFFF')
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
  }

  @Builder
  FormatOption(value: string, title: string, note: string) {
    Column({ space: 3 }) {
      Row({ space: 5 }) {
        Text(this.targetFormat === value ? '●' : '○')
          .fontSize(9)
          .fontColor(this.targetFormat === value ? COLOR_PINK_DARK : COLOR_BLUE)
        Text(title)
          .fontSize(14)
          .fontWeight(this.targetFormat === value ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(COLOR_PINK_DARK)
      }
      Text(note)
        .fontSize(9)
        .fontColor(COLOR_PINK_DARK)
        .opacity(0.72)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.targetFormat === value ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
    .borderRadius(16)
    .border({
      width: this.targetFormat === value ? 1.6 : 1,
      color: this.targetFormat === value ? COLOR_BLUE : '#805B9BFF'
    })
    .onClick(() => {
      this.selectFormat(value);
    })
  }

  @Builder
  FormatPicker() {
    Column({ space: 10 }) {
      Row() {
        Text('输出格式')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Blank()
        Text(this.formatBadge())
          .fontSize(9)
          .fontColor(this.isDirect() ? '#2E917B' : COLOR_PINK_DARK)
      }
      Row({ space: 10 }) {
        this.FormatOption('mp3', 'MP3', '通用 · 320kbps')
        this.FormatOption('flac', 'FLAC', '无损 · 体积较大')
        this.FormatOption('ogg', 'OGG', '同源 · 无损')
      }
      Row({ space: 10 }) {
        this.FormatOption('wav', 'WAV', 'PCM · 兼容')
        this.FormatOption('aac', 'AAC', '192kbps · 手机')
        this.FormatOption('aiff', 'AIFF', 'PCM · 专业')
      }
      Text(this.targetNote())
        .fontSize(9)
        .lineHeight(14)
        .fontColor(COLOR_FAINT)
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#8CFFFFFF')
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
  }

  @Builder
  ExtractReady() {
    Column({ space: 14 }) {
      this.FileCard()
      Button('取消当前选择')
        .width('100%')
        .height(36)
        .borderRadius(12)
        .fontSize(10)
        .fontColor(COLOR_PINK_DARK)
        .backgroundColor('#12F27EA8')
        .onClick(() => {
          this.resetAll();
          promptAction.showToast({ message: '已取消选择，可重新选视频' });
        })
      this.AudioInfoCard()
      this.FormatPicker()
      if (!this.canExtract) {
        Row({ space: 10 }) {
          Text('!')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_ERROR)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor('#1AD9536E')
            .borderRadius(13)
          Column({ space: 3 }) {
            Text('这个音轨暂时不能直接封装')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_ERROR)
            Text(this.unsupportedReason.length > 0 ? this.unsupportedReason :
              '当前编码不在 V1.0 支持范围内')
              .fontSize(10)
              .lineHeight(16)
              .fontColor('#9E6373')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(13)
        .backgroundColor(COLOR_ERROR_SOFT)
        .borderRadius(16)
        .border({ width: 1, color: '#33D9536E' })
      }
      Button('提取并保存为 ' + this.targetFormat.toUpperCase())
        .width('100%')
        .height(54)
        .borderRadius(19)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.canStartExtract() ? COLOR_PINK : '#D9C9D1')
        .enabled(this.canStartExtract())
        .shadow(this.canStartExtract() ?
          { radius: 18, color: '#4DD95B88', offsetX: 0, offsetY: 8 } :
          { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
        .onClick(() => {
          this.startExtract();
        })
      Text(this.canStartExtract() ?
        (this.isDirect() ? '原音轨直接封装，速度接近硬盘读写' : this.targetNote()) :
        (this.targetFormat === 'ogg' ? '当前源不是 OGG/Opus/Vorbis，无法生成 OGG' : '当前音轨暂不支持，换一个视频试试'))
        .fontSize(9)
        .lineHeight(15)
        .fontColor(COLOR_FAINT)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
  }

  @Builder
  ProgressCard() {
    Column({ space: 17 }) {
      Row() {
        Column({ space: 4 }) {
          Text(this.cancelling ? '正在取消…' : (this.isDirect() ? '无损提取中' : '转码处理中'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
          Text(this.outputName)
            .fontSize(10)
            .fontColor(COLOR_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.percentText())
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_PINK_DARK)
      }
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(10)
          .borderRadius(5)
          .backgroundColor('#1AF27EA8')
        Row()
          .width(this.progressBarWidth())
          .height(10)
          .borderRadius(5)
          .linearGradient({
            angle: 90,
            colors: [[COLOR_PINK, 0.0], [COLOR_PINK_DARK, 1.0]]
          })
          .animation({ duration: 180, curve: Curve.EaseOut })
      }
      .width('100%')
      .height(10)
      .clip(true)
      Row({ space: 6 }) {
        this.Metric('已处理', formatDuration(this.processedUs))
        this.Metric('写入速度', formatSpeed(this.speedBps))
        this.Metric('预计剩余', formatEta(this.etaUs()))
      }
      Row() {
        Text('已写入 ' + formatBytes(this.processedBytes))
          .fontSize(9)
          .fontColor(COLOR_FAINT)
        Blank()
        Text('已用时 ' + this.elapsedText(this.elapsedMs))
          .fontSize(9)
          .fontColor(COLOR_FAINT)
      }
      .width('100%')
      Text(this.backgroundActive ?
        '后台运行已开启 · 可切换页签，或按 Home / 返回键离开' :
        '可切换页签 · 提取期间请尽量保持应用在前台')
        .fontSize(9)
        .fontColor(COLOR_MINT)
        .textAlign(TextAlign.Center)
      Button(this.cancelling ? '正在取消…' : '取消提取')
        .width('100%')
        .height(44)
        .borderRadius(16)
        .fontSize(12)
        .fontColor(COLOR_PINK_DARK)
        .backgroundColor('#00FFFFFF')
        .border({ width: 1, color: '#66D95B88' })
        .enabled(!this.cancelling)
        .onClick(() => {
          this.cancelExtract();
        })
    }
    .width('100%')
    .padding({ top: 22, bottom: 20, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  SuccessCard() {
    Column({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(76)
          .height(76)
          .backgroundColor(COLOR_MINT_SOFT)
          .borderRadius(38)
        Text('✓')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_MINT)
      }
      Text('提取完成')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text(this.outputName)
        .fontSize(12)
        .fontColor(COLOR_SUB)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        this.InfoChip(this.targetFormat.toUpperCase(), '#1F5B9BFF', COLOR_PINK_DARK)
        this.InfoChip(formatBytes(this.outputBytes), '#145FC7AD', '#2E917B')
        this.InfoChip(this.elapsedText(this.outputElapsedMs), '#10000000', COLOR_SUB)
      }
      Divider()
        .strokeWidth(0.5)
        .color('#26D95B88')
      Text('已保存到你选择的位置')
        .fontSize(9)
        .fontColor(COLOR_FAINT)
      Button('继续提取')
        .width('100%')
        .height(50)
        .borderRadius(18)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(COLOR_PINK)
        .shadow({ radius: 16, color: '#40D95B88', offsetX: 0, offsetY: 7 })
        .onClick(() => {
          this.resetAll();
        })
      Text('查看记录')
        .fontSize(11)
        .fontColor(COLOR_PINK_DARK)
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          this.resetAll();
          this.selectDock(2);
        })
    }
    .width('100%')
    .padding({ top: 24, bottom: 18, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ErrorCard() {
    Column({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(70)
          .height(70)
          .backgroundColor(COLOR_ERROR_SOFT)
          .borderRadius(35)
        Text('!')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_ERROR)
      }
      Text('出了点小问题')
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text(this.errorMsg)
        .fontSize(11)
        .lineHeight(18)
        .fontColor(COLOR_SUB)
        .textAlign(TextAlign.Center)
      Row({ space: 10 }) {
        Button('重新选择')
          .layoutWeight(1)
          .height(48)
          .borderRadius(16)
          .fontSize(12)
          .fontColor(COLOR_SUB)
          .backgroundColor('#80FFFFFF')
          .border({ width: 1, color: COLOR_LINE })
          .onClick(() => {
            this.resetAll();
            this.pickVideo();
          })
        Button('重试')
          .layoutWeight(1)
          .height(48)
          .borderRadius(16)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(COLOR_PINK)
          .onClick(() => {
            this.retry();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 26, bottom: 20, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ConvertModeButton(mode: string, title: string, note: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(this.convertMode === mode ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.convertMode === mode ? Color.White : COLOR_INK)
      Text(note)
        .fontSize(8)
        .fontColor(this.convertMode === mode ? '#E6FFFFFF' : COLOR_FAINT)
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.convertMode === mode ? COLOR_PINK : '#73FFFFFF')
    .borderRadius(18)
    .border({ width: 1, color: this.convertMode === mode ? '#00FFFFFF' : COLOR_LINE })
    .onClick(() => {
      this.selectConvertMode(mode);
    })
  }

  @Builder
  ConvertEmptyCard() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(74)
          .height(74)
          .backgroundColor(this.convertMode === 'audio' ? '#26F27EA8' : '#265FC7AD')
          .borderRadius(37)
        if (this.convertMode === 'audio') {
          Text('♫')
            .fontSize(29)
            .fontColor(COLOR_PINK)
        } else {
          Image($r('app.media.app_icon'))
            .width(54)
            .height(54)
            .borderRadius(27)
            .objectFit(ImageFit.Cover)
            .clip(true)
            .backgroundColor(Color.White)
        }
      }
      Text(this.convertMode === 'audio' ? '选择一段音频' : '选择一段视频')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text(this.convertMode === 'audio' ?
        'MP3 / FLAC / M4A / AAC / OGG 都可以。' :
        'MP4 / MKV / MOV / AVI / TS 等常见视频都可以。')
        .fontSize(10)
        .lineHeight(17)
        .fontColor(COLOR_SUB)
        .textAlign(TextAlign.Center)
      Button(this.convertMode === 'audio' ? '选择音频文件' : '选择视频文件')
        .width('78%')
        .height(44)
        .borderRadius(15)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.convertMode === 'audio' ? COLOR_PINK : COLOR_MINT)
        .shadow({ radius: 14, color: '#33D95B88', offsetX: 0, offsetY: 6 })
        .onClick(() => {
          this.pickConvert();
        })
    }
    .width('100%')
    .padding({ top: 28, bottom: 24, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ConvertFileCard() {
    Column({ space: 11 }) {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(48)
            .height(48)
            .backgroundColor(this.convertMode === 'audio' ? '#26F27EA8' : '#265FC7AD')
            .borderRadius(24)
          if (this.convertMode === 'audio') {
            Text('♫')
              .fontSize(20)
              .fontColor(COLOR_PINK)
          } else {
            Image($r('app.media.app_icon'))
              .width(38)
              .height(38)
              .borderRadius(19)
              .objectFit(ImageFit.Cover)
              .clip(true)
              .backgroundColor(Color.White)
          }
        }
        Column({ space: 5 }) {
          Text(this.convertName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(formatBytes(this.convertSize) + ' · ' + formatDuration(this.convertDurationUs) +
            ' · ' + this.convertSummary())
            .fontSize(9)
            .fontColor(COLOR_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 11 })
        Text(this.convertPhase === 'ready' ? '就绪' :
          (this.convertPhase === 'working' ? '处理中' :
            (this.convertPhase === 'success' ? '已完成' : '待处理')))
          .fontSize(9)
          .fontColor(this.convertPhase === 'working' ? COLOR_PINK : COLOR_MINT)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.convertPhase === 'working' ? '#1FF27EA8' : '#1F5FC7AD')
          .borderRadius(9)
      }
      .width('100%')
      if (this.convertPhase !== 'working') {
        Row({ space: 8 }) {
          Button('更换文件')
            .layoutWeight(1)
            .height(38)
            .borderRadius(13)
            .fontSize(10)
            .fontColor(COLOR_SUB)
            .backgroundColor('#73FFFFFF')
            .border({ width: 1, color: COLOR_LINE })
            .onClick(() => {
              this.pickConvert();
            })
          Button('取消选择')
            .layoutWeight(1)
            .height(38)
            .borderRadius(13)
            .fontSize(10)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor('#1FF27EA8')
            .onClick(() => {
              this.resetConvert(true);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(COLOR_CARD)
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
    .shadow({ radius: 18, color: '#10A56A8A', offsetX: 0, offsetY: 8 })
  }

  @Builder
  ConvertOptionsCard() {
    Column({ space: 12 }) {
      Row() {
        Text(this.convertMode === 'audio' ? '输出格式' : '输出编码')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Blank()
        Text(this.convertMode === 'audio' ? '本机编码' : '硬件转码')
          .fontSize(8)
          .fontColor(COLOR_MINT)
      }
      .width('100%')
      if (this.convertMode === 'audio') {
        Row({ space: 9 }) {
          Text('MP3')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'mp3' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'mp3' ? 1.6 : 1, color: this.convertTargetFormat === 'mp3' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('mp3');
            })
          Text('FLAC')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'flac' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'flac' ? 1.6 : 1, color: this.convertTargetFormat === 'flac' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('flac');
            })
          Text('OGG')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'ogg' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'ogg' ? 1.6 : 1, color: this.convertTargetFormat === 'ogg' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('ogg');
            })
        }
        .width('100%')
        Row({ space: 9 }) {
          Text('WAV')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'wav' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'wav' ? 1.6 : 1, color: this.convertTargetFormat === 'wav' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('wav');
            })
          Text('AAC')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'aac' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'aac' ? 1.6 : 1, color: this.convertTargetFormat === 'aac' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('aac');
            })
          Text('AIFF')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(this.convertTargetFormat === 'aiff' ? COLOR_BLUE_STRONG : COLOR_BLUE_SOFT)
            .borderRadius(14)
            .border({ width: this.convertTargetFormat === 'aiff' ? 1.6 : 1, color: this.convertTargetFormat === 'aiff' ? COLOR_BLUE : '#805B9BFF' })
            .onClick(() => {
              this.selectConvertFormat('aiff');
            })
        }
        .width('100%')
        Text(this.convertAudioNote())
          .fontSize(9)
          .lineHeight(16)
          .fontColor(COLOR_SUB)
      } else {
        Row({ space: 9 }) {
          Text('H.264')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.convertVideoTarget === 'avc' ? Color.White : COLOR_INK)
            .backgroundColor(this.convertVideoTarget === 'avc' ? COLOR_MINT : '#73FFFFFF')
            .borderRadius(14)
            .border({ width: 1, color: this.convertVideoTarget === 'avc' ? '#00FFFFFF' : COLOR_LINE })
            .onClick(() => {
              this.selectConvertVideoCodec('avc');
            })
          Text('H.265')
            .layoutWeight(1)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.convertVideoTarget === 'hevc' ? Color.White : COLOR_INK)
            .backgroundColor(this.convertVideoTarget === 'hevc' ? COLOR_MINT : '#73FFFFFF')
            .borderRadius(14)
            .border({ width: 1, color: this.convertVideoTarget === 'hevc' ? '#00FFFFFF' : COLOR_LINE })
            .onClick(() => {
              this.selectConvertVideoCodec('hevc');
            })
        }
        .width('100%')
        Text(this.convertVideoNote())
          .fontSize(9)
          .lineHeight(16)
          .fontColor(COLOR_SUB)
      }
    }
    .width('100%')
    .padding(15)
    .backgroundColor(COLOR_CARD)
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
  }

  @Builder
  ConvertStartButton() {
    Button(this.convertMode === 'audio' ?
      ('开始转换并保存为 ' + this.convertTargetFormat.toUpperCase()) : '开始视频转码并保存 MP4')
      .width('100%')
      .height(54)
      .borderRadius(19)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .backgroundColor(this.convertMode === 'audio' && !this.canConvertAudioOutput() ?
        '#D9C9D1' : (this.convertMode === 'audio' ? COLOR_PINK : COLOR_MINT))
      .enabled(this.convertMode === 'video' || this.canConvertAudioOutput())
      .shadow({ radius: 18, color: '#40D95B88', offsetX: 0, offsetY: 8 })
      .onClick(() => {
        this.startConversion();
      })
  }

  @Builder
  ConvertProgressCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text(this.convertMode === 'audio' ? '音频处理中' : '视频转码中')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
          Text(this.convertMode === 'audio' ?
            ((this.convertAudioCodec.toUpperCase() === this.convertTargetFormat.toUpperCase() ||
              (this.convertTargetFormat === 'ogg' &&
                (this.convertAudioCodec === 'Opus' || this.convertAudioCodec === 'Vorbis'))) ?
              '直提原音轨，不做二次编码' : '解码 → 重编码，全程在本机完成') :
            '系统 AVTranscoder · 硬件加速')
            .fontSize(9)
            .fontColor(COLOR_SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.convertPercentText())
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.convertMode === 'audio' ? COLOR_PINK_DARK : COLOR_MINT)
      }
      .width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(9)
          .backgroundColor('#1F8D7684')
          .borderRadius(5)
        Row()
          .width(this.convertBarWidth())
          .height(9)
          .linearGradient({
            angle: 90,
            colors: [[this.convertMode === 'audio' ? '#F27EA8' : '#5FC7AD', 0.0],
              [this.convertMode === 'audio' ? '#D95B88' : '#3FAE94', 1.0]]
          })
          .borderRadius(5)
      }
      .width('100%')
      Row() {
        Column({ space: 3 }) {
          Text('已写入')
            .fontSize(8)
            .fontColor(COLOR_FAINT)
          Text(this.convertOutputBytes > 0 ? formatBytes(this.convertOutputBytes) : '--')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 3 }) {
          Text('已用时')
            .fontSize(8)
            .fontColor(COLOR_FAINT)
          Text(this.elapsedText(this.convertElapsedMs))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 3 }) {
          Text('输出')
            .fontSize(8)
            .fontColor(COLOR_FAINT)
          Text(this.convertMode === 'audio' ? this.convertTargetFormat.toUpperCase() : 'MP4')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      Text(this.convertBackgroundActive ?
        '后台任务已开启 · 可切换页签，或按 Home / 返回键离开' :
        '请保持应用在前台，避免系统暂停处理')
        .fontSize(9)
        .lineHeight(15)
        .fontColor(this.convertBackgroundActive ? COLOR_MINT : COLOR_SUB)
      Button(this.convertCancelling ? '正在取消…' : '取消转换')
        .width('100%')
        .height(42)
        .borderRadius(14)
        .fontSize(11)
        .fontColor(COLOR_ERROR)
        .backgroundColor(COLOR_ERROR_SOFT)
        .enabled(!this.convertCancelling)
        .onClick(() => {
          this.cancelConversion();
        })
    }
    .width('100%')
    .padding(18)
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ConvertSuccessCard() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(66)
          .height(66)
          .backgroundColor(COLOR_MINT_SOFT)
          .borderRadius(33)
        Text('✓')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_MINT)
      }
      Text('转换完成')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text(this.convertOutputName)
        .fontSize(11)
        .fontColor(COLOR_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(formatBytes(this.convertOutputBytes) + ' · ' + this.elapsedText(this.convertElapsedMs) +
        ' · ' + (this.convertMode === 'audio' ? this.convertTargetFormat.toUpperCase() : 'MP4'))
        .fontSize(9)
        .fontColor(COLOR_FAINT)
      Row({ space: 9 }) {
        Button('查看记录')
          .layoutWeight(1)
          .height(44)
          .borderRadius(14)
          .fontSize(11)
          .fontColor(COLOR_PINK_DARK)
          .backgroundColor('#1FF27EA8')
          .onClick(() => {
            this.selectDock(2);
          })
        Button('再转一个')
          .layoutWeight(1)
          .height(44)
          .borderRadius(14)
          .fontSize(11)
          .fontColor(COLOR_SUB)
          .backgroundColor('#73FFFFFF')
          .border({ width: 1, color: COLOR_LINE })
          .onClick(() => {
            this.resetConvert(true);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 24, bottom: 18, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ConvertErrorCard() {
    Column({ space: 12 }) {
      Text('转换没有完成')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_INK)
      Text(this.convertError)
        .fontSize(10)
        .lineHeight(17)
        .fontColor(COLOR_SUB)
        .textAlign(TextAlign.Center)
      Row({ space: 9 }) {
        Button('重新选择')
          .layoutWeight(1)
          .height(42)
          .borderRadius(14)
          .fontSize(10)
          .fontColor(COLOR_SUB)
          .backgroundColor('#73FFFFFF')
          .border({ width: 1, color: COLOR_LINE })
          .onClick(() => {
            this.resetConvert(true);
            this.pickConvert();
          })
        Button('再试一次')
          .layoutWeight(1)
          .height(42)
          .borderRadius(14)
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor(COLOR_PINK)
          .onClick(() => {
            this.startConversion();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 20, bottom: 16, left: 18, right: 18 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(22)
    .border({ width: 1, color: '#E6FFFFFF' })
  }

  @Builder
  ConvertTab() {
    Column({ space: 14 }) {
      Column({ space: 7 }) {
        Row() {
          Text('转换工作台')
            .fontSize(25)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_INK)
          Blank()
          Text('BETA 19')
            .fontSize(8)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_MINT)
            .padding({ left: 9, right: 9, top: 5, bottom: 5 })
            .backgroundColor('#1F5FC7AD')
            .borderRadius(10)
        }
        .width('100%')
        Text('音频换格式，视频换容器。\n同一套直提、转码和进度体验。')
          .fontSize(11)
          .lineHeight(19)
          .fontColor(COLOR_SUB)
      }
      .width('100%')
      .padding({ top: 4, bottom: 2 })

      Row({ space: 9 }) {
        this.ConvertModeButton('audio', '音频转音频', 'MP3 / FLAC')
        this.ConvertModeButton('video', '视频转视频', 'MP4 · H.264 / H.265')
      }
      .width('100%')

      if (this.convertPhase === 'idle') {
        this.ConvertEmptyCard()
      } else {
        this.ConvertFileCard()
      }

      if (this.convertPhase === 'analyzing') {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(COLOR_PINK)
          Text('正在读取媒体信息…')
            .fontSize(10)
            .fontColor(COLOR_SUB)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(COLOR_CARD)
        .borderRadius(18)
      } else if (this.convertPhase === 'ready') {
        this.ConvertOptionsCard()
        this.ConvertStartButton()
      } else if (this.convertPhase === 'working') {
        this.ConvertProgressCard()
      } else if (this.convertPhase === 'success') {
        this.ConvertSuccessCard()
      } else if (this.convertPhase === 'error') {
        this.ConvertErrorCard()
      }

      Text('所有处理都在本机完成，不上传文件；视频与音频均以文件描述符流式读写，支持 10GB+ 大文件。')
        .fontSize(9)
        .lineHeight(16)
        .fontColor(COLOR_FAINT)
        .padding({ left: 4, right: 4, top: 2 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 18 })
  }

  @Builder
  EmptyHistory() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(86)
          .height(86)
          .backgroundColor('#33FFFFFF')
          .borderRadius(43)
        Text('♪')
          .fontSize(34)
          .fontColor(COLOR_PINK)
      }
      Text('还没有提取记录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_INK)
      Text('提取成功的音频会出现在这里，\n记录只保存在本机。')
        .fontSize(10)
        .lineHeight(17)
        .fontColor(COLOR_FAINT)
        .textAlign(TextAlign.Center)
      Button('去提取一个视频')
        .margin({ top: 8 })
        .height(42)
        .borderRadius(15)
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor(COLOR_PINK)
        .onClick(() => {
          this.selectDock(0);
        })
    }
    .width('100%')
    .padding({ top: 46, bottom: 40, left: 20, right: 20 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1.5, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  HistoryRow(item: HistoryItem) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(42)
          .height(42)
          .backgroundColor(COLOR_BLUE_SOFT)
          .borderRadius(21)
        Text(historyFormat(item).toUpperCase().substring(0, 4))
          .fontSize(7)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_PINK_DARK)
      }
      Column({ space: 4 }) {
        Text(item.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 5 }) {
          Text(formatBytes(item.size))
            .fontSize(9)
            .fontColor(COLOR_SUB)
          Text('·')
            .fontSize(9)
            .fontColor(COLOR_FAINT)
          Text(formatDuration(item.durationUs))
            .fontSize(9)
            .fontColor(COLOR_SUB)
          Text('·')
            .fontSize(9)
            .fontColor(COLOR_FAINT)
          Text(item.codec.length > 0 ? '源 ' + item.codec : '源音轨')
            .fontSize(9)
            .fontColor(COLOR_SUB)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 11 })
      Column({ space: 3 }) {
        Text(formatClock(item.savedAt))
          .fontSize(8)
          .fontColor(COLOR_FAINT)
        Text('查看位置')
          .fontSize(8)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PINK_DARK)
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(13)
    .backgroundColor('#8CFFFFFF')
    .borderRadius(18)
    .border({ width: 1, color: COLOR_LINE })
    .onClick(() => {
      this.revealOutput(item);
    })
  }

  @Builder
  HistoryTab() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('提取记录')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_INK)
          Text('成功的提取会留在这里，方便回看')
            .fontSize(10)
            .fontColor(COLOR_SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.history.length > 0) {
          Text('清除')
            .fontSize(10)
            .fontColor(COLOR_PINK_DARK)
            .padding({ left: 10, right: 4, top: 8, bottom: 8 })
            .onClick(() => {
              this.clearHistory();
            })
        }
      }
      .width('100%')
      .padding({ top: 6, bottom: 2 })
      if (!this.historyLoaded) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(COLOR_PINK)
          Text('正在读取记录…')
            .fontSize(10)
            .fontColor(COLOR_FAINT)
        }
        .padding({ top: 30 })
      } else if (this.history.length === 0) {
        this.EmptyHistory()
      } else {
        ForEach(this.history, (item: HistoryItem) => {
          this.HistoryRow(item)
        }, (item: HistoryItem) => item.id)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AboutFeature(icon: string, title: string, detail: string) {
    Row({ space: 11 }) {
      Text(icon)
        .fontSize(14)
        .fontColor(COLOR_PINK_DARK)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor('#1FF27EA8')
        .borderRadius(11)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Text(detail)
          .fontSize(9)
          .lineHeight(15)
          .fontColor(COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  ChangelogCard() {
    Column({ space: 9 }) {
      Row() {
        Text('更新日志')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Blank()
        Text(this.changelogExpanded ? '收起' : '展开')
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PINK_DARK)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .backgroundColor(COLOR_BLUE_SOFT)
          .borderRadius(8)
          .margin({ right: 7 })
          .onClick(() => {
            this.changelogExpanded = !this.changelogExpanded;
          })
        Text('BETA 19')
          .fontSize(8)
          .fontColor(COLOR_PINK_DARK)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(COLOR_PINK_SOFT)
          .borderRadius(7)
      }
      .width('100%')
      Text('按每次需求推进一个 Beta，记录从初版到当前的全部改动。')
        .fontSize(9)
        .lineHeight(15)
        .fontColor(COLOR_FAINT)
      if (this.changelogExpanded) {
        ForEach(this.changelog, (item: ChangelogItem) => {
          Column({ space: 4 }) {
            Row({ space: 7 }) {
              Text(item.version)
                .fontSize(8)
                .fontColor(COLOR_PINK_DARK)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#1FF27EA8')
                .borderRadius(6)
              Text(item.title)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLOR_INK)
            }
            .width('100%')
            Text(item.details.join('\n'))
              .fontSize(9)
              .lineHeight(15)
              .fontColor(COLOR_SUB)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 7, bottom: 7 })
          .border({ width: { bottom: 1 }, color: '#12A56A8A' })
        }, (item: ChangelogItem) => item.version)
      } else {
        Text('已收起 · 共 ' + this.changelog.length + ' 个版本')
          .fontSize(9)
          .fontColor(COLOR_FAINT)
          .padding({ top: 3, bottom: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(22)
    .border({ width: 1, color: COLOR_LINE })
  }

  @Builder
  AboutTab() {
    Column({ space: 14 }) {
      Column({ space: 9 }) {
        Image($r('app.media.app_icon'))
          .width(88)
          .height(88)
          .borderRadius(26)
          .shadow({ radius: 22, color: '#40C77799', offsetX: 0, offsetY: 10 })
        Text('Ruinsss格式快转')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_INK)
        Text('V1.0.1 · Beta 19')
          .fontSize(10)
          .fontColor(COLOR_PINK_DARK)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor('#80FFFFFF')
          .borderRadius(8)
          .border({ width: 1, color: COLOR_LINE })
        Text('把声音和画面，转成更顺手的格式。')
          .fontSize(10)
          .fontColor(COLOR_SUB)
        Text('by Ruinsss')
          .fontSize(10)
          .letterSpacing(0.6)
          .fontColor(COLOR_FAINT)
      }
      .width('100%')
      .padding({ top: 20, bottom: 18 })
      Row({ space: 12 }) {
        Image('https://github.com/Ruinsss233.png')
          .width(54)
          .height(54)
          .borderRadius(27)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.brand_mark'))
          .border({ width: 1, color: '#99FFFFFF' })
          .shadow({ radius: 14, color: '#33C77799', offsetX: 0, offsetY: 6 })
        Column({ space: 4 }) {
          Text('Ruinsss233')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_INK)
          Text('GitHub · 开源作者')
            .fontSize(9)
            .fontColor(COLOR_SUB)
          Text('github.com/Ruinsss233')
            .fontSize(8)
            .fontColor(COLOR_PINK_DARK)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('↗')
          .fontSize(18)
          .fontColor(COLOR_PINK_DARK)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor('#8CFFFFFF')
      .borderRadius(20)
      .border({ width: 1, color: COLOR_LINE })
      .onClick(() => {
        this.openGithub();
      })
      Column({ space: 10 }) {
        Row() {
          Text('开源地址')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
          Blank()
          Text('GITHUB')
            .fontSize(8)
            .fontColor('#2E917B')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(COLOR_MINT_SOFT)
            .borderRadius(7)
        }
        .width('100%')
        Text('github.com/Ruinsss233/RuinsssFormat')
          .fontSize(10)
          .fontColor(COLOR_PINK_DARK)
          .copyOption(CopyOptions.LocalDevice)
        Text('源码、构建脚本和版本记录都在这里；点击可直接打开仓库。')
          .fontSize(9)
          .lineHeight(16)
          .fontColor(COLOR_SUB)
        Row({ space: 10 }) {
          Button('打开仓库')
            .fontSize(10)
            .height(36)
            .borderRadius(13)
            .fontColor(Color.White)
            .backgroundColor(COLOR_PINK)
            .layoutWeight(1)
            .onClick(() => {
              this.openRepo();
            })
          Button('复制地址')
            .fontSize(10)
            .height(36)
            .borderRadius(13)
            .fontColor(COLOR_PINK_DARK)
            .backgroundColor(COLOR_PINK_SOFT)
            .layoutWeight(1)
            .onClick(() => {
              this.copyText(this.repoUrl, '开源地址');
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor('#8CFFFFFF')
      .borderRadius(20)
      .border({ width: 1, color: COLOR_LINE })
      Column({ space: 13 }) {
        Text('它擅长什么')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        this.AboutFeature('⚡', '提取 + 转换', '音频可直提或转成 MP3 / FLAC / WAV / AAC / AIFF；OGG 支持 Opus/Vorbis 源无损转封装。视频可重新封装成 MP4（H.264 / H.265），全程本地。')
        this.AboutFeature('▤', '大文件友好', '文件描述符流式处理，内存占用恒定，10GB 以上的视频也不需要先读进内存。')
        this.AboutFeature('◈', '媒体本地处理', '提取、转换过程和结果都只留在设备上；仅 GitHub 头像和仓库链接需要联网，绝不上传媒体文件。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(17)
      .backgroundColor(COLOR_CARD)
      .borderRadius(22)
      .border({ width: 1, color: COLOR_LINE })
      this.ChangelogCard()
      Column({ space: 11 }) {
        Row() {
          Text('下一站：批量处理')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_INK)
          Blank()
          Text('V1.1 规划')
            .fontSize(8)
            .fontColor('#2E917B')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(COLOR_MINT_SOFT)
            .borderRadius(7)
        }
        .width('100%')
        Text('音频与视频转换已内置；批量处理、视频压缩和字幕会在后续版本加入。')
          .fontSize(9)
          .lineHeight(16)
          .fontColor(COLOR_SUB)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.InfoChip('批量处理', '#14F27EA8', COLOR_PINK_DARK)
          this.InfoChip('视频压缩', '#145FC7AD', '#2E917B')
          this.InfoChip('字幕', '#10000000', COLOR_SUB)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(17)
      .backgroundColor('#8CFFFFFF')
      .borderRadius(22)
      .border({ width: 1, color: COLOR_LINE })
      Column({ space: 8 }) {
        Text('关于 V1.0.1 · Beta 19')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Text('失真的压缩会偷走声音的细节。这个工具选择另一条路：只搬运，不改变。')
          .fontSize(9)
          .lineHeight(16)
          .fontColor(COLOR_SUB)
        Text('Ruinsss格式快转 · Made with care')
          .fontSize(8)
          .fontColor(COLOR_FAINT)
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(17)
      .backgroundColor('#66FFFFFF')
      .borderRadius(20)
      .border({ width: 1, color: '#99FFFFFF' })
    }
    .width('100%')
    .padding({ top: 4 })
  }

  @Builder
  ResumeCard() {
    Column({ space: 9 }) {
      Row() {
        Text('上次任务未完成')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_INK)
        Blank()
        Text('可恢复')
          .fontSize(9)
          .fontColor(COLOR_MINT)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(COLOR_MINT_SOFT)
          .borderRadius(8)
      }
      .width('100%')
      Text(this.resumeName)
        .fontSize(10)
        .fontColor(COLOR_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 8 }) {
        Button('恢复提取')
          .height(34)
          .layoutWeight(1)
          .borderRadius(12)
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor(COLOR_PINK)
          .onClick(() => {
            if (this.pendingJob !== null) {
              this.resumeJob(this.pendingJob);
            }
          })
        Button('放弃')
          .height(34)
          .width(72)
          .borderRadius(12)
          .fontSize(10)
          .fontColor(COLOR_PINK_DARK)
          .backgroundColor(COLOR_PINK_SOFT)
          .onClick(() => {
            if (this.pendingJob !== null) {
              this.discardPendingJob(this.pendingJob);
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(COLOR_CARD)
    .borderRadius(20)
    .border({ width: 1, color: '#E6FFFFFF' })
    .shadow(SHADOW_CARD)
  }

  @Builder
  ExtractTab() {
    if (this.phase === 'idle') {
      this.Hero()
      if (this.resumeName.length > 0) {
        this.ResumeCard()
      }
      this.PickerCard()
      this.PrivacyNote()
    } else if (this.phase === 'analyzing') {
      this.AnalyzingCard()
    } else if (this.phase === 'ready') {
      this.ExtractReady()
    } else if (this.phase === 'extracting') {
      this.ProgressCard()
    } else if (this.phase === 'success') {
      this.SuccessCard()
    } else {
      this.ErrorCard()
    }
  }

  @Builder
  LogTab() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('诊断日志')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_INK)
          Text(this.logCount.toString() + ' 条 · 仅保存在应用沙箱')
            .fontSize(9)
            .fontColor(COLOR_FAINT)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('复制全部')
          .fontSize(10)
          .height(32)
          .borderRadius(12)
          .fontColor(Color.White)
          .backgroundColor(COLOR_PINK)
          .onClick(() => {
            this.copyLogs();
          })
        Button('清空')
          .fontSize(10)
          .height(32)
          .borderRadius(12)
          .fontColor(COLOR_PINK_DARK)
          .backgroundColor(COLOR_PINK_SOFT)
          .margin({ left: 6 })
          .onClick(() => {
            this.clearLogs();
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 4 })

      Column({ space: 8 }) {
        Row() {
          Text('ruinsss-format.log')
            .fontSize(9)
            .fontColor(COLOR_FAINT)
          Blank()
          Text('复制后可反馈给 Ruinsss')
            .fontSize(9)
            .fontColor(COLOR_FAINT)
        }
        .width('100%')
        Scroll() {
          Text(this.logText.length > 0 ? this.logText : '暂无日志')
            .width('100%')
            .fontSize(9)
            .lineHeight(16)
            .fontFamily('monospace')
            .fontColor(COLOR_SUB)
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .height(430)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(15)
      .backgroundColor(COLOR_CARD)
      .borderRadius(22)
      .border({ width: 1, color: COLOR_LINE })
      .shadow({ radius: 18, color: '#10A56A8A', offsetX: 0, offsetY: 8 })
      Text('日志记录文件选择、探测、保存、提取/转码与错误码，不包含文件内容，也不会上传。')
        .fontSize(9)
        .lineHeight(15)
        .fontColor(COLOR_FAINT)
        .padding({ left: 4, right: 4 })
    }
    .width('100%')
    .padding({ top: 12, bottom: 18 })
  }

  @Builder
  DockGlyph(index: number, color: string) {
    if (index === 0) {
      Row({ space: 2 }) {
        Column().width(3).height(8).backgroundColor(color).borderRadius(2)
        Column().width(3).height(14).backgroundColor(color).borderRadius(2)
        Column().width(3).height(18).backgroundColor(color).borderRadius(2)
        Column().width(3).height(11).backgroundColor(color).borderRadius(2)
        Column().width(3).height(6).backgroundColor(color).borderRadius(2)
      }
      .height(19)
      .alignItems(VerticalAlign.Center)
    } else if (index === 1) {
      Text('⇄')
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
        .height(19)
    } else if (index === 2) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(17)
          .height(17)
          .borderRadius(5)
          .border({ width: 1.4, color: color })
        Column()
          .width(8)
          .height(1.3)
          .backgroundColor(color)
          .borderRadius(1)
          .offset({ x: 0, y: -3 })
        Column()
          .width(8)
          .height(1.3)
          .backgroundColor(color)
          .borderRadius(1)
          .offset({ x: 0, y: 3 })
      }
      .width(19)
      .height(19)
    } else if (index === 3) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(16)
          .height(18)
          .borderRadius(4)
          .border({ width: 1.4, color: color })
        Column()
          .width(8)
          .height(1.2)
          .backgroundColor(color)
          .borderRadius(1)
          .offset({ x: 0, y: -3 })
        Column()
          .width(8)
          .height(1.2)
          .backgroundColor(color)
          .borderRadius(1)
        Column()
          .width(5)
          .height(1.2)
          .backgroundColor(color)
          .borderRadius(1)
          .offset({ x: -1.5, y: 3 })
      }
      .width(19)
      .height(19)
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(17)
          .height(17)
          .borderRadius(9)
          .border({ width: 1.4, color: color })
        Text('i')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(color)
      }
      .width(19)
      .height(19)
    }
  }

  @Builder
  Dock() {
    Row() {
      Row() {
        ForEach(this.tabs, (index: number) => {
          Column({ space: 3 }) {
            this.DockGlyph(index, this.dockIndex === index ? COLOR_PINK_DARK : COLOR_FAINT)
            Text(index === 0 ? '提取' : (index === 1 ? '转换' : (index === 2 ? '记录' : (index === 3 ? '日志' : '关于'))))
              .fontSize(9)
              .fontColor(this.dockIndex === index ? COLOR_PINK_DARK : COLOR_SUB)
              .fontWeight(this.dockIndex === index ? FontWeight.Medium : FontWeight.Normal)
          }
          .layoutWeight(1)
          .height(54)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.dockIndex === index ? '#26F27EA8' : '#00FFFFFF')
          .borderRadius(17)
          .onClick(() => {
            this.selectDock(index);
          })
        }, (index: number) => index.toString())
      }
      .width('100%')
      .height(66)
      .padding(6)
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .linearGradient({
        angle: 180,
        colors: [['#E6FFFFFF', 0.0], ['#B3FFFFFF', 1.0]]
      })
      .borderRadius(25)
      .border({ width: 1, color: '#E6FFFFFF' })
      .shadow(SHADOW_DOCK)
    }
    .width('100%')
    .padding({ left: 18, right: 18, bottom: 12 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.BackgroundLayer()
      Column() {
        this.Header()
        Scroll() {
          Column({ space: 14 }) {
            if (this.dockIndex === 0) {
              this.ExtractTab()
            } else if (this.dockIndex === 1) {
              this.ConvertTab()
            } else if (this.dockIndex === 2) {
              this.HistoryTab()
            } else if (this.dockIndex === 3) {
              this.LogTab()
            } else {
              this.AboutTab()
            }
            Blank().height(104)
          }
          .width('100%')
          .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      this.Dock()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG_TOP)
    .onTouch((event: TouchEvent) => {
      this.handleRippleTouch(event);
    })
  }
}
