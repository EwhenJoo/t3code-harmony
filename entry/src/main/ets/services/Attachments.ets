import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { ChatAttachment } from '../model/Types';
import { connection } from './Connection';
import { httpDownload, httpUpload } from '../net/HttpClient';
import { Log } from '../common/Log';

const TAG = 'Attachments';
/** What the server accepts as an image the model can see (PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES). */
const IMAGE_TYPES: string[] = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_FILE_BYTES = 50 * 1024 * 1024;
/** Longest side of a photo that has to be re-encoded (HEIC, or over the image limit). */
const MAX_IMAGE_SIDE = 3072;
export const MAX_ATTACHMENTS = 20;

const MIME_BY_EXTENSION: Record<string, string> = {
  'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'webp': 'image/webp', 'gif': 'image/gif',
  'heic': 'image/heic', 'heif': 'image/heif', 'bmp': 'image/bmp', 'svg': 'image/svg+xml',
  'pdf': 'application/pdf', 'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv', 'json': 'application/json',
  'log': 'text/plain', 'xml': 'application/xml', 'html': 'text/html', 'zip': 'application/zip',
  'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'py': 'text/x-python', 'ts': 'text/plain', 'js': 'text/javascript', 'yaml': 'text/yaml', 'yml': 'text/yaml',
};

interface UploadUrlInput {
  type: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
}

interface UploadUrlResult {
  attachmentId?: string;
  relativeUrl?: string;
}

interface AttachmentDeleteInput {
  attachmentId: string;
}

export function mimeTypeOf(name: string): string {
  const dot = name.lastIndexOf('.');
  const ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  return MIME_BY_EXTENSION[ext] ?? 'application/octet-stream';
}

export function sizeLabel(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${Math.round(bytes / 1024)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function nameFromUri(uri: string): string {
  const path = uri.split('?')[0];
  const last = path.substring(path.lastIndexOf('/') + 1);
  try {
    return decodeURIComponent(last);
  } catch (e) {
    return last;
  }
}

/**
 * One file the user attached to the message being written. It is copied into the app's cache right
 * away (picker grants are temporary) and uploaded to the computer the message goes to; `status`
 * tells the composer whether it can be sent yet.
 */
@ObservedV2
export class DraftAttachment {
  key: string = util.generateRandomUUID();
  @Trace kind: string = 'file'; // image | file
  @Trace name: string = '';
  @Trace mimeType: string = '';
  @Trace sizeBytes: number = 0;
  /** file:// URI of the cached copy, for the thumbnail. */
  @Trace uri: string = '';
  @Trace status: string = 'uploading'; // uploading | ready | failed
  @Trace error: string = '';
  path: string = '';
  attachmentId: string = '';
  environmentId: string = '';

  toWire(): ChatAttachment {
    return {
      type: this.kind, id: this.attachmentId, name: this.name, mimeType: this.mimeType, sizeBytes: this.sizeBytes,
    };
  }
}

/** Picks photos and files, prepares them for the server's limits and uploads them (attachments.createUploadUrl). */
export class AttachmentService {
  private cacheDir(context: common.Context): string {
    const dir = `${context.cacheDir}/attachments`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
    } catch (e) {
      Log.w(TAG, `cache folder unavailable ${JSON.stringify(e)}`);
    }
    return dir;
  }

  async pickPhotos(max: number): Promise<string[]> {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = Math.max(1, max);
    const result = await new photoAccessHelper.PhotoViewPicker().select(options);
    return result.photoUris ?? [];
  }

  async pickFiles(max: number): Promise<string[]> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = Math.max(1, max);
    return await new picker.DocumentViewPicker().select(options);
  }

  /** Copies a picked file into the cache; photos the model cannot take as they are become JPEG. */
  async prepare(context: common.Context, uri: string, fromPhotos: boolean): Promise<DraftAttachment> {
    const draft = new DraftAttachment();
    draft.name = nameFromUri(uri);
    draft.mimeType = mimeTypeOf(draft.name);
    const isImage = fromPhotos || draft.mimeType.startsWith('image/');
    const dest = `${this.cacheDir(context)}/${draft.key}-${draft.name.replace(/[\/\\]/g, '_')}`;
    const source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(source.fd).size;
      const supportedImage = IMAGE_TYPES.indexOf(draft.mimeType) >= 0;
      if (isImage && (!supportedImage || size > MAX_IMAGE_BYTES)) {
        await this.reencode(source.fd, dest + '.jpg');
        draft.path = dest + '.jpg';
        draft.name = draft.name.replace(/\.[^.]*$/, '') + '.jpg';
        draft.mimeType = 'image/jpeg';
      } else {
        fileIo.copyFileSync(source.fd, dest);
        draft.path = dest;
      }
    } finally {
      fileIo.closeSync(source);
    }
    draft.sizeBytes = fileIo.statSync(draft.path).size;
    draft.kind = IMAGE_TYPES.indexOf(draft.mimeType) >= 0 && draft.sizeBytes <= MAX_IMAGE_BYTES ? 'image' : 'file';
    draft.uri = `file://${draft.path}`;
    if (draft.sizeBytes === 0) {
      throw new Error(`${draft.name} 是空文件`);
    }
    if (draft.sizeBytes > MAX_FILE_BYTES) {
      fileIo.unlinkSync(draft.path);
      throw new Error(`${draft.name} 超过 50 MB`);
    }
    return draft;
  }

  private async reencode(fd: number, dest: string): Promise<void> {
    const source = image.createImageSource(fd);
    try {
      const info = await source.getImageInfo();
      const longest = Math.max(info.size.width, info.size.height);
      const scale = longest > MAX_IMAGE_SIDE ? MAX_IMAGE_SIDE / longest : 1;
      const pixels = await source.createPixelMap({
        desiredSize: { width: Math.round(info.size.width * scale), height: Math.round(info.size.height * scale) },
      });
      const packer = image.createImagePacker();
      try {
        const data = await packer.packToData(pixels, { format: 'image/jpeg', quality: 85 });
        const file = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, data);
        fileIo.closeSync(file);
      } finally {
        packer.release();
        pixels.release();
      }
    } finally {
      source.release();
    }
  }

  /** Uploads (or re-uploads, after the message's computer changed) one attachment. */
  async upload(draft: DraftAttachment, environmentId: string): Promise<void> {
    draft.status = 'uploading';
    draft.error = '';
    draft.environmentId = environmentId;
    try {
      const input: UploadUrlInput = { type: draft.kind, name: draft.name, mimeType: draft.mimeType, sizeBytes: draft.sizeBytes };
      const result = await connection.rpc(environmentId, 'attachments.createUploadUrl', input) as UploadUrlResult | null;
      const attachmentId = result?.attachmentId ?? '';
      const relative = result?.relativeUrl ?? '';
      if (attachmentId.length === 0 || relative.length === 0) {
        throw new Error('电脑没有给出上传地址');
      }
      const file = fileIo.openSync(draft.path, fileIo.OpenMode.READ_ONLY);
      const data = new ArrayBuffer(draft.sizeBytes);
      try {
        fileIo.readSync(file.fd, data);
      } finally {
        fileIo.closeSync(file);
      }
      const url = connection.httpUrl(environmentId, relative);
      const headers = await connection.authHeadersFor(environmentId, 'POST', url);
      headers['content-type'] = draft.mimeType;
      const response = await httpUpload(url, headers, data);
      if (response.status < 200 || response.status >= 300) {
        throw new Error(response.body.length > 0 && response.body.length < 120 ? response.body : `上传被拒绝（${response.status}）`);
      }
      if (draft.environmentId !== environmentId) {
        return; // the message moved to another computer meanwhile; that upload wins
      }
      draft.attachmentId = attachmentId;
      draft.status = 'ready';
    } catch (e) {
      if (draft.environmentId === environmentId) {
        draft.status = 'failed';
        draft.error = (e as Error).message ?? '上传失败';
      }
      Log.w(TAG, `upload ${draft.name} failed: ${(e as Error).message}`);
    }
  }

  /** Lets the computer drop an upload the user removed before sending. */
  discard(draft: DraftAttachment): void {
    if (draft.attachmentId.length > 0 && draft.environmentId.length > 0) {
      const input: AttachmentDeleteInput = { attachmentId: draft.attachmentId };
      connection.rpc(draft.environmentId, 'attachments.delete', input).catch(() => {
      });
    }
    this.forget(draft);
  }

  /** Removes the cached copy once the message is sent (or the attachment dropped). */
  forget(draft: DraftAttachment): void {
    try {
      if (draft.path.length > 0 && fileIo.accessSync(draft.path)) {
        fileIo.unlinkSync(draft.path);
      }
    } catch (e) {
      // already gone
    }
  }
}

export const attachments: AttachmentService = new AttachmentService();

interface AttachmentResource {
  _tag: string;
  attachmentId: string;
  fileName?: string;
  mimeType?: string;
  disposition?: string;
}

interface AttachmentAssetInput {
  resource: AttachmentResource;
}

interface AssetUrl {
  relativeUrl?: string;
}

/**
 * Images sent in a conversation, fetched once through a signed asset URL (assets.createUrl) and kept in
 * the cache; `version` changes when one lands, so bubbles re-read their source.
 */
@ObservedV2
export class AttachmentPreviews {
  @Trace version: number = 0;
  private context: common.Context | null = null;
  private files: Map<string, string> = new Map();
  private pending: Set<string> = new Set();
  private failed: Set<string> = new Set();

  init(context: common.Context): void {
    this.context = context;
  }

  /** A file:// URI of the image, or '' while it loads (or if it cannot be shown). */
  imageUri(environmentId: string, file: ChatAttachment): string {
    const key = `${environmentId}|${file.id}`;
    const known = this.files.get(key);
    if (known !== undefined) {
      return known;
    }
    if (!this.pending.has(key) && !this.failed.has(key) && this.context !== null && environmentId.length > 0) {
      this.pending.add(key);
      this.fetch(environmentId, file, key).finally(() => this.pending.delete(key));
    }
    return '';
  }

  private async fetch(environmentId: string, file: ChatAttachment, key: string): Promise<void> {
    try {
      const input: AttachmentAssetInput = {
        resource: { _tag: 'attachment', attachmentId: file.id, fileName: file.name, mimeType: file.mimeType, disposition: 'inline' },
      };
      const result = await connection.rpc(environmentId, 'assets.createUrl', input) as AssetUrl | null;
      const relative = result?.relativeUrl ?? '';
      if (relative.length === 0) {
        throw new Error('no url');
      }
      const url = connection.httpUrl(environmentId, relative);
      const response = await httpDownload(url, await connection.authHeadersFor(environmentId, 'GET', url), 30000, 12 * 1024 * 1024);
      if (response.status !== 200 || response.data.byteLength === 0) {
        throw new Error(`status ${response.status}`);
      }
      const dir = `${(this.context as common.Context).cacheDir}/sent-attachments`;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
      const ext = file.name.lastIndexOf('.') >= 0 ? file.name.substring(file.name.lastIndexOf('.')) : '';
      const path = `${dir}/${file.id.replace(/[^A-Za-z0-9._-]/g, '_')}${ext}`;
      const out = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(out.fd, response.data);
      fileIo.closeSync(out);
      this.files.set(key, `file://${path}`);
      this.version++;
    } catch (e) {
      this.failed.add(key);
      Log.d(TAG, `preview of ${file.name} unavailable: ${(e as Error).message}`);
    }
  }
}

export const attachmentPreviews: AttachmentPreviews = new AttachmentPreviews();
