/** File picking / opening helpers. All file access stays on-device. */

import { common } from '@kit.AbilityKit';
import { fileIo, fileShare, picker } from '@kit.CoreFileKit';
import { baseName, safeFileName } from '../model/Types';

export class PickedVideo {
  uri: string = '';
  name: string = '';
  size: number = 0;
  file: fileIo.File | null = null;
}

export class SaveTarget {
  uri: string = '';
  name: string = '';
  file: fileIo.File | null = null;
}

export class FileService {
  static async pickMedia(
    ctx: common.UIAbilityContext,
    filters: string[]
  ): Promise<PickedVideo | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = filters;
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await documentPicker.select(options);
    if (uris === undefined || uris === null || uris.length === 0) {
      return null;
    }
    const uri: string = uris[0];
    const picked: PickedVideo = new PickedVideo();
    picked.uri = uri;
    picked.name = FileService.displayName(uri);
    picked.size = fileIo.statSync(uri).size;
    picked.file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    await FileService.persist([uri], false);
    return picked;
  }

  static async pickVideo(ctx: common.UIAbilityContext): Promise<PickedVideo | null> {
    return FileService.pickMedia(ctx, [
      '视频文件|.mp4,.mkv,.mov,.m4v,.avi,.flv,.ts,.webm,.3gp,.wmv,.mpg,.mpeg,.m2ts'
    ]);
  }

  static async pickAudio(ctx: common.UIAbilityContext): Promise<PickedVideo | null> {
    return FileService.pickMedia(ctx, [
      '音频文件|.mp3,.flac,.m4a,.aac,.ogg,.opus,.amr,.ape,.wma'
    ]);
  }

  static async chooseSave(
    ctx: common.UIAbilityContext,
    sourceName: string,
    extension: string,
    label: string = '音频'
  ): Promise<SaveTarget | null> {
    const stem: string = safeFileName(baseName(sourceName));
    const fileName: string = stem + '_' + label + '.' + extension;
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.' + extension];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await documentPicker.save(options);
    if (uris === undefined || uris === null || uris.length === 0) {
      return null;
    }
    const target: SaveTarget = new SaveTarget();
    target.uri = uris[0];
    target.name = FileService.displayName(target.uri);
    // The picker has already created the document and granted read/write
    // access. CREATE/TRUNC can be rejected by document providers; the native
    // muxer truncates the descriptor itself before writing.
    target.file = fileIo.openSync(target.uri, fileIo.OpenMode.READ_WRITE);
    await FileService.persist([target.uri], true);
    return target;
  }

  static closeFile(file: fileIo.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fileIo.closeSync(file);
    } catch (e) {
      console.error('closeFile failed: ' + JSON.stringify(e));
    }
  }

  static sizeOf(uri: string): number {
    try {
      return fileIo.statSync(uri).size;
    } catch (e) {
      return 0;
    }
  }

  static tryDelete(uri: string): void {
    if (uri.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(uri);
    } catch (e) {
      // Document providers do not always allow unlink; a zero-byte file is a
      // harmless fallback compared with losing the user's original selection.
    }
  }

  static async persist(uris: string[], write: boolean): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    try {
      const policy: fileShare.PolicyInfo[] = [];
      for (let i = 0; i < uris.length; i++) {
        let mode: number = fileShare.OperationMode.READ_MODE;
        if (write) {
          mode = mode | fileShare.OperationMode.WRITE_MODE;
        }
        policy.push({ uri: uris[i], operationMode: mode });
      }
      await fileShare.persistPermission(policy);
    } catch (e) {
      console.error('persist uri permission failed: ' + JSON.stringify(e));
    }
  }

  static async release(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    try {
      const policy: fileShare.PolicyInfo[] = [];
      for (let i = 0; i < uris.length; i++) {
        policy.push({
          uri: uris[i],
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
        });
      }
      await fileShare.revokePermission(policy);
    } catch (e) {
      console.error('revoke uri permission failed: ' + JSON.stringify(e));
    }
  }

  static displayName(uri: string): string {
    let s: string = uri;
    const query: number = s.indexOf('?');
    if (query >= 0) {
      s = s.substring(0, query);
    }
    const slash: number = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
    if (slash >= 0 && slash + 1 < s.length) {
      s = s.substring(slash + 1);
    }
    try {
      s = decodeURIComponent(s);
    } catch (e) {
      // Keep the raw name when it contains a stray percent sign.
    }
    return s.length > 0 ? s : '未命名视频';
  }
}
