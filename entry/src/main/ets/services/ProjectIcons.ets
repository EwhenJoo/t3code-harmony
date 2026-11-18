import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ProjectShell } from '../model/Types';
import { connection } from './Connection';
import { httpDownload } from '../net/HttpClient';
import { Log } from '../common/Log';

const TAG = 'ProjectIcons';
/** The server answers with this file name when a project has no favicon. */
const FAVICON_MISSING = 'project-favicon-missing';
const FAVICON_TTL_MS = 24 * 3600 * 1000;

interface LucideTable {
  version: string;
  icons: Record<string, string>;
  names: Record<string, string>;
}

interface AssetUrlResult {
  relativeUrl?: string;
  expiresAt?: number;
}

interface FaviconResource {
  _tag: string;
  cwd: string;
  path?: string;
}

interface AssetUrlInput {
  resource: FaviconResource;
}

class FaviconEntry {
  /** file:// URI of the downloaded image, or '' when the project has none. */
  uri: string = '';
  fetchedAt: number = 0;
}

function hash(text: string): string {
  let h = 5381;
  for (let i = 0; i < text.length; i++) {
    h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  }
  return (h >>> 0).toString(16);
}

/** "folder-code" → "FolderCode", the way lucide (and the desktop) resolve saved names. */
function toPascalName(name: string): string {
  return name.split('-').map((part: string) => part.length > 0 ? part.charAt(0).toUpperCase() + part.substring(1) : '').join('');
}

function extensionFor(contentType: string, url: string): string {
  if (contentType.indexOf('svg') >= 0) {
    return 'svg';
  }
  if (contentType.indexOf('png') >= 0) {
    return 'png';
  }
  if (contentType.indexOf('jpeg') >= 0 || contentType.indexOf('jpg') >= 0) {
    return 'jpg';
  }
  if (contentType.indexOf('webp') >= 0) {
    return 'webp';
  }
  if (contentType.indexOf('gif') >= 0) {
    return 'gif';
  }
  const path = url.split('?')[0];
  const dot = path.lastIndexOf('.');
  return dot >= 0 ? path.substring(dot + 1).toLowerCase() : 'img';
}

/**
 * Project icons as the desktop shows them. Lucide overrides are drawn from the same icon set the
 * desktop bundles (lucide 0.564, packed in rawfile/lucide), written as tinted SVG files once;
 * favicons are fetched through `assets.createUrl` (a signed URL) and cached on disk for a day.
 * `version` changes whenever a download lands, so badges re-read their source.
 */
@ObservedV2
export class ProjectIconService {
  @Trace version: number = 0;
  private context: common.Context | null = null;
  private lucide: LucideTable | null = null;
  private lucideFiles: Map<string, string> = new Map();
  private favicons: Map<string, FaviconEntry> = new Map();
  private pending: Set<string> = new Set();
  private failed: Set<string> = new Set();

  init(context: common.Context): void {
    this.context = context;
  }

  private dir(): string {
    const dir = `${this.context?.filesDir ?? ''}/project-icons`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
    } catch (e) {
      Log.w(TAG, `icon folder unavailable ${JSON.stringify(e)}`);
    }
    return dir;
  }

  private table(): LucideTable | null {
    if (this.lucide === null && this.context !== null) {
      try {
        const bytes = this.context.resourceManager.getRawFileContentSync('lucide/icons.json');
        const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
        this.lucide = JSON.parse(text) as LucideTable;
      } catch (e) {
        Log.w(TAG, `lucide table unavailable ${JSON.stringify(e)}`);
      }
    }
    return this.lucide;
  }

  hasLucide(name: string): boolean {
    const table = this.table();
    if (table === null) {
      return false;
    }
    return table.names[toPascalName(name)] !== undefined || table.icons[name] !== undefined;
  }

  /** A file:// URI of the lucide icon stroked in `hex`; '' when the name is unknown. */
  lucideUri(name: string, hex: string): string {
    const key = `${name}:${hex}`;
    const known = this.lucideFiles.get(key);
    if (known !== undefined) {
      return known;
    }
    const table = this.table();
    if (table === null || this.context === null) {
      return '';
    }
    const canonical = table.names[toPascalName(name)] ?? name;
    const inner = table.icons[canonical];
    if (inner === undefined) {
      return '';
    }
    const path = `${this.dir()}/lucide-${canonical}-${hex.replace('#', '')}.svg`;
    try {
      if (!fileIo.accessSync(path)) {
        const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="${hex}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
        const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, svg);
        fileIo.closeSync(file);
      }
    } catch (e) {
      Log.w(TAG, `write lucide icon failed ${JSON.stringify(e)}`);
      return '';
    }
    const uri = `file://${path}`;
    this.lucideFiles.set(key, uri);
    return uri;
  }

  private faviconKey(project: ProjectShell): string {
    return `${project.environmentId ?? ''}|${project.workspaceRoot ?? ''}|${project.faviconPath ?? ''}`;
  }

  /**
   * The project's favicon as a file:// URI. '' means "none (yet)": the first call starts the
   * download and `version` bumps when it lands.
   */
  faviconUri(project: ProjectShell): string {
    const key = this.faviconKey(project);
    if (this.failed.has(key)) {
      return '';
    }
    const entry = this.favicons.get(key);
    if (entry !== undefined && Date.now() - entry.fetchedAt < FAVICON_TTL_MS) {
      return entry.uri;
    }
    if (!this.pending.has(key) && (project.workspaceRoot ?? '').length > 0 && (project.environmentId ?? '').length > 0) {
      this.pending.add(key);
      this.fetchFavicon(project, key).finally(() => this.pending.delete(key));
    }
    return entry?.uri ?? '';
  }

  /** An image that would not decode (e.g. .icns): fall back to the monogram from now on. */
  markBroken(project: ProjectShell): void {
    this.failed.add(this.faviconKey(project));
    this.version++;
  }

  private async fetchFavicon(project: ProjectShell, key: string): Promise<void> {
    const envId = project.environmentId ?? '';
    const entry = new FaviconEntry();
    entry.fetchedAt = Date.now();
    try {
      const resource: FaviconResource = { _tag: 'project-favicon', cwd: project.workspaceRoot ?? '' };
      if ((project.faviconPath ?? '').length > 0) {
        resource.path = project.faviconPath ?? undefined;
      }
      const input: AssetUrlInput = { resource: resource };
      const result = await connection.rpc(envId, 'assets.createUrl', input) as AssetUrlResult | null;
      const relative = result?.relativeUrl ?? '';
      if (relative.length > 0 && relative.split('?')[0].split('/').pop() !== FAVICON_MISSING) {
        const url = connection.httpUrl(envId, relative);
        const res = await httpDownload(url, await connection.authHeadersFor(envId, 'GET', url));
        if (res.status === 200 && res.data.byteLength > 0) {
          // A fresh name per download, so an Image never keeps showing a stale file.
          const path = `${this.dir()}/favicon-${hash(key)}-${entry.fetchedAt}.${extensionFor(res.contentType, url)}`;
          const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(file.fd, res.data);
          fileIo.closeSync(file);
          const previous = this.favicons.get(key)?.uri ?? '';
          if (previous.startsWith('file://')) {
            try {
              fileIo.unlinkSync(previous.substring(7));
            } catch (e) {
              // already gone
            }
          }
          entry.uri = `file://${path}`;
        }
      }
    } catch (e) {
      Log.d(TAG, `favicon for ${project.title} unavailable: ${(e as Error).message}`);
    }
    this.favicons.set(key, entry);
    if (entry.uri.length > 0) {
      this.version++;
    }
  }
}

export const projectIcons: ProjectIconService = new ProjectIconService();
