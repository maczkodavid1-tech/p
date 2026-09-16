proc orchestratorStateName(state: OrchestratorState): string =
  case state
  of osPerceive: "perceive"
  of osDeliberate: "deliberate"
  of osAct: "act"
  of osValidate: "validate"
  of osReflect: "reflect"
  of osConsolidate: "consolidate"
  of osTerminal: "terminal"

proc parseOrchestratorState(value: string): OrchestratorState =
  case value.strip().toLowerAscii()
  of "perceive": osPerceive
  of "deliberate": osDeliberate
  of "act": osAct
  of "validate": osValidate
  of "reflect": osReflect
  of "consolidate": osConsolidate
  of "terminal": osTerminal
  else: osPerceive

proc buildOrchestratorGraph(): OrchestratorGraph =
  result.edges = initTable[OrchestratorState, HashSet[OrchestratorState]]()
  for state in OrchestratorState:
    result.edges[state] = initHashSet[OrchestratorState]()
  result.edges[osPerceive].incl(osDeliberate)
  result.edges[osDeliberate].incl(osAct)
  result.edges[osDeliberate].incl(osValidate)
  result.edges[osAct].incl(osValidate)
  result.edges[osAct].incl(osReflect)
  result.edges[osValidate].incl(osPerceive)
  result.edges[osValidate].incl(osAct)
  result.edges[osValidate].incl(osReflect)
  result.edges[osValidate].incl(osConsolidate)
  result.edges[osValidate].incl(osTerminal)
  result.edges[osReflect].incl(osConsolidate)
  result.edges[osConsolidate].incl(osPerceive)
  result.edges[osConsolidate].incl(osTerminal)
  result.edges[osTerminal].incl(osTerminal)
  result.edges[osTerminal].incl(osPerceive)

proc canOrchestratorTransition(graph: OrchestratorGraph, fromState, toState: OrchestratorState): bool =
  if fromState == toState:
    return true
  if not graph.edges.hasKey(fromState):
    return false
  toState in graph.edges[fromState]

proc newStateTransitionEngine(): StateTransitionEngine =
  StateTransitionEngine(graph: buildOrchestratorGraph(), maxRetries: 3)

var transitionEngine: StateTransitionEngine

proc modelRoleName(role: ModelRole): string =
  case role
  of mrOrchestrator: "orchestrator"
  of mrGpt6Astra: "gpt6_astra"
  of mrGlm52: "glm52"
  of mrGemini38: "gemini38"
  of mrMiniMaxM3: "minimax_m3"
  of mrGrok43: "grok43"

proc parseModelRole(s: string): ModelRole =
  case s.strip().toLowerAscii()
  of "orchestrator": mrOrchestrator
  of "gpt6_astra", "gpt-6-astra", "gpt6", "gpt_6_astra": mrGpt6Astra
  of "glm52", "glm_5_2", "glm-5.2": mrGlm52
  of "gemini38", "gemini_3_8", "gemini-3.8": mrGemini38
  of "minimax_m3", "minimax-m3", "minimax": mrMiniMaxM3
  of "grok43", "grok_4_3", "grok-4.3": mrGrok43
  else: raise newException(ValueError, "unknown model role: " & s)

proc providerName(p: ProviderKind): string =
  case p
  of pkRequesty: "requesty"
  of pkCerebras: "cerebras"
  of pkGemini: "gemini"
  of pkFlyMyAi: "flymyai"

proc modelSpec(role: ModelRole): ModelSpec =
  case role
  of mrOrchestrator:
    ModelSpec(role: role, provider: pkCerebras, model: CerebrasGemma4Model, multimodal: false, structured: true)
  of mrGpt6Astra:
    ModelSpec(role: role, provider: pkRequesty, model: Gpt6AstraModel, multimodal: true, structured: true)
  of mrGlm52:
    ModelSpec(role: role, provider: pkRequesty, model: Glm52Model, multimodal: false, structured: false)
  of mrGemini38:
    ModelSpec(role: role, provider: pkGemini, model: Gemini38Model, multimodal: true, structured: true)
  of mrMiniMaxM3:
    ModelSpec(role: role, provider: pkRequesty, model: MiniMaxM3Model, multimodal: false, structured: false)
  of mrGrok43:
    ModelSpec(role: role, provider: pkRequesty, model: Grok43Model, multimodal: true, structured: false)

proc yamlScalar(value: string): string =
  let v = value.strip()
  if v.len >= 2 and ((v[0] == '"' and v[^1] == '"') or (v[0] == '\'' and v[^1] == '\'')):
    return v[1 .. ^2]
  v

proc loadPromptRegistry(path: string): OrderedTable[string, string] =
  if not fileExists(path):
    raise newException(IOError, "prompt configuration file does not exist: " & path)
  var prompts = initOrderedTable[string, string]()
  let raw = readFile(path)
  let header = ": |"
  var cursor = 0
  while true:
    let marker = raw.find(header, cursor)
    if marker < 0:
      break
    var keyStart = marker - 1
    while keyStart >= 0 and (raw[keyStart].isAlphaNumeric or raw[keyStart] == '_'):
      dec keyStart
    inc keyStart
    let key = raw[keyStart ..< marker].strip()
    if key.len == 0:
      raise newException(ValueError, "invalid prompt YAML header")
    let bodyStart = marker + header.len
    let nextMarker = raw.find(header, bodyStart)
    let bodyEnd = if nextMarker < 0: raw.len else: nextMarker
    var promptLines: seq[string] = @[]
    for line in raw[bodyStart ..< bodyEnd].splitLines():
      if line.len >= 2 and line[0] == ' ' and line[1] == ' ':
        promptLines.add(line[2 .. ^1])
      else:
        promptLines.add(line)
    let value = promptLines.join("\n").strip(chars = {' ', '\t', '\n', '\r'})
    if value.len == 0:
      raise newException(ValueError, "empty prompt: " & key)
    if prompts.hasKey(key):
      raise newException(ValueError, "duplicate prompt key: " & key)
    prompts[key] = value
    if nextMarker < 0:
      break
    cursor = nextMarker
  if prompts.len == 0:
    raise newException(ValueError, "prompt configuration is empty: " & path)
  result = prompts

proc promptText(key: string): string =
  if not promptRegistry.hasKey(key):
    raise newException(ValueError, "missing configured prompt: " & key)
  promptRegistry[key]

proc parseSkillFrontMatter(content, path: string): ReferenceSkill =
  let lines = content.splitLines()
  if lines.len < 3 or lines[0].strip() != "---":
    raise newException(ValueError, "SKILL.md is missing YAML front matter: " & path)
  var fields = initTable[string, string]()
  var i = 1
  var closing = -1
  while i < lines.len:
    if lines[i].strip() == "---":
      closing = i
      break
    let raw = lines[i]
    if raw.strip().len == 0:
      inc i
      continue
    if raw[0] in {' ', '\t'}:
      raise newException(ValueError, "unexpected indentation in SKILL.md front matter: " & path)
    let colon = raw.find(':')
    if colon <= 0:
      raise newException(ValueError, "invalid SKILL.md front matter line: " & raw)
    let field = raw[0 ..< colon].strip()
    let tail = raw[colon + 1 .. ^1].strip()
    if tail in [">", ">-", ">+", "|", "|-", "|+"]:
      let folded = tail[0] == '>'
      inc i
      var chunks: seq[string] = @[]
      while i < lines.len and lines[i].strip() != "---" and (lines[i].len == 0 or lines[i][0] in {' ', '\t'}):
        let line = lines[i]
        var value = line
        if value.len >= 2 and value[0] == ' ' and value[1] == ' ':
          value = value[2 .. ^1]
        else:
          value = value.strip()
        chunks.add(value)
        inc i
      fields[field] = if folded: chunks.join(" ").splitWhitespace().join(" ") else: chunks.join("\n").strip()
      continue
    fields[field] = yamlScalar(tail)
    inc i
  if closing < 0:
    raise newException(ValueError, "SKILL.md front matter is not closed: " & path)
  let name = fields.getOrDefault("name", "").strip()
  let description = fields.getOrDefault("description", "").strip()
  if name.len == 0 or description.len == 0:
    raise newException(ValueError, "SKILL.md requires name and description: " & path)
  result = ReferenceSkill(name: name, description: description, path: path, content: content)

proc loadReferenceSkills(root: string): OrderedTable[string, ReferenceSkill] =
  if not dirExists(root):
    raise newException(IOError, "reference skill directory does not exist: " & root)
  result = initOrderedTable[string, ReferenceSkill]()
  var paths: seq[string] = @[]
  for path in walkDirRec(root):
    let parts = splitFile(path)
    if parts.name == "SKILL" and parts.ext.toLowerAscii() == ".md":
      paths.add(path)
  paths.sort()
  for path in paths:
    let skill = parseSkillFrontMatter(readFile(path), path)
    if result.hasKey(skill.name):
      raise newException(ValueError, "duplicate reference skill name: " & skill.name)
    result[skill.name] = skill
  if result.len == 0:
    raise newException(ValueError, "no SKILL.md files found under: " & root)

proc referenceSkillCatalog(): string =
  var parts: seq[string] = @[]
  for name, skill in referenceSkills.pairs:
    parts.add("REFERENCE SKILL: " & name & "\nSOURCE: " & skill.path & "\n" & skill.content)
  parts.join("\n\n")

proc configuredModelRoleNames(): seq[string] =
  @[modelRoleName(mrGpt6Astra), modelRoleName(mrGlm52), modelRoleName(mrGemini38), modelRoleName(mrMiniMaxM3), modelRoleName(mrGrok43)]

proc configuredSubAgentModelRoleNames(): seq[string] =
  @[modelRoleName(mrOrchestrator), modelRoleName(mrGpt6Astra), modelRoleName(mrGlm52), modelRoleName(mrGemini38), modelRoleName(mrMiniMaxM3), modelRoleName(mrGrok43)]

proc normalizePlanStep(step: JsonNode, index: int): JsonNode =
  if step.isNil or step.kind != JObject:
    raise newException(ValueError, "plan step must be an object")
  result = copy(step)
  let rawModel = result{"model"}.getStr("").strip()
  if rawModel.len == 0:
    raise newException(ValueError, "plan step model is required because the orchestrator must choose it explicitly")
  let role = parseModelRole(rawModel)
  if role == mrOrchestrator:
    raise newException(ValueError, "orchestrator cannot be used as a specialist plan model")
  result["model"] = %modelRoleName(role)
  if result{"id"}.getStr("").strip().len == 0:
    result["id"] = %("step-" & $(index + 1))
  if result{"goal"}.getStr("").strip().len == 0:
    raise newException(ValueError, "plan step goal is required")
  if not result.hasKey("execution_mode") or result["execution_mode"].kind != JString or result["execution_mode"].getStr("").strip().len == 0:
    raise newException(ValueError, "plan step execution_mode is required because the orchestrator must choose it explicitly")
  if result["execution_mode"].getStr("") notin ["reason", "vm", "browser", "desktop", "visual", "document", "subagent", "image"]:
    raise newException(ValueError, "invalid execution_mode in plan step: " & result["execution_mode"].getStr(""))
  if result["execution_mode"].getStr("") == "image":
    let imagePolicy = result{"image_policy"}.getStr("").strip().toLowerAscii()
    let requiredDirector = if imagePolicy == "adult": modelRoleName(mrGrok43) else: modelRoleName(mrGemini38)
    if imagePolicy notin ["safe", "adult"]:
      raise newException(ValueError, "image plan step requires image_policy safe or adult")
    if modelRoleName(role) != requiredDirector:
      raise newException(ValueError, "image plan step with image_policy " & imagePolicy & " must use model " & requiredDirector)
    result["image_policy"] = %imagePolicy
  if result.hasKey("depends_on"):
    if result["depends_on"].kind != JArray:
      raise newException(ValueError, "plan step depends_on must be an array")
    for dependency in result["depends_on"].elems:
      if dependency.kind != JString or dependency.getStr("").strip().len == 0:
        raise newException(ValueError, "plan step dependencies must be non-empty strings")
  else:
    result["depends_on"] = newJArray()
  if result.hasKey("status"):
    if result["status"].kind != JString or result["status"].getStr("").strip().toLowerAscii() != "pending":
      raise newException(ValueError, "new plan step status must be pending")
  result["status"] = %"pending"

proc parseJsonObjectLoose(s: string): JsonNode =
  let t = s.strip()
  if t.len == 0:
    return nil
  try:
    let j = parseJson(t)
    if j.kind == JObject:
      return j
  except CatchableError:
    discard
  var start = t.find('{')
  while start >= 0:
    var depth = 0
    var inString = false
    var escaped = false
    for i in start ..< t.len:
      let ch = t[i]
      if inString:
        if escaped:
          escaped = false
        elif ch == '\\':
          escaped = true
        elif ch == '"':
          inString = false
      else:
        if ch == '"':
          inString = true
        elif ch == '{':
          inc depth
        elif ch == '}':
          dec depth
          if depth == 0:
            try:
              let j = parseJson(t[start .. i])
              if j.kind == JObject:
                return j
            except CatchableError:
              break
    let next = t.find('{', start + 1)
    if next < 0:
      break
    start = next
  nil

proc copyOrEmpty(n: JsonNode): JsonNode =
  if n.isNil: newJObject() else: copy(n)

proc jsonArrayStrings(n: JsonNode): seq[string] =
  result = @[]
  if n.isNil or n.kind != JArray:
    return
  for it in n.elems:
    if it.kind == JString:
      result.add(it.getStr())

proc httpRequestAsync(url: string, meth: HttpMethod, body = "", headers: HttpHeaders = nil): Future[(int, string, HttpHeaders)] {.async.} =
  let maxRedirects = positiveEnvInt("OUTBOUND_HTTP_MAX_REDIRECTS", 5)
  let timeoutMs = positiveEnvInt("OUTBOUND_HTTP_TIMEOUT_MS", 60000)
  let maxBytes = positiveEnvInt("OUTBOUND_HTTP_MAX_BYTES", 32 * 1024 * 1024)
  var currentUrl = url
  var currentMethod = meth
  var currentBody = body
  for redirectIndex in 0 .. maxRedirects:
    discard validateOutboundUrl(currentUrl)
    var client = newAsyncHttpClient(maxRedirects = 0)
    client.timeout = timeoutMs
    if headers != nil:
      client.headers = headers
    try:
      let resp = await client.request(currentUrl, httpMethod = currentMethod, body = currentBody)
      let status = resp.code.int
      if status in [301, 302, 303, 307, 308] and resp.headers.hasKey("Location"):
        if redirectIndex >= maxRedirects:
          raise newException(IOError, "too many HTTP redirects")
        let location = resp.headers["Location"]
        let nextUri = combine(parseUri(currentUrl), parseUri(location))
        let nextUrl = $nextUri
        discard validateOutboundUrl(nextUrl)
        if status == 303 or ((status == 301 or status == 302) and currentMethod == HttpPost):
          currentMethod = HttpGet
          currentBody = ""
        currentUrl = nextUrl
        continue
      let bounded = await readBoundedBody(resp, maxBytes)
      if bounded[1]:
        raise newException(IOError, "upstream response exceeded configured size limit")
      return (status, bounded[0], resp.headers)
    finally:
      client.close()
  raise newException(IOError, "HTTP redirect processing failed")

proc requireEnv(name: string): string =
  result = getEnv(name, "").strip()
  if result.len == 0:
    raise newException(IOError, name & " is not configured")

proc openAiContent(msg: JsonNode): string =
  if msg.isNil or msg.kind != JObject:
    return ""
  let c = msg{"content"}
  if c.isNil:
    return ""
  case c.kind
  of JString:
    return c.getStr()
  of JArray:
    var parts: seq[string] = @[]
    for it in c.elems:
      if it.kind == JObject:
        let t = it{"text"}.getStr(it{"content"}.getStr(""))
        if t.len > 0:
          parts.add(t)
    return parts.join("")
  else:
    return ""

proc streamText(node: JsonNode): string =
  if node.isNil:
    return ""
  case node.kind
  of JString:
    return node.getStr("")
  of JArray:
    var parts: seq[string] = @[]
    for item in node.elems:
      if item.kind == JString:
        parts.add(item.getStr(""))
      elif item.kind == JObject:
        let text = item{"text"}.getStr(item{"content"}.getStr(""))
        if text.len > 0:
          parts.add(text)
    return parts.join("")
  of JObject:
    return node{"text"}.getStr(node{"content"}.getStr(""))
  else:
    return ""

proc requestyBody(role: ModelRole, messages: JsonNode, structured = false, stream = false): JsonNode =
  let spec = modelSpec(role)
  result = %*{"model": spec.model, "messages": messages}
  case role
  of mrGpt6Astra:
    result["reasoning_effort"] = %"max"
    result["reasoning"] = %*{"effort": "max", "mode": "pro"}
    result["requesty"] = %*{"auto_cache": true}
  of mrGlm52:
    result["temperature"] = %0
    result["max_tokens"] = %131072
    result["reasoning_effort"] = %"max"
  of mrMiniMaxM3:
    result["temperature"] = %0
    result["max_tokens"] = %131072
    result["thinking"] = %*{"type": "adaptive"}
  of mrGrok43:
    result["reasoning_effort"] = %"high"
    result["requesty"] = %*{"auto_cache": true}
  else:
    discard
  if structured:
    result["response_format"] = %*{"type": "json_object"}
  if stream:
    result["stream"] = %true
    result["stream_options"] = %*{"include_usage": true}

proc parseOpenAiResponse(raw: string, provider: ProviderKind): LlmResponse =
  let j = parseJson(raw)
  result = LlmResponse(provider: provider, raw: j, logprobs: @[])
  result.model = j{"model"}.getStr("")
  result.usage = if j.hasKey("usage") and j["usage"].kind == JObject: copy(j["usage"]) else: newJObject()
  if result.usage.kind == JObject and result.usage.len > 0:
    result.promptTokens = result.usage{"prompt_tokens"}.getInt(result.usage{"input_tokens"}.getInt(0))
    result.completionTokens = result.usage{"completion_tokens"}.getInt(result.usage{"output_tokens"}.getInt(0))
    result.totalTokens = result.usage{"total_tokens"}.getInt(0)
    if result.totalTokens == 0 and (result.promptTokens > 0 or result.completionTokens > 0):
      result.totalTokens = result.promptTokens + result.completionTokens
  if j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].elems.len > 0:
    let ch = j["choices"][0]
    result.finishReason = ch{"finish_reason"}.getStr("")
    let msg = ch{"message"}
    result.content = openAiContent(msg)
    result.reasoningContent = msg{"reasoning_content"}.getStr(msg{"reasoning"}.getStr(""))
    if ch.hasKey("logprobs") and ch["logprobs"].kind == JObject and ch["logprobs"].hasKey("content") and ch["logprobs"]["content"].kind == JArray:
      for item in ch["logprobs"]["content"].elems:
        if item.kind != JObject:
          continue
        var tops: seq[TopLogprobItem] = @[]
        if item.hasKey("top_logprobs") and item["top_logprobs"].kind == JArray:
          for candidate in item["top_logprobs"].elems:
            if candidate.kind == JObject:
              tops.add(TopLogprobItem(token: candidate{"token"}.getStr(""), logprob: candidate{"logprob"}.getFloat(-99.0)))
        result.logprobs.add(LogprobItem(token: item{"token"}.getStr(""), logprob: item{"logprob"}.getFloat(-99.0), textOffset: item{"text_offset"}.getInt(-1), topLogprobs: tops))

proc requestyCall(role: ModelRole, messages: JsonNode, structured = false): Future[LlmResponse] {.async.} =
  let key = requireEnv("REQUESTY_API_KEY")
  let body = requestyBody(role, messages, structured, false)
  let headers = newHttpHeaders({
    "Authorization": "Bearer " & key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  let (status, raw, _) = await httpRequestAsync(RequestyBaseUrl & "/chat/completions", HttpPost, $body, headers)
  if status < 200 or status >= 300:
    raise newException(IOError, "Requesty status " & $status & ": " & raw)
  return parseOpenAiResponse(raw, pkRequesty)

proc resolveCerebrasGemma4(): Future[string] {.async.} =
  if CerebrasGemma4Model.len > 0:
    return CerebrasGemma4Model
  let explicit = getEnv("CEREBRAS_GEMMA4_MODEL", "").strip()
  if explicit.len > 0:
    CerebrasGemma4Model = explicit
    return explicit
  let key = requireEnv("CEREBRAS_API_KEY")
  let headers = newHttpHeaders({
    "Authorization": "Bearer " & key,
    "Accept": "application/json"
  })
  let (status, raw, _) = await httpRequestAsync(CerebrasBaseUrl & "/models", HttpGet, "", headers)
  if status < 200 or status >= 300:
    raise newException(IOError, "Cerebras models status " & $status & ": " & raw)
  let j = parseJson(raw)
  if not j.hasKey("data") or j["data"].kind != JArray:
    raise newException(IOError, "Cerebras model catalog has no data array")
  for it in j["data"].elems:
    if it.kind != JObject:
      continue
    let id = it{"id"}.getStr("")
    let hay = (id & " " & it{"name"}.getStr("") & " " & it{"description"}.getStr("")).toLowerAscii()
    if "gemma" in hay and ("4" in hay or "four" in hay):
      CerebrasGemma4Model = id
      return id
  raise newException(IOError, "Gemma 4 model is not available in the Cerebras model catalog")

proc cerebrasCall(messages: JsonNode, structured = true): Future[LlmResponse] {.async.} =
  let key = requireEnv("CEREBRAS_API_KEY")
  let model = await resolveCerebrasGemma4()
  var body = %*{
    "model": model,
    "messages": messages,
    "reasoning_effort": "high"
  }
  if structured:
    body["response_format"] = %*{"type": "json_object"}
  let headers = newHttpHeaders({
    "Authorization": "Bearer " & key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  let (status, raw, _) = await httpRequestAsync(CerebrasBaseUrl & "/chat/completions", HttpPost, $body, headers)
  if status < 200 or status >= 300:
    raise newException(IOError, "Cerebras status " & $status & ": " & raw)
  return parseOpenAiResponse(raw, pkCerebras)

proc extractGeminiOutput(j: JsonNode): string =
  var parts: seq[string] = @[]
  if j.hasKey("output_text") and j["output_text"].kind == JString:
    parts.add(j["output_text"].getStr())
  if j.hasKey("steps") and j["steps"].kind == JArray:
    for step in j["steps"].elems:
      if step.kind != JObject or step{"type"}.getStr("") != "model_output":
        continue
      let content = step{"content"}
      if content.kind == JArray:
        for contentBlock in content.elems:
          if contentBlock.kind == JObject and contentBlock{"type"}.getStr("") == "text":
            let text = contentBlock{"text"}.getStr("")
            if text.len > 0:
              parts.add(text)
  result = parts.join("")

proc geminiCall(input: JsonNode, systemInstruction = ""): Future[LlmResponse] {.async.} =
  let key = requireEnv("GEMINI_API_KEY")
  var body = %*{
    "model": Gemini38Model,
    "input": input,
    "tools": [
      {"type": "code_execution"},
      {"type": "google_search"},
      {"type": "url_context"}
    ],
    "generation_config": {
      "max_output_tokens": 65536,
      "thinking_level": "high"
    }
  }
  if systemInstruction.len > 0:
    body["system_instruction"] = %systemInstruction
  let headers = newHttpHeaders({
    "x-goog-api-key": key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  let (status, raw, _) = await httpRequestAsync(GeminiBaseUrl & "/interactions", HttpPost, $body, headers)
  if status < 200 or status >= 300:
    raise newException(IOError, "Gemini status " & $status & ": " & raw)
  let j = parseJson(raw)
  var usage = newJObject()
  if j.hasKey("usage") and j["usage"].kind == JObject:
    usage = copy(j["usage"])
  elif j.hasKey("usageMetadata") and j["usageMetadata"].kind == JObject:
    usage = copy(j["usageMetadata"])
  let promptTokens = usage{"prompt_tokens"}.getInt(usage{"input_tokens"}.getInt(usage{"promptTokenCount"}.getInt(usage{"inputTokenCount"}.getInt(0))))
  let completionTokens = usage{"completion_tokens"}.getInt(usage{"output_tokens"}.getInt(usage{"candidatesTokenCount"}.getInt(usage{"outputTokenCount"}.getInt(0))))
  var totalTokens = usage{"total_tokens"}.getInt(usage{"totalTokenCount"}.getInt(0))
  if totalTokens == 0 and (promptTokens > 0 or completionTokens > 0):
    totalTokens = promptTokens + completionTokens
  if usage.kind == JObject and usage.len > 0:
    usage["prompt_tokens"] = %promptTokens
    usage["completion_tokens"] = %completionTokens
    usage["total_tokens"] = %totalTokens
  return LlmResponse(content: extractGeminiOutput(j), raw: j, usage: usage, model: Gemini38Model, provider: pkGemini, finishReason: j{"status"}.getStr(""), promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens, logprobs: @[])

proc addGeminiMediaPart(input: JsonNode, kind, value, mimeType: string) =
  if input.isNil or input.kind != JArray or value.len == 0:
    return
  if value.startsWith("data:"):
    let comma = value.find(',')
    if comma > 5:
      let header = value[5 ..< comma]
      let payload = if comma + 1 < value.len: value[comma + 1 .. ^1] else: ""
      let semi = header.find(';')
      let actualMime = if semi >= 0: header[0 ..< semi] else: header
      input.add(%*{"type": kind, "mime_type": (if actualMime.len > 0: actualMime else: mimeType), "data": payload})
      return
  if value.startsWith("http://") or value.startsWith("https://") or value.startsWith("gs://"):
    input.add(%*{"type": kind, "uri": value})
  else:
    input.add(%*{"type": kind, "mime_type": mimeType, "data": value})

proc geminiInputFromMessages(messages: JsonNode): JsonNode =
  result = newJArray()
  if messages.isNil or messages.kind != JArray:
    return
  for m in messages.elems:
    if m.kind != JObject:
      continue
    let roleName = m{"role"}.getStr("user")
    if roleName == "system":
      continue
    let content = m{"content"}
    var contentParts = newJArray()
    if content.kind == JString:
      contentParts.add(%*{"type": "text", "text": content.getStr()})
    elif content.kind == JArray:
      for part in content.elems:
        if part.kind != JObject:
          continue
        let typ = part{"type"}.getStr("")
        case typ
        of "text", "input_text":
          let text = part{"text"}.getStr(part{"content"}.getStr(""))
          if text.len > 0:
            contentParts.add(%*{"type": "text", "text": text})
        of "image_url", "input_image", "image":
          var value = part{"url"}.getStr(part{"uri"}.getStr(part{"data"}.getStr("")))
          if part.hasKey("image_url"):
            if part["image_url"].kind == JObject:
              value = part["image_url"]{"url"}.getStr(value)
            elif part["image_url"].kind == JString:
              value = part["image_url"].getStr()
          addGeminiMediaPart(contentParts, "image", value, part{"mime_type"}.getStr("image/jpeg"))
        of "video_url", "input_video", "video":
          var value = part{"url"}.getStr(part{"uri"}.getStr(part{"data"}.getStr("")))
          if part.hasKey("video_url"):
            if part["video_url"].kind == JObject:
              value = part["video_url"]{"url"}.getStr(value)
            elif part["video_url"].kind == JString:
              value = part["video_url"].getStr()
          addGeminiMediaPart(contentParts, "video", value, part{"mime_type"}.getStr("video/mp4"))
        of "document", "file":
          var value = part{"url"}.getStr(part{"uri"}.getStr(part{"data"}.getStr("")))
          addGeminiMediaPart(contentParts, "document", value, part{"mime_type"}.getStr("application/pdf"))
        else:
          discard
    if contentParts.len > 0:
      let stepType = if roleName == "assistant": "model_output" else: "user_input"
      result.add(%*{"type": stepType, "content": contentParts})

proc geminiSystemInstructionFromMessages(messages: JsonNode): string =
  let specialist = promptText("gemini38")
  var systemMessages: seq[string] = @[]
  var containsSubAgentProtocol = false
  if not messages.isNil and messages.kind == JArray:
    for message in messages.elems:
      if message.kind == JObject and message{"role"}.getStr("") == "system":
        let text = openAiContent(message).strip()
        if text.len > 0:
          systemMessages.add(text)
          if promptText("subagent_core") in text:
            containsSubAgentProtocol = true
  var parts: seq[string] = @[]
  if not containsSubAgentProtocol:
    parts.add(specialist)
  for text in systemMessages:
    if text != specialist or parts.len == 0:
      parts.add(text)
  parts.join("\n\n")

proc findMediaValue(n: JsonNode, preferredKeys: openArray[string]): string =
  if n.isNil:
    return ""
  case n.kind
  of JObject:
    for key in preferredKeys:
      if n.hasKey(key) and n[key].kind == JString and n[key].getStr("").len > 64:
        return n[key].getStr()
    for _, value in n.fields:
      let found = findMediaValue(value, preferredKeys)
      if found.len > 0:
        return found
  of JArray:
    for value in n.elems:
      let found = findMediaValue(value, preferredKeys)
      if found.len > 0:
        return found
  else:
    discard
  ""

proc chargeTokens(tenantId, taskId: string, used: int): bool
proc enforcePromptBound(messages: JsonNode)

proc invokeModel(role: ModelRole, messages: JsonNode, structured = false, tenantId = "", taskId = ""): Future[LlmResponse] {.async.} =
  enforcePromptBound(messages)
  var response: LlmResponse
  case role
  of mrOrchestrator:
    response = await cerebrasCall(messages, true)
  of mrGemini38:
    let input = geminiInputFromMessages(messages)
    response = await geminiCall(input, geminiSystemInstructionFromMessages(messages))
  else:
    response = await requestyCall(role, messages, structured)
  if tenantId.len > 0 and response.totalTokens > 0:
    if not chargeTokens(tenantId, taskId, response.totalTokens):
      raise newException(IOError, "token budget exhausted")
  return response

proc enforcePromptBound(messages: JsonNode) =
  if messages.isNil or messages.kind != JArray:
    raise newException(ValueError, "messages must be an array")
  let maxBytes = positiveEnvInt("AGENT_MAX_PROMPT_BYTES", 2 * 1024 * 1024)
  let encoded = canonical(messages)
  if encoded.len > maxBytes:
    raise newException(ValueError, "prompt exceeds AGENT_MAX_PROMPT_BYTES")

proc effectiveMaxTokens(requested: int, source: string): int =
  let sourceName = source.strip().toLowerAscii()
  let providerMaximum =
    if sourceName in ["gemini", "gemini38", "gemini-3.8-flash", "models/gemini-3.8-flash"]: 65536
    elif sourceName in ["orchestrator", "cerebras", "gemma4", "gemma-4"]: 32768
    else: 131072
  if requested <= 0:
    return providerMaximum
  min(requested, providerMaximum)

proc chargeTokens(tenantId, taskId: string, used: int): bool =
  if used <= 0:
    return true
  acquire(store.lock)
  defer: release(store.lock)
  discard store.execUnlocked("UPDATE tenants SET tokens_used=tokens_used+? WHERE tenant_id=? AND token_budget-tokens_used>=?", @[%used, %tenantId, %used])
  if sqlite3_changes(store.handle) <= 0:
    return false
  if taskId.len > 0:
    discard store.execUnlocked("UPDATE tasks SET tokens_used=tokens_used+?,updated_at=? WHERE task_id=? AND tenant_id=?", @[%used, %nowF(), %taskId, %tenantId])
  true

proc callChatCompletionsAsync(messages: JsonNode, maxTokens: int = 0,
                              temperature: float = 0.96,
                              jsonMode: bool = false,
                              logprobs: bool = false,
                              topLogprobs: int = 20,
                              echoPrompt: bool = false,
                              topP: float = 1.0): Future[LlmResponse] {.async.} =
  enforcePromptBound(messages)
  let key = requireEnv("REQUESTY_API_KEY")
  var body = requestyBody(mrGpt6Astra, messages, jsonMode, false)
  body["max_tokens"] = %effectiveMaxTokens(maxTokens, "gpt6_astra")
  body["temperature"] = %temperature
  body["top_p"] = %topP
  if logprobs:
    body["logprobs"] = %true
    body["top_logprobs"] = %max(1, min(20, topLogprobs))
  if echoPrompt:
    body["echo"] = %true
  let headers = newHttpHeaders({
    "Authorization": "Bearer " & key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  let (status, raw, _) = await httpRequestAsync(RequestyBaseUrl & "/chat/completions", HttpPost, $body, headers)
  if status < 200 or status >= 300:
    raise newException(IOError, "Requesty status " & $status & ": " & raw)
  return parseOpenAiResponse(raw, pkRequesty)

proc extractJsonObject(text: string): JsonNode =
  parseJsonObjectLoose(text)

proc boundUtf8Bytes(s: string, maxBytes: int): string =
  if maxBytes <= 0:
    return ""
  if s.len <= maxBytes:
    return s
  var n = maxBytes
  while n > 0 and n < s.len and (s[n].ord and 0xc0) == 0x80:
    dec n
  if n <= 0:
    return ""
  s[0 ..< n]

proc recursiveReasonCall(tenantId, taskId, goal, context: string, depth, maxDepth, branches: int): Future[JsonNode] {.async.} =
  let requestedDepth = max(1, if maxDepth > 0: maxDepth else: max(1, depth))
  let requestedBranches = max(1, branches)
  let currentDepth = max(0, depth)
  let systemText = promptText("recursive_reason")
  let userText = "Goal:\n" & goal & "\n\nContext:\n" & context & "\n\nReasoning depth index: " & $currentDepth
  let response = await callChatCompletionsAsync(%*[
    {"role": "system", "content": systemText},
    {"role": "user", "content": userText}
  ], maxTokens = 131072, temperature = 0.0, jsonMode = true)
  if response.totalTokens > 0 and not chargeTokens(tenantId, taskId, response.totalTokens):
    raise newException(IOError, "token budget exhausted")
  var parsed = parseJsonObjectLoose(response.content)
  if parsed.isNil:
    parsed = %*{"analysis": response.content, "candidate_actions": newJArray(), "uncertainties": newJArray(), "conclusion": response.content}
  parsed["model"] = %response.model
  parsed["depth"] = %currentDepth
  if currentDepth + 1 < requestedDepth:
    var branchResults = newJArray()
    let candidates = parsed{"candidate_actions"}
    if not candidates.isNil and candidates.kind == JArray and candidates.elems.len > 0:
      let takeCount = min(requestedBranches, candidates.elems.len)
      for i in 0 ..< takeCount:
        let branchContext = context & "\n\nCandidate branch:\n" & canonical(candidates[i])
        branchResults.add(await recursiveReasonCall(tenantId, taskId, goal, branchContext, currentDepth + 1, requestedDepth, requestedBranches))
    elif requestedBranches == 1:
      branchResults.add(await recursiveReasonCall(tenantId, taskId, goal, context, currentDepth + 1, requestedDepth, requestedBranches))
    parsed["branches"] = branchResults
  return parsed

proc topProbMap(item: LogprobItem): Table[string, float] =
  result = initTable[string, float]()
  result[item.token] = exp(item.logprob)
  for candidate in item.topLogprobs:
    let probability = exp(candidate.logprob)
    if probability > result.getOrDefault(candidate.token, 0.0):
      result[candidate.token] = probability

proc tokenReverseKl(teacher, student: LogprobItem): float =
  let tp = topProbMap(teacher)
  let sp = topProbMap(student)
  var keys = initHashSet[string]()
  for key in tp.keys: keys.incl(key)
  for key in sp.keys: keys.incl(key)
  var tNorm = 0.0
  var sNorm = 0.0
  for key in keys:
    tNorm += tp.getOrDefault(key, 0.0)
    sNorm += sp.getOrDefault(key, 0.0)
  if tNorm <= 0.0 or sNorm <= 0.0:
    return 0.0
  let epsilon = 1e-12
  for key in keys:
    let p = max(epsilon, sp.getOrDefault(key, 0.0) / sNorm)
    let q = max(epsilon, tp.getOrDefault(key, 0.0) / tNorm)
    result += p * ln(p / q)

proc findAlignedTokenWindow(teacher, student: seq[LogprobItem]): seq[(int, int)] =
  result = @[]
  if teacher.len == 0 or student.len == 0:
    return
  var ti = 0
  var si = 0
  while ti < teacher.len and si < student.len:
    if teacher[ti].token == student[si].token:
      result.add((ti, si))
      inc ti
      inc si
      continue
    var found = false
    for delta in 1 .. 8:
      if ti + delta < teacher.len and teacher[ti + delta].token == student[si].token:
        ti += delta
        found = true
        break
      if si + delta < student.len and teacher[ti].token == student[si + delta].token:
        si += delta
        found = true
        break
    if not found:
      inc ti
      inc si

proc recordModelContext(h: TaskHandle, role: ModelRole, phase, content: string, metadata: JsonNode = nil)
proc persistReflection(h: TaskHandle, failurePoint, pivotAction, attribution: string, patch, verifier: JsonNode)

proc persistTask(h: TaskHandle)
proc emit(h: TaskHandle, ev: JsonNode)
proc haltForBudget(h: TaskHandle)