/**
 * Wire shapes for the T3 Code orchestration v2 protocol (subset this client reads).
 * Field names mirror packages/contracts/src/orchestrationV2.ts in the T3 Code repo.
 * Every field the server may omit is optional so JSON.parse results can be cast safely.
 */

import { ProviderUsageLimits } from './Workspace';

export interface ModelOption {
  id: string;
  value?: string | number | boolean;
}

export interface ModelSelection {
  instanceId: string;
  model: string;
  options?: ModelOption[];
}

export interface PendingRuntimeRequestSummary {
  id: string;
  kind: string;
  createdAt: string;
  blocking?: boolean;
  userOnly?: boolean;
}

export interface LatestVisibleMessageSummary {
  id: string;
  role: string;
  text: string;
  updatedAt: string;
}

/** A project's icon override, as the desktop saves it: lucide (name + color), emoji, or monogram. */
export interface ProjectIcon {
  kind?: string;
  name?: string;
  color?: string;
  emoji?: string;
  text?: string;
}

/** A project's saved command (ProjectScript), offered in the terminal menu like on iOS. */
export interface ProjectScript {
  id: string;
  name: string;
  command: string;
  icon?: string;
  runOnWorktreeCreate?: boolean;
  runOnSettle?: boolean;
}

export interface ProjectShell {
  id: string;
  /** Client-side: the computer this project lives on (set when the shell stream delivers it). */
  environmentId?: string;
  title: string;
  workspaceRoot?: string;
  defaultModelSelection?: ModelSelection | null;
  projectIcon?: ProjectIcon | null;
  /** A favicon file in the workspace the desktop picked; fetched through assets.createUrl. */
  faviconPath?: string | null;
  pinnedAt?: string | null;
  archivedAt?: string | null;
  createdAt?: string;
  updatedAt?: string;
  scripts?: ProjectScript[];
}

export interface ThreadShell {
  id: string;
  /** Client-side: the computer this thread runs on (set when the shell stream delivers it). */
  environmentId?: string;
  projectId: string;
  title: string;
  providerInstanceId: string;
  modelSelection?: ModelSelection;
  runtimeMode?: string;
  interactionMode?: string;
  branch?: string | null;
  worktreePath?: string | null;
  activeRunId?: string | null;
  activityRunStatus?: string | null;
  latestRunId?: string | null;
  status: string;
  lastError?: string | null;
  pendingRuntimeRequest?: PendingRuntimeRequestSummary | null;
  latestVisibleMessage?: LatestVisibleMessageSummary | null;
  latestUserMessageAt?: string | null;
  hasActionableProposedPlan?: boolean;
  itemCount?: number;
  createdAt: string;
  updatedAt: string;
  archivedAt?: string | null;
  settledOverride?: string | null;
  settledAt?: string | null;
  unsettledAt?: string | null;
  snoozedUntil?: string | null;
  pinnedAt?: string | null;
  lastVisitedAt?: string | null;
  /** When the latest run ended (the desktop compares it with lastVisitedAt for "unread"). */
  latestRunCompletedAt?: string | null;
  deletedAt?: string | null;
  lineage?: ThreadLineage;
  delegatedFrom?: DelegatedFrom | null;
}

export interface ThreadLineage {
  parentThreadId?: string | null;
  relationshipToParent?: string | null;
  rootThreadId?: string | null;
  /** A side chat opened from its parent; the desktop shows it inside the parent, not in the sidebar. */
  sideChat?: boolean | null;
}

/** A thread another computer handed to this one (delegate_task); its parent lives over there. */
export interface DelegatedFrom {
  environmentId: string;
  threadId: string;
  title?: string;
}

export interface ShellSnapshot {
  schemaVersion?: number;
  snapshotSequence: number;
  threads: ThreadShell[];
  archivedThreads?: ThreadShell[];
  projects: ProjectShell[];
}

export interface ShellStreamItem {
  kind: string;
  sequence?: number;
  snapshot?: ShellSnapshot;
  resolvedRepositoryIdentityRoots?: string[];
  project?: ProjectShell;
  projectId?: string;
  thread?: ThreadShell;
  threadId?: string;
  location?: string;
}

export interface ConversationMessage {
  id: string;
  threadId: string;
  runId?: string | null;
  role: string;
  text: string;
  streaming?: boolean;
  attachments?: ChatAttachment[];
  createdAt: string;
  updatedAt: string;
}

export interface ApprovalOption {
  decision: string;
  label: string;
  warning?: string;
}

export interface UserInputQuestionOption {
  label: string;
  description: string;
  value?: string;
}

export interface UserInputQuestion {
  id: string;
  header: string;
  question: string;
  options: UserInputQuestionOption[];
  multiSelect?: boolean;
  allowCustomAnswer?: boolean;
}

export interface NativeItemRef {
  driver?: string;
  nativeId?: string;
}

/** Union of every turn item variant; `type` selects which optional fields are set. */
/** A file sent with a message (ChatImageAttachment / ChatFileAttachment); `id` is the uploaded attachment id. */
export interface ChatAttachment {
  type: string; // image | file
  id: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
}

export interface TurnItem {
  id: string;
  threadId: string;
  /** user_message: files sent with it. */
  attachments?: ChatAttachment[];
  runId?: string | null;
  parentItemId?: string | null;
  ordinal: number;
  status?: string;
  title?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  updatedAt?: string;
  type: string;
  messageId?: string;
  text?: string;
  streaming?: boolean;
  toolName?: string;
  input?: string | Object;
  output?: string;
  outputOmitted?: boolean;
  exitCode?: number;
  fileName?: string;
  additions?: number;
  deletions?: number;
  requestId?: string;
  requestKind?: string;
  prompt?: string;
  reason?: string;
  appName?: string;
  options?: ApprovalOption[];
  questions?: UserInputQuestion[];
  message?: string;
  query?: string;
}

export interface ProjectedTurnItem {
  position: number;
  visibility: string;
  sourceThreadId: string;
  sourceItemId: string;
  item: TurnItem;
}

export interface RuntimeRequest {
  id: string;
  nodeId?: string;
  kind: string;
  status: string;
  createdAt: string;
  resolvedAt?: string | null;
  decision?: string;
}

/**
 * What the agent suggests saying next, for one run (orchestration.subscribePromptSuggestion; the
 * server produces these when "prompt suggestions" is on in the desktop's Labs settings).
 */
export interface PromptSuggestion {
  runId: string;
  text: string;
}

export interface RunRecord {
  id: string;
  ordinal: number;
  status: string;
  requestedAt?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
}

export interface AppThread {
  id: string;
  projectId: string;
  title: string;
  providerInstanceId: string;
  modelSelection?: ModelSelection;
  runtimeMode?: string;
  interactionMode?: string;
  branch?: string | null;
  worktreePath?: string | null;
}

export interface ThreadProjection {
  thread: AppThread;
  runs: RunRecord[];
  runtimeRequests: RuntimeRequest[];
  messages: ConversationMessage[];
  turnItems: TurnItem[];
  visibleTurnItems?: ProjectedTurnItem[];
  updatedAt?: string;
}

export interface ThreadDetailSnapshot {
  snapshotSequence: number;
  projection: ThreadProjection;
  hasMoreHistory?: boolean;
}

export interface DomainEvent {
  id?: string;
  type: string;
  threadId?: string;
  runId?: string;
  occurredAt?: string;
  payload?: Object;
}

export interface ThreadStreamItem {
  kind: string;
  snapshotSequence?: number;
  projection?: ThreadProjection;
  sequence?: number;
  event?: DomainEvent;
}

export interface EnvironmentPlatform {
  os?: string;
  arch?: string;
}

export interface ExecutionEnvironmentDescriptor {
  environmentId: string;
  label: string;
  platform?: EnvironmentPlatform;
  serverVersion?: string;
  orchestrationProtocolVersion?: number;
  /** What this server can do; voice uses `voiceTranscription` and `cloudVoiceTranscription`. */
  capabilities?: Record<string, boolean>;
}

export interface AccessTokenResult {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope: string;
}

export interface WebSocketTicketResult {
  ticket: string;
  expiresAt: string;
}

export interface ProviderOptionChoice {
  id: string;
  label: string;
  description?: string;
  isDefault?: boolean;
}

/** A model setting the provider exposes: reasoning effort, fast mode, thinking… */
export interface ProviderOptionDescriptor {
  id: string;
  label: string;
  description?: string;
  /** 'select' | 'boolean' */
  type: string;
  options?: ProviderOptionChoice[];
  currentValue?: string | boolean;
  role?: string;
}

export interface ModelCapabilities {
  optionDescriptors?: ProviderOptionDescriptor[];
}

export interface ProviderModelInfo {
  slug?: string;
  name?: string;
  shortName?: string;
  isDefault?: boolean;
  isLegacy?: boolean;
  badge?: string;
  capabilities?: ModelCapabilities | null;
}

export interface ProviderAuthInfo {
  status?: string;
  label?: string;
  email?: string;
}

export interface ProviderStatus {
  instanceId?: string;
  driver?: string;
  displayName?: string;
  enabled?: boolean;
  status?: string;
  models?: ProviderModelInfo[];
  auth?: ProviderAuthInfo;
  usageLimits?: ProviderUsageLimits;
}

export interface ServerConfig {
  environment?: ExecutionEnvironmentDescriptor;
  hostname?: string;
  providers?: ProviderStatus[];
}

/** One persisted pairing with a T3 server. */
export class SavedEnvironment {
  id: string = '';
  label: string = '';
  baseUrl: string = '';
  accessToken: string = '';
  serverVersion: string = '';
  os: string = '';
  pairedAt: string = '';
  /** 'direct' (pairing link over LAN / Tailscale) or 'connect' (T3 Connect tunnel via the relay). */
  kind?: string;
  /** T3 Connect only: the tunnel's WebSocket origin. Direct environments derive it from baseUrl. */
  wsBaseUrl?: string;
  /** 'Bearer' for pairing tokens, 'DPoP' for T3 Connect tokens bound to this device's key. */
  tokenType?: string;
  /** Epoch ms after which a T3 Connect token must be renewed through the relay; 0 = no expiry. */
  tokenExpiresAt?: number;
}

/** A computer linked to the signed-in T3 account, as listed by the relay. */
export class CloudComputer {
  environmentId: string = '';
  label: string = '';
  httpBaseUrl: string = '';
  wsBaseUrl: string = '';
  linkedAt: string = '';
}
