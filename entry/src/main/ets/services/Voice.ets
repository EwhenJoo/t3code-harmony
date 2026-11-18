import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { appState, EnvironmentState } from '../model/AppState';
import { connection } from './Connection';
import { httpRequest, httpUpload, HttpResult } from '../net/HttpClient';
import { Prefs, PREF_VOICE } from '../common/Prefs';
import { Log } from '../common/Log';

const TAG = 'Voice';

/** What the computer's speech service takes: 16 kHz mono Float32 PCM, at most five minutes. */
export const SAMPLE_RATE = 16000;
export const MAX_RECORDING_SECONDS = 300;
/** Shorter than this is a stray tap, not speech. */
export const MIN_RECORDING_SECONDS = 0.4;

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';

/** Cloud speech services a computer can hold a key for (the desktop's Settings › Voice). */
export const CLOUD_PROVIDERS: string[] = ['openai', 'xai', 'openrouter'];

/** Languages the cloud services take (the server's own list). */
export const CLOUD_LANGUAGES: string[] =
  'zh en ja ko ar bg ca cs da de el es fa fi fr hi hr hu id it mk ms nl pl pt ro ru sk sv th tr uk ur vi'.split(' ');

export function providerName(provider: string): string {
  switch (provider) {
    case 'openai':
      return 'OpenAI';
    case 'xai':
      return 'xAI';
    case 'openrouter':
      return 'OpenRouter';
    default:
      return provider;
  }
}

const LANGUAGE_NAMES: Record<string, string> = {
  'zh': '中文',
  'yue': '粤语',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
  'fr': 'Français',
  'de': 'Deutsch',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'ru': 'Русский',
  'uk': 'Українська',
  'ar': 'العربية',
  'hi': 'हिन्दी',
  'nl': 'Nederlands',
  'tr': 'Türkçe',
  'vi': 'Tiếng Việt',
  'th': 'ไทย',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'pl': 'Polski',
  'sv': 'Svenska',
  'da': 'Dansk',
  'fi': 'Suomi',
  'cs': 'Čeština',
  'el': 'Ελληνικά',
  'he': 'עברית',
  'fa': 'فارسی',
  'hu': 'Magyar',
  'ro': 'Română',
  'bg': 'Български',
  'ca': 'Català',
  'hr': 'Hrvatski',
  'sk': 'Slovenčina',
  'mk': 'Македонски',
  'ur': 'اردو',
};

export function languageName(code: string): string {
  if (code === 'auto') {
    return '自动';
  }
  return LANGUAGE_NAMES[code] ?? LANGUAGE_NAMES[code.split('-')[0]] ?? code;
}

/** Languages to offer, the ones people here are likeliest to speak first. */
export function orderedLanguages(languages: string[]): string[] {
  const first = ['zh', 'en', 'yue', 'ja', 'ko'];
  const lead = first.filter((code: string) => languages.indexOf(code) >= 0);
  return lead.concat(languages.filter((code: string) => lead.indexOf(code) < 0));
}

/**
 * Voice input, set up as on the desktop: which computer turns speech into text, and with what — a
 * model on that computer, or a cloud service whose key that computer holds. Kept on this phone.
 */
@ObservedV2
export class VoiceSettings {
  /** '' never set up (the mic offers setup), 'off', 'local' (a model on the computer) or 'cloud'. */
  @Trace mode: string = '';
  @Trace environmentId: string = '';
  /** Cloud only: openai | xai | openrouter. */
  @Trace provider: string = '';
  /** OpenRouter only: the `author/model` slug. */
  @Trace cloudModel: string = '';
  @Trace language: string = 'auto';
  @Trace removeFillerWords: boolean = true;
  @Trace silenceFiltering: boolean = true;
  /** Tidy the transcript with the computer's text model (punctuation, lists, spoken corrections). */
  @Trace cleanup: boolean = false;
}

interface SavedVoice {
  mode?: string;
  environmentId?: string;
  provider?: string;
  cloudModel?: string;
  language?: string;
  removeFillerWords?: boolean;
  silenceFiltering?: boolean;
  cleanup?: boolean;
}

export interface SpeechModel {
  id: string;
  name: string;
  description?: string;
  size: number;
  languages: string[];
  recommended?: boolean;
  supportsLanguageDetection?: boolean;
  active?: boolean;
  /** downloadable | downloading | verifying | installed */
  state: string;
  /** Bytes so far while downloading. */
  downloaded?: number;
}

interface SpeechModels {
  models?: SpeechModel[];
}

export interface SpeechStatus {
  supported: boolean;
  reason?: string;
  state?: string;
  modelId?: string;
  model?: string;
  languages?: string[];
  supportsLanguageDetection?: boolean;
}

export interface CloudModel {
  id: string;
  name: string;
}

interface CloudModels {
  models?: CloudModel[];
}

interface TranscriptionResult {
  text?: string;
}

interface CustomWord {
  term: string;
  aliases: string[];
}

/** Recognition preferences that travel with every recording (SpeechTranscriptionOptions). */
export interface TranscriptionOptions {
  speechLanguage: string;
  speechTranslateToEnglish: boolean;
  speechCustomWords: CustomWord[];
  speechRemoveFillerWords: boolean;
  speechSilenceFiltering: boolean;
}

interface PromptSettings {
  mode: string;
  customInstructions: string;
}

interface PostProcessingOptions {
  speechCustomWords: CustomWord[];
  speechPostProcessingPrompt: PromptSettings;
}

interface TextSelection {
  start: number;
  end: number;
}

interface DraftContext {
  text: string;
  selection: TextSelection;
}

interface PostProcessingRequest {
  options: PostProcessingOptions;
  transcript: string;
  draft: DraftContext;
}

interface ModelRequest {
  modelId: string;
}

interface ErrorBody {
  _tag?: string;
  code?: string;
  reason?: string;
  provider?: string;
  message?: string;
}

/**
 * The transcription request body: a little-endian u32 with the options' length, the options as JSON,
 * then the audio as Float32 samples. The JSON is padded with spaces to a multiple of four bytes so the
 * samples can be written through an aligned Float32Array.
 */
export function encodeSpeechRequest(options: TranscriptionOptions, chunks: ArrayBuffer[]): ArrayBuffer {
  const encoder = new util.TextEncoder();
  let json = JSON.stringify(options);
  let head = encoder.encodeInto(json);
  while (head.length % 4 !== 0) {
    json += ' ';
    head = encoder.encodeInto(json);
  }
  let samples = 0;
  chunks.forEach((chunk: ArrayBuffer) => {
    samples += Math.floor(chunk.byteLength / 2);
  });
  const body = new ArrayBuffer(4 + head.length + samples * 4);
  new DataView(body).setUint32(0, head.length, true);
  new Uint8Array(body, 4, head.length).set(head);
  const pcm = new Float32Array(body, 4 + head.length, samples);
  let at = 0;
  chunks.forEach((chunk: ArrayBuffer) => {
    const source = new Int16Array(chunk, 0, Math.floor(chunk.byteLength / 2));
    for (let i = 0; i < source.length; i++) {
      pcm[at++] = source[i] / 32768;
    }
  });
  return body;
}

/** Up to 1 KB of the draft on each side of where the words go, as the desktop sends for cleanup. */
function draftContext(text: string, start: number, end: number): DraftContext {
  const window = 1024;
  const from = Math.max(0, Math.min(start, text.length));
  const to = Math.max(from, Math.min(end, text.length));
  const before = text.slice(Math.max(0, from - window), from);
  const selected = text.slice(from, Math.min(to, from + window));
  const after = text.slice(to, to + window);
  return { text: before + selected + after, selection: { start: before.length, end: before.length + selected.length } };
}

/** One recording from the microphone, kept in memory as 16 kHz mono 16-bit chunks. */
export class VoiceRecording {
  private capturer: audio.AudioCapturer | null = null;
  private chunks: ArrayBuffer[] = [];
  private samples: number = 0;
  private limited: boolean = false;
  /** Loudness of the latest chunk, 0…1, for the level meter. */
  onLevel: (level: number) => void = () => {
  };
  /** The five-minute limit was reached; the recording stops taking audio. */
  onLimit: () => void = () => {
  };

  get seconds(): number {
    return this.samples / SAMPLE_RATE;
  }

  async start(): Promise<void> {
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };
    const capturer = await audio.createAudioCapturer(options);
    this.capturer = capturer;
    capturer.on('readData', (buffer: ArrayBuffer) => this.take(buffer));
    await capturer.start();
  }

  private take(buffer: ArrayBuffer): void {
    if (this.limited || this.capturer === null) {
      return;
    }
    const room = MAX_RECORDING_SECONDS * SAMPLE_RATE - this.samples;
    const count = Math.min(room, Math.floor(buffer.byteLength / 2));
    if (count <= 0) {
      return;
    }
    const copy = buffer.slice(0, count * 2);
    const pcm = new Int16Array(copy);
    let sum = 0;
    for (let i = 0; i < pcm.length; i++) {
      sum += pcm[i] * pcm[i];
    }
    this.chunks.push(copy);
    this.samples += count;
    const rms = Math.sqrt(sum / Math.max(1, pcm.length)) / 32768;
    // Square root, so ordinary speech moves the meter visibly.
    this.onLevel(Math.min(1, Math.sqrt(rms) * 2.4));
    if (this.samples >= MAX_RECORDING_SECONDS * SAMPLE_RATE) {
      this.limited = true;
      this.onLimit();
    }
  }

  /** Stops the microphone and hands over the audio. */
  async finish(): Promise<ArrayBuffer[]> {
    await this.close();
    return this.chunks;
  }

  async cancel(): Promise<void> {
    await this.close();
    this.chunks = [];
    this.samples = 0;
  }

  private async close(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = null;
    if (capturer === null) {
      return;
    }
    try {
      capturer.off('readData');
    } catch (e) {
      // already detached
    }
    try {
      await capturer.stop();
    } catch (e) {
      Log.w(TAG, `capturer stop ${(e as Error).message}`);
    }
    try {
      await capturer.release();
    } catch (e) {
      Log.w(TAG, `capturer release ${(e as Error).message}`);
    }
  }
}

export class VoiceService {
  readonly settings: VoiceSettings = new VoiceSettings();

  load(): void {
    try {
      const saved = JSON.parse(Prefs.getString(PREF_VOICE, '{}')) as SavedVoice;
      const s = this.settings;
      s.mode = saved.mode ?? '';
      s.environmentId = saved.environmentId ?? '';
      s.provider = saved.provider ?? '';
      s.cloudModel = saved.cloudModel ?? '';
      s.language = saved.language ?? 'auto';
      s.removeFillerWords = saved.removeFillerWords ?? true;
      s.silenceFiltering = saved.silenceFiltering ?? true;
      s.cleanup = saved.cleanup ?? false;
    } catch (e) {
      Log.w(TAG, 'saved voice settings unreadable');
    }
  }

  save(): void {
    const s = this.settings;
    const saved: SavedVoice = {
      mode: s.mode,
      environmentId: s.environmentId,
      provider: s.provider,
      cloudModel: s.cloudModel,
      language: s.language,
      removeFillerWords: s.removeFillerWords,
      silenceFiltering: s.silenceFiltering,
      cleanup: s.cleanup,
    };
    Prefs.put(PREF_VOICE, JSON.stringify(saved));
  }

  /** Off, or transcribe on a computer: its own model (provider '') or a cloud service it has a key for. */
  setDestination(mode: string, environmentId: string = '', provider: string = ''): void {
    const s = this.settings;
    if (s.mode !== mode || s.environmentId !== environmentId || s.provider !== provider) {
      s.cloudModel = '';
    }
    s.mode = mode;
    s.environmentId = mode === 'off' ? '' : environmentId;
    s.provider = mode === 'cloud' ? provider : '';
    this.save();
  }

  setCloudModel(model: string): void {
    this.settings.cloudModel = model;
    this.save();
  }

  setLanguage(language: string): void {
    this.settings.language = language;
    this.save();
  }

  setRemoveFillerWords(on: boolean): void {
    this.settings.removeFillerWords = on;
    this.save();
  }

  setSilenceFiltering(on: boolean): void {
    this.settings.silenceFiltering = on;
    this.save();
  }

  setCleanup(on: boolean): void {
    this.settings.cleanup = on;
    this.save();
  }

  environment(): EnvironmentState | null {
    return appState.environmentFor(this.settings.environmentId) ?? null;
  }

  /** "ThinkPad · 本机模型", "ThinkPad · OpenAI", "关闭" or "未设置". */
  destinationLabel(): string {
    const s = this.settings;
    if (s.mode === 'off') {
      return '关闭';
    }
    if (s.mode !== 'local' && s.mode !== 'cloud') {
      return '未设置';
    }
    const env = this.environment();
    const where = env !== null ? env.label : '已移除的电脑';
    return `${where} · ${s.mode === 'cloud' ? providerName(s.provider) : '本机模型'}`;
  }

  /** '' when a recording can be sent now, else why not. */
  unavailableReason(): string {
    const s = this.settings;
    if (s.mode !== 'local' && s.mode !== 'cloud') {
      return '还没有设置语音输入';
    }
    const env = this.environment();
    if (env === null) {
      return '语音输入用的电脑已移除';
    }
    if (env.phase !== 'connected') {
      return `${env.label} 未连接`;
    }
    return '';
  }

  /** Asks for the microphone; a refusal made earlier goes through the system's settings dialog. */
  async requestMicrophone(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    try {
      const result = await manager.requestPermissionsFromUser(context, [MICROPHONE]);
      if (result.authResults[0] === 0) {
        return true;
      }
      if ((result.dialogShownResults ?? [])[0] === true) {
        return false; // just refused in the dialog
      }
      const states = await manager.requestPermissionOnSetting(context, [MICROPHONE]);
      return states[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      Log.w(TAG, `microphone permission ${JSON.stringify(e)}`);
      return false;
    }
  }

  // ---- The computer's voice API ---------------------------------------------------------------

  private async request(environmentId: string, method: string, path: string, body?: Object,
    timeoutMs: number = 20000): Promise<Object | null> {
    const url = connection.httpUrl(environmentId, path);
    const headers = await connection.authHeadersFor(environmentId, method, url);
    if (body !== undefined) {
      headers['content-type'] = 'application/json';
    }
    const result = await httpRequest(method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET, url, headers,
      body !== undefined ? JSON.stringify(body) : undefined, timeoutMs);
    if (result.status < 200 || result.status >= 300) {
      throw voiceError(result, '');
    }
    return result.body.length > 0 ? JSON.parse(result.body) as Object : null;
  }

  async status(environmentId: string): Promise<SpeechStatus> {
    return await this.request(environmentId, 'GET', '/api/voice/status') as SpeechStatus;
  }

  async models(environmentId: string): Promise<SpeechModel[]> {
    const result = await this.request(environmentId, 'GET', '/api/voice/models') as SpeechModels | null;
    return result?.models ?? [];
  }

  async selectModel(environmentId: string, modelId: string): Promise<SpeechModel[]> {
    const payload: ModelRequest = { modelId: modelId };
    const result = await this.request(environmentId, 'POST', '/api/voice/models/select', payload) as SpeechModels | null;
    return result?.models ?? [];
  }

  /** Downloads a model onto the computer; answers once it is there (minutes for the big ones). */
  async downloadModel(environmentId: string, modelId: string): Promise<SpeechModel[]> {
    const payload: ModelRequest = { modelId: modelId };
    const result = await this.request(environmentId, 'POST', '/api/voice/models/download', payload,
      30 * 60 * 1000) as SpeechModels | null;
    return result?.models ?? [];
  }

  /** Which cloud services the computer holds a key for. */
  async cloudKeys(environmentId: string): Promise<string[]> {
    const result = await this.request(environmentId, 'GET', '/api/voice/cloud/keys') as Record<string, boolean> | null;
    return CLOUD_PROVIDERS.filter((provider: string) => result !== null && result[provider] === true);
  }

  async cloudModels(environmentId: string): Promise<CloudModel[]> {
    const result = await this.request(environmentId, 'GET', '/api/voice/cloud/openrouter/models') as CloudModels | null;
    return result?.models ?? [];
  }

  options(): TranscriptionOptions {
    const s = this.settings;
    return {
      speechLanguage: s.language.length >= 2 ? s.language : 'auto',
      speechTranslateToEnglish: false,
      speechCustomWords: [],
      speechRemoveFillerWords: s.removeFillerWords,
      speechSilenceFiltering: s.silenceFiltering,
    };
  }

  /** Sends a recording to the chosen computer and returns what was said. */
  async transcribe(chunks: ArrayBuffer[]): Promise<string> {
    const reason = this.unavailableReason();
    if (reason.length > 0) {
      throw new Error(reason);
    }
    const s = this.settings;
    let path = '/api/voice/transcribe';
    if (s.mode === 'cloud') {
      path = `/api/voice/cloud/${s.provider}/transcribe`;
      if (s.provider === 'openrouter' && s.cloudModel.length > 0) {
        path += `?model=${encodeURIComponent(s.cloudModel)}`;
      }
    }
    const body = encodeSpeechRequest(this.options(), chunks);
    const url = connection.httpUrl(s.environmentId, path);
    const headers = await connection.authHeadersFor(s.environmentId, 'POST', url);
    headers['content-type'] = 'application/octet-stream';
    const result = await httpUpload(url, headers, body, 180000);
    if (result.status < 200 || result.status >= 300) {
      throw voiceError(result, s.mode === 'cloud' ? s.provider : '');
    }
    const parsed = JSON.parse(result.body) as TranscriptionResult;
    return (parsed.text ?? '').trim();
  }

  /**
   * Tidies a transcript with the computer's text model, given the draft around where it goes. Only
   * text is sent, never audio; on failure the raw transcript stands.
   */
  async cleanup(transcript: string, draft: string, start: number, end: number): Promise<string> {
    const payload: PostProcessingRequest = {
      options: { speechCustomWords: [], speechPostProcessingPrompt: { mode: 'default', customInstructions: '' } },
      transcript: transcript,
      draft: draftContext(draft, start, end),
    };
    try {
      const result = await this.request(this.settings.environmentId, 'POST', '/api/voice/post-process',
        payload, 60000) as TranscriptionResult | null;
      const text = (result?.text ?? '').trim();
      return text.length > 0 ? text : transcript;
    } catch (e) {
      Log.w(TAG, `cleanup failed ${(e as Error).message}`);
      return transcript;
    }
  }
}

/** The computer's refusal, in words. */
function voiceError(result: HttpResult, provider: string): Error {
  let body: ErrorBody = {};
  try {
    body = JSON.parse(result.body) as ErrorBody;
  } catch (e) {
    // not JSON
  }
  const name = providerName(body.provider ?? provider);
  if (body._tag === 'CloudSpeechError' || result.status === 422) {
    switch (body.reason) {
      case 'missing-key':
        return new Error(`电脑上还没有 ${name} 的 API 密钥`);
      case 'key-changed':
        return new Error(`${name} 密钥刚刚变了，再试一次`);
      case 'unreadable-key':
        return new Error(`电脑读不到 ${name} 密钥，录音没有发出`);
      case 'rejected-key':
        return new Error(`${name} 拒绝了这个密钥`);
      case 'rate-limit':
        return new Error(`${name} 达到用量上限，稍后再试`);
      case 'model-unavailable':
        return new Error(`${name} 上没有所选的模型`);
      default:
        return new Error(`${name} 暂时转写不了，稍后再试`);
    }
  }
  switch (body.reason) {
    case 'invalid_audio':
      return new Error('录音无法识别，再录一次');
    case 'speech_busy':
      return new Error('电脑正忙（转写或下载模型），稍后再试');
    case 'speech_unavailable':
      return new Error('这台电脑不支持本机转写');
    case 'invalid_command':
      return new Error('电脑上没有所选的模型');
    default:
      break;
  }
  if (result.status === 403) {
    return new Error('这台电脑不允许手机做这项操作');
  }
  if (result.status === 404) {
    return new Error('这台电脑的 T3 Code 不支持语音输入，请先更新');
  }
  if (result.status === 401) {
    return new Error('登录已失效，请重新连接这台电脑');
  }
  return new Error(`电脑转写失败（${result.status}）`);
}

export const voice: VoiceService = new VoiceService();
