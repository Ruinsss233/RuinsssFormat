/**
 * Thin ArkTS wrapper around libruinsss_media.so.
 *
 * The native library reports JSON strings on purpose: the payload is small,
 * the schema is stable, and this keeps the N-API surface limited to primitives
 * plus one Promise. Extraction itself runs on the native worker thread.
 */

import nativeMedia from 'libruinsss_media.so';
import { ExtractProgress, ExtractResult, ProbeResult, parseExtract, parseProbe, parseProgress } from '../model/Types';

interface NativeMedia {
  probe(fd: number, size: number): string;
  extract(inputFd: number, inputSize: number, outputFd: number, format: string): Promise<string>;
  getProgress(): string;
  cancel(): void;
  version(): string;
}

const native: NativeMedia = nativeMedia as NativeMedia;

export class MediaService {
  static probe(fd: number, size: number): ProbeResult {
    return parseProbe(native.probe(fd, size));
  }

  static async extract(
    inputFd: number,
    inputSize: number,
    outputFd: number,
    format: string
  ): Promise<ExtractResult> {
    const raw: string = await native.extract(inputFd, inputSize, outputFd, format);
    return parseExtract(raw);
  }

  static progress(): ExtractProgress {
    return parseProgress(native.getProgress());
  }

  static cancel(): void {
    native.cancel();
  }

  static version(): string {
    return native.version();
  }
}
