proc parseLegacyNumber(part: string, ok: var bool): uint64 =
  if part.len == 0:
    ok = false
    return 0
  var base = 10'u64
  var i = 0
  if part.len > 2 and part[0] == '0' and part[1] in {'x', 'X'}:
    base = 16
    i = 2
  elif part.len > 1 and part[0] == '0':
    base = 8
    i = 1
  if i >= part.len:
    ok = true
    return 0
  var value = 0'u64
  while i < part.len:
    let ch = part[i]
    var d = -1
    if ch in {'0'..'9'}: d = ch.ord - '0'.ord
    elif ch in {'a'..'f'}: d = 10 + ch.ord - 'a'.ord
    elif ch in {'A'..'F'}: d = 10 + ch.ord - 'A'.ord
    if d < 0 or uint64(d) >= base or value > (high(uint32).uint64 - uint64(d)) div base:
      ok = false
      return 0
    value = value * base + uint64(d)
    inc i
  ok = true
  value

proc parseLegacyIpv4(host: string): (bool, array[4, uint8]) =
  let parts = host.split('.')
  if parts.len < 1 or parts.len > 4:
    return (false, default(array[4, uint8]))
  var nums: seq[uint64] = @[]
  for part in parts:
    var ok = false
    let n = parseLegacyNumber(part, ok)
    if not ok:
      return (false, default(array[4, uint8]))
    nums.add(n)
  var value = 0'u64
  case nums.len
  of 1:
    if nums[0] > 0xffffffff'u64: return (false, default(array[4, uint8]))
    value = nums[0]
  of 2:
    if nums[0] > 0xff'u64 or nums[1] > 0xffffff'u64: return (false, default(array[4, uint8]))
    value = (nums[0] shl 24) or nums[1]
  of 3:
    if nums[0] > 0xff'u64 or nums[1] > 0xff'u64 or nums[2] > 0xffff'u64: return (false, default(array[4, uint8]))
    value = (nums[0] shl 24) or (nums[1] shl 16) or nums[2]
  of 4:
    for n in nums:
      if n > 0xff'u64: return (false, default(array[4, uint8]))
    value = (nums[0] shl 24) or (nums[1] shl 16) or (nums[2] shl 8) or nums[3]
  else:
    return (false, default(array[4, uint8]))
  var outv: array[4, uint8]
  outv[0] = uint8((value shr 24) and 0xff)
  outv[1] = uint8((value shr 16) and 0xff)
  outv[2] = uint8((value shr 8) and 0xff)
  outv[3] = uint8(value and 0xff)
  (true, outv)

proc blockedIpv4(a: array[4, uint8]): bool =
  let x = a[0].int
  let y = a[1].int
  if x == 0 or x == 10 or x == 127: return true
  if x == 100 and y >= 64 and y <= 127: return true
  if x == 169 and y == 254: return true
  if x == 172 and y >= 16 and y <= 31: return true
  if x == 192 and y == 168: return true
  if x == 198 and y in [18, 19]: return true
  if x >= 224: return true
  false

proc blockedIp(ip: IpAddress): bool =
  case ip.family
  of IpAddressFamily.IPv4:
    blockedIpv4(ip.address_v4)
  of IpAddressFamily.IPv6:
    let a = ip.address_v6
    var allZero = true
    for b in a:
      if b != 0'u8: allZero = false
    if allZero: return true
    var loopback = true
    for i in 0 ..< 15:
      if a[i] != 0'u8: loopback = false
    if loopback and a[15] == 1'u8: return true
    if (a[0] and 0xfe'u8) == 0xfc'u8: return true
    if a[0] == 0xfe'u8 and (a[1] and 0xc0'u8) == 0x80'u8: return true
    if a[0] == 0xff'u8: return true
    var mapped = true
    for i in 0 ..< 10:
      if a[i] != 0'u8: mapped = false
    if mapped and a[10] == 0xff'u8 and a[11] == 0xff'u8:
      return blockedIpv4([a[12], a[13], a[14], a[15]])
    false

proc validateOutboundHost(hostInput: string) =
  var host = hostInput.toLowerAscii().strip()
  while host.len > 0 and host.endsWith("."):
    host.setLen(host.len - 1)
  if host.len == 0:
    raise newException(ValueError, "URL hostname required")
  if '%' in host or '\0' in host:
    raise newException(ValueError, "invalid URL hostname")
  if host == "localhost" or host.endsWith(".localhost") or host == "metadata.google.internal" or host.endsWith(".metadata.google.internal"):
    raise newException(ValueError, "target blocked")
  let legacy = parseLegacyIpv4(host)
  if legacy[0]:
    if blockedIpv4(legacy[1]):
      raise newException(ValueError, "target blocked")
    return
  if isIpAddress(host):
    if blockedIp(parseIpAddress(host)):
      raise newException(ValueError, "target blocked")
    return
  let resolved = getHostByName(host)
  if resolved.addrList.len == 0:
    raise newException(ValueError, "hostname did not resolve")
  for address in resolved.addrList:
    if not isIpAddress(address):
      raise newException(ValueError, "hostname resolved to an invalid address")
    if blockedIp(parseIpAddress(address)):
      raise newException(ValueError, "hostname resolves to a blocked address")

proc validateOutboundUrl(url: string): Uri =
  if '\r' in url or '\n' in url:
    raise newException(ValueError, "invalid URL")
  let parsed = parseUri(url)
  let scheme = parsed.scheme.toLowerAscii()
  if scheme notin ["http", "https"]:
    raise newException(ValueError, "only http/https allowed")
  if parsed.username.len > 0 or parsed.password.len > 0:
    raise newException(ValueError, "userinfo in URL is not allowed")
  validateOutboundHost(parsed.hostname)
  parsed

proc readBoundedBody(resp: AsyncResponse, maxBytes: int): Future[(string, bool)] {.async.} =
  if maxBytes <= 0:
    raise newException(ValueError, "response body limit must be positive")
  var body = newStringOfCap(min(maxBytes, 8192))
  while true:
    let item = await resp.bodyStream.read()
    if not item[0]:
      break
    let chunk = item[1]
    if chunk.len > maxBytes - body.len:
      return (body, true)
    body.add(chunk)
  return (body, false)

proc responseHeadersJson(headers: HttpHeaders): JsonNode =
  result = newJObject()
  if headers.isNil:
    return
  for key, value in headers:
    result[key] = %value

proc mapHttpMethod(methodName: string): HttpMethod =
  case methodName.toUpperAscii()
  of "GET": HttpGet
  of "POST": HttpPost
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  of "HEAD": HttpHead
  of "PATCH": HttpPatch
  of "OPTIONS": HttpOptions
  else: raise newException(ValueError, "unsupported HTTP method: " & methodName)

type
  ProviderKind = enum
    pkRequesty,
    pkCerebras,
    pkGemini,
    pkFlyMyAi
  ModelRole = enum
    mrOrchestrator,
    mrGpt6Astra,
    mrGlm52,
    mrGemini38,
    mrMiniMaxM3,
    mrGrok43
  OrchestratorState = enum
    osPerceive,
    osDeliberate,
    osAct,
    osValidate,
    osReflect,
    osConsolidate,
    osTerminal
  ImageContentPolicy = enum
    icpSafe,
    icpAdult
  ModelSpec = object
    role: ModelRole
    provider: ProviderKind
    model: string
    multimodal: bool
    structured: bool
  ReferenceSkill = object
    name: string
    description: string
    path: string
    content: string
  TopLogprobItem = object
    token: string
    logprob: float
  LogprobItem = object
    token: string
    logprob: float
    textOffset: int
    topLogprobs: seq[TopLogprobItem]
  LlmResponse = object
    content: string
    reasoningContent: string
    raw: JsonNode
    usage: JsonNode
    model: string
    provider: ProviderKind
    finishReason: string
    promptTokens: int
    completionTokens: int
    totalTokens: int
    logprobs: seq[LogprobItem]
  DirectChatResult = object
    content: string
    reasoningContent: string
    model: string
    usage: JsonNode
    taskId: string
  RouteDecision = object
    raw: JsonNode
    intent: string
    primaryModel: ModelRole
    secondaryModels: seq[ModelRole]
    requiresVm: bool
    requiresBrowser: bool
    requiresDesktop: bool
    requiresVisualAnalysis: bool
    requiresDocumentAnalysis: bool
    requiresImageGeneration: bool
    plan: JsonNode
    delegations: JsonNode
    completionCriteria: JsonNode
  ToolResult = object
    ok: bool
    payload: JsonNode
    receipt: string
    message: string
  OrchestratorGraph = object
    edges: Table[OrchestratorState, HashSet[OrchestratorState]]
  StateTransitionEngine = ref object
    graph: OrchestratorGraph
    maxRetries: int
  ValidationGate = ref object
    epsilon: float
  MetaAgent = ref object
    minOccurrences: int
    lookback: int
    maxCandidates: int
    gate: ValidationGate
  SseClient = ref object
    req: Request
    tenantId: string
    alive: bool
    queue: Deque[string]
    lock: Lock
  TaskHandle = ref object
    taskId: string
    tenantId: string
    title: string
    spec: JsonNode
    sigma: JsonNode
    obs: JsonNode
    stepIndex: int
    maxSteps: int
    status: string
    terminalReason: string
    verified: bool
    paused: bool
    stopRequested: bool
    loopActive: Atomic[bool]
    transitionBusy: bool
    lock: Lock
    orchestratorState: OrchestratorState
    subscribers: seq[tuple[id: string, cb: proc(ev: JsonNode) {.closure.}]]
    cognition: JsonNode
    cognitionAt: float
    allowedTools: HashSet[string]
    broadcastAttached: bool
    lastPlannedDigest: string
  SubAgentHandle = ref object
    agentId: string
    taskId: string
    parentAgentId: string
    name: string
    goal: string
    instructions: string
    modelRole: ModelRole
    context: JsonNode
    messages: JsonNode
    state: JsonNode
    status: string
    resultText: string
    errorText: string
    stopRequested: bool
    loopActive: Atomic[bool]
    lock: Lock
    rootTask: TaskHandle
  FlyMyAiError = object of CatchableError
    status: int
  FlyMyAiFileField = object
    name: string
    filename: string
    mimeType: string
    data: string
  FlyMyAiPrediction = object
    status: int
    model: string
    outputData: JsonNode
    inferenceTime: float
    raw: JsonNode
  ImageReference = object
    source: string
    filename: string
    mimeType: string
    data: string
    bytes: int
  ImageGenerationRequest = object
    prompt: string
    policy: ImageContentPolicy
    size: string
    quality: string
    moderation: string
    watermark: bool
    sequential: string
    optimizePromptMode: string
    name: string
    references: seq[ImageReference]
    directorModel: string
    directorAgentId: string
    stepId: string
    directorEnforced: bool
  ImageGenerationResult = object
    ok: bool
    imageId: string
    model: string
    policy: ImageContentPolicy
    directorModel: string
    payload: JsonNode
    receipt: string
    message: string
    latencyMs: int
  ToolHandler = proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.closure.}
  GcsafeToolHandler = proc(tenant: string, args: JsonNode): Future[ToolResult] {.closure, gcsafe.}
  GcsafeRequestHandler = proc(req: Request): Future[void] {.closure, gcsafe.}
  ToolSpec = object
    name: string
    description: string
    schema: JsonNode
    handler: ToolHandler

var
  toolRegistry {.threadvar.}: OrderedTable[string, ToolSpec]
  promptRegistry {.threadvar.}: OrderedTable[string, string]
  referenceSkills {.threadvar.}: OrderedTable[string, ReferenceSkill]
  activeTasks = initTable[string, TaskHandle]()
  tasksLock: Lock
  sseLock: Lock
  sseSubscribers = initTable[string, seq[tuple[id: string, cb: proc(ev: JsonNode) {.closure.}]]]()
  activeChatJobs = initHashSet[string]()
  chatJobsLock: Lock
  activeSubAgents = initTable[string, SubAgentHandle]()
  subAgentsLock: Lock

