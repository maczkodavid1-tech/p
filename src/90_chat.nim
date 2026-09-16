proc persistChatJobEvent(jobId: string, ev: JsonNode) =
  let eventType = ev{"type"}.getStr("")
  let contentDelta = ev{"content"}.getStr(ev{"delta"}.getStr(""))
  let reasoningDelta = ev{"reasoning_content"}.getStr(ev{"reasoning"}.getStr(""))
  let usage = if ev.hasKey("usage") and ev["usage"].kind == JObject: ev["usage"] else: newJObject()
  var ops: seq[SqlOperation] = @[]
  ops.add(SqlOperation(
    sql: "INSERT INTO chat_job_events (job_id, sequence, event_json, created_at) SELECT ?, COALESCE(MAX(sequence),0)+1, ?, ? FROM chat_job_events WHERE job_id=?",
    params: @[%jobId, %($ev), %nowF(), %jobId]))
  case eventType
  of "started":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET status='running', updated_at=? WHERE job_id=?", params: @[%nowF(), %jobId]))
  of "delta":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET content=content||?, reasoning=reasoning||?, updated_at=? WHERE job_id=?", params: @[%contentDelta, %reasoningDelta, %nowF(), %jobId]))
  of "usage":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET prompt_tokens=?, completion_tokens=?, total_tokens=?, usage_json=?, updated_at=? WHERE job_id=?",
      params: @[%usage{"prompt_tokens"}.getInt(usage{"input_tokens"}.getInt(0)), %usage{"completion_tokens"}.getInt(usage{"output_tokens"}.getInt(0)), %usage{"total_tokens"}.getInt(0), %($usage), %nowF(), %jobId]))
  of "done":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET status='succeeded', model=?, task_id=?, usage_json=?, updated_at=? WHERE job_id=?",
      params: @[%ev{"model"}.getStr(""), %ev{"task_id"}.getStr(""), %($usage), %nowF(), %jobId]))
  of "stopped":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET status='stopped', error='', updated_at=? WHERE job_id=?", params: @[%nowF(), %jobId]))
  of "error":
    ops.add(SqlOperation(sql: "UPDATE chat_jobs SET status='failed', error=?, updated_at=? WHERE job_id=?", params: @[%ev{"message"}.getStr("chat job failed"), %nowF(), %jobId]))
  else:
    discard
  store.execTransaction(ops)

proc chooseSimpleSpecialist(route: RouteDecision): ModelRole = route.primaryModel

proc specialistChatMessages(role: ModelRole, messages: JsonNode): JsonNode =
  result = newJArray()
  result.add(%*{"role": "system", "content": specialistSystem(role)})
  if not messages.isNil and messages.kind == JArray:
    for message in messages.elems:
      result.add(copy(message))

proc routeNeedsExecution(route: RouteDecision): bool =
  if route.delegations.kind == JArray and route.delegations.elems.len > 0:
    return true
  if route.plan.kind == JArray and route.plan.elems.len > 0:
    return true
  route.requiresVm or route.requiresBrowser or route.requiresDesktop or route.requiresDocumentAnalysis or route.requiresVisualAnalysis

proc routingGoal(messages: JsonNode): string =
  var parts: seq[string] = @[]
  if messages.isNil or messages.kind != JArray:
    return ""
  for msg in messages.elems:
    if msg.kind != JObject:
      continue
    let text = openAiContent(msg)
    if text.len > 0:
      parts.add(msg{"role"}.getStr("user") & ": " & text)
    let content = msg{"content"}
    if content.kind == JArray:
      for item in content.elems:
        if item.kind != JObject:
          continue
        let typ = item{"type"}.getStr("")
        if typ in ["image", "image_url", "input_image"]:
          parts.add("[visual input present: send this request to gemini38 for image analysis]")
        elif typ in ["video", "video_url", "input_video"]:
          parts.add("[video input present]")
        elif typ in ["file", "document", "input_file"]:
          parts.add("[document input present: " & item{"name"}.getStr(item{"filename"}.getStr(item{"path"}.getStr(""))) & "]")
  parts.join("\n")

proc hasVisualInput(messages: JsonNode): bool =
  if messages.isNil or messages.kind != JArray:
    return false
  for message in messages.elems:
    if message.kind != JObject:
      continue
    let content = message{"content"}
    if content.kind != JArray:
      continue
    for part in content.elems:
      if part.kind == JObject and part{"type"}.getStr("") in ["image", "image_url", "input_image"]:
        return true
  false

proc hasUsableVisualInput(messages: JsonNode): bool =
  if messages.isNil or messages.kind != JArray:
    return false
  for message in messages.elems:
    if message.kind != JObject:
      continue
    let content = message{"content"}
    if content.kind != JArray:
      continue
    for part in content.elems:
      if part.kind != JObject or part{"type"}.getStr("") notin ["image", "image_url", "input_image"]:
        continue
      var value = part{"url"}.getStr(part{"uri"}.getStr(part{"data"}.getStr("")))
      if part.hasKey("image_url"):
        if part["image_url"].kind == JObject:
          value = part["image_url"]{"url"}.getStr(value)
        elif part["image_url"].kind == JString:
          value = part["image_url"].getStr()
      if value.strip().len > 0:
        return true
  false

proc visualChat(messages: JsonNode, tenantId: string): Future[DirectChatResult] {.async.} =
  if not hasVisualInput(messages):
    raise newException(ValueError, "visual chat requires an image input")
  if not hasUsableVisualInput(messages):
    raise newException(ValueError, "image input must contain a data URL, URI, or encoded image data")
  let specialistMessages = specialistChatMessages(mrGemini38, messages)
  let response = await invokeModel(mrGemini38, specialistMessages, false, tenantId, "")
  DirectChatResult(content: response.content, reasoningContent: response.reasoningContent, model: modelRoleName(mrGemini38), usage: copy(response.usage), taskId: "")

proc taskUsage(taskId: string): JsonNode =
  let rows = store.query("SELECT tokens_used FROM tasks WHERE task_id=?", @[%taskId])
  let total = if rows.len > 0: rows[0].getInt("tokens_used", 0) else: 0
  %*{"total_tokens": total}

proc directChat(messages: JsonNode, tenantId: string): Future[DirectChatResult] {.async.} =
  let goal = routingGoal(messages)
  let route = await routeTask(goal, defaultSigma(goal), %*{"status": "chat"}, tenantId, "")
  if hasVisualInput(messages):
    return await visualChat(messages, tenantId)
  if routeNeedsExecution(route):
    let spec = %*{"goal": goal, "messages": copy(messages)}
    let h = createTask(goal, spec, tenantId)
    h.applyRoute(route)
    discard h.launchTask()
    let timeoutMs = positiveEnvInt("CHAT_SYNC_TIMEOUT_MS", 1_800_000)
    let started = getMonoTime()
    while true:
      if int((getMonoTime() - started).inMilliseconds) >= timeoutMs:
        acquire(h.lock)
        h.stopRequested = true
        h.status = "halted"
        h.terminalReason = "synchronous chat timeout"
        h.orchestratorState = osTerminal
        h.sigma["phase"] = %"terminal"
        release(h.lock)
        h.persistTask()
        raise newException(IOError, "synchronous routed chat timed out")
      await sleepAsync(250)
      acquire(h.lock)
      let status = h.status
      let obs = copy(h.obs)
      let reason = h.terminalReason
      release(h.lock)
      if status == "succeeded":
        return DirectChatResult(content: obs{"final"}.getStr(obs{"content"}.getStr("Task completed.")), reasoningContent: "", model: modelRoleName(route.primaryModel), usage: taskUsage(h.taskId), taskId: h.taskId)
      if status in ["failed", "halted", "stopped"]:
        raise newException(IOError, obs{"error"}.getStr(reason))
  let role = chooseSimpleSpecialist(route)
  let specialistMessages = specialistChatMessages(role, messages)
  let resp = await invokeModel(role, specialistMessages, false, tenantId, "")
  return DirectChatResult(content: resp.content, reasoningContent: resp.reasoningContent, model: modelRoleName(role), usage: copy(resp.usage), taskId: "")

proc createChatJob(requestNode: JsonNode, tenantId: string): string =
  let id = newId("chatjob")
  let ts = nowF()
  discard store.exec("INSERT INTO chat_jobs (job_id, tenant_id, request_json, status, created_at, updated_at) VALUES (?,?,?,'queued',?,?)",
    @[%id, %tenantId, %($requestNode), %ts, %ts])
  id

proc claimChatJob(jobId: string): bool =
  acquire(chatJobsLock)
  if jobId in activeChatJobs:
    release(chatJobsLock)
    return false
  activeChatJobs.incl(jobId)
  release(chatJobsLock)
  let rows = store.query("SELECT status FROM chat_jobs WHERE job_id=?", @[%jobId])
  if rows.len == 0 or rows[0].getStr("status") notin ["queued", "running"]:
    acquire(chatJobsLock)
    activeChatJobs.excl(jobId)
    release(chatJobsLock)
    return false
  true

proc releaseChatJob(jobId: string) =
  acquire(chatJobsLock)
  activeChatJobs.excl(jobId)
  release(chatJobsLock)

proc streamRequestyJob(jobId: string, role: ModelRole, messages: JsonNode, tenantId: string): Future[LlmResponse] {.async.} =
  let key = requireEnv("REQUESTY_API_KEY")
  let requestRows = store.query("SELECT request_json FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%jobId, %tenantId])
  if requestRows.len == 0:
    raise newException(IOError, "chat job not found for tenant")
  let requestNode = requestRows[0].getJson("request_json")
  let requestedMax = requestNode{"max_tokens"}.getInt(0)
  let requestedTemperature = requestNode{"temperature"}.getFloat(NaN)
  let requestedTopP = requestNode{"top_p"}.getFloat(NaN)
  var body = requestyBody(role, messages, false, true)
  if requestedMax > 0:
    body["max_tokens"] = %effectiveMaxTokens(requestedMax, "stream")
  if not requestedTemperature.isNaN:
    body["temperature"] = %requestedTemperature
  if not requestedTopP.isNaN:
    body["top_p"] = %requestedTopP
  var client = newAsyncHttpClient(maxRedirects = 0)
  defer: client.close()
  client.timeout = positiveEnvInt("MODEL_HTTP_TIMEOUT_MS", 600000)
  client.headers = newHttpHeaders({"Authorization": "Bearer " & key, "Content-Type": "application/json", "Accept": "text/event-stream"})
  let upstream = await client.request(RequestyBaseUrl & "/chat/completions", httpMethod = HttpPost, body = $body)
  if upstream.code.int < 200 or upstream.code.int >= 300:
    let (raw, _) = await readBoundedBody(upstream, positiveEnvInt("MODEL_MAX_RESPONSE_BYTES", 16_777_216))
    raise newException(IOError, "Requesty stream status " & $upstream.code.int & ": " & raw)
  var pending = ""
  var content = ""
  var reasoning = ""
  var usage = newJObject()
  var finishReason = ""
  var model = modelSpec(role).model
  var rawEvents = newJArray()
  var sawDone = false
  proc consume(eventText: string): bool =
    var dataLines: seq[string] = @[]
    for line in eventText.splitLines():
      if line.startsWith("data:"):
        dataLines.add(line[5 .. ^1].strip())
    if dataLines.len == 0:
      return false
    let data = dataLines.join("\n")
    if data == "[DONE]":
      sawDone = true
      return true
    let event = parseJson(data)
    rawEvents.add(copy(event))
    if event.hasKey("model"):
      model = event{"model"}.getStr(model)
    if event.hasKey("usage") and event["usage"].kind == JObject:
      usage = copy(event["usage"])
      persistChatJobEvent(jobId, %*{"type": "usage", "usage": usage})
    if event.hasKey("error"):
      let message = if event["error"].kind == JObject: event["error"]{"message"}.getStr($event["error"]) else: $event["error"]
      raise newException(IOError, message)
    if event.hasKey("choices") and event["choices"].kind == JArray and event["choices"].elems.len > 0:
      let choice = event["choices"][0]
      let delta = if choice.hasKey("delta") and choice["delta"].kind == JObject: choice["delta"] else: newJObject()
      let contentDelta = streamText(delta{"content"})
      let reasoningDelta = streamText(if delta.hasKey("reasoning_content"): delta["reasoning_content"] else: delta{"reasoning"})
      if contentDelta.len > 0: content.add(contentDelta)
      if reasoningDelta.len > 0: reasoning.add(reasoningDelta)
      if choice.hasKey("finish_reason") and choice["finish_reason"].kind == JString:
        finishReason = choice["finish_reason"].getStr("")
      if contentDelta.len > 0 or reasoningDelta.len > 0:
        var deltaEvent = %*{"type": "delta", "model": model}
        if contentDelta.len > 0: deltaEvent["content"] = %contentDelta
        if reasoningDelta.len > 0: deltaEvent["reasoning_content"] = %reasoningDelta
        if finishReason.len > 0: deltaEvent["finish_reason"] = %finishReason
        persistChatJobEvent(jobId, deltaEvent)
    false
  var ended = false
  while not ended:
    let stateRows = store.query("SELECT status FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%jobId, %tenantId])
    if stateRows.len == 0 or stateRows[0].getStr("status") in ["stopping", "stopped"]:
      raise newException(IOError, "chat job stopped")
    let readResult = await upstream.bodyStream.read()
    if not readResult[0]:
      break
    pending.add(readResult[1])
    pending = pending.replace("\r\n", "\n")
    while true:
      let separator = pending.find("\n\n")
      if separator < 0: break
      let eventText = pending[0 ..< separator]
      pending = if separator + 2 < pending.len: pending[separator + 2 .. ^1] else: ""
      if consume(eventText):
        ended = true
        break
  if pending.strip().len > 0 and not sawDone:
    discard consume(pending.replace("\r\n", "\n").strip())
  let promptTokens = usage{"prompt_tokens"}.getInt(usage{"input_tokens"}.getInt(0))
  let completionTokens = usage{"completion_tokens"}.getInt(usage{"output_tokens"}.getInt(0))
  let totalTokens = usage{"total_tokens"}.getInt(promptTokens + completionTokens)
  if totalTokens > 0 and not chargeTokens(tenantId, "", totalTokens):
    raise newException(IOError, "tenant token budget exhausted")
  if not sawDone and content.len == 0 and reasoning.len == 0:
    raise newException(IOError, "Requesty stream ended without model output")
  result = LlmResponse(content: content, reasoningContent: reasoning, raw: rawEvents, usage: usage, model: model, provider: pkRequesty, finishReason: finishReason, promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens, logprobs: @[])

proc runChatJob(jobId: string) {.async.} =
  if not claimChatJob(jobId):
    return
  try:
    let rows = store.query("SELECT request_json,tenant_id FROM chat_jobs WHERE job_id=?", @[%jobId])
    if rows.len == 0:
      return
    let tenantId = rows[0].getStr("tenant_id")
    let req = rows[0].getJson("request_json")
    let messages = req{"messages"}
    if messages.kind != JArray or messages.elems.len == 0:
      raise newException(ValueError, "messages array required")
    persistChatJobEvent(jobId, %*{"type": "started"})
    let goal = routingGoal(messages)
    let route = await routeTask(goal, defaultSigma(goal), %*{"status": "chat_job"}, tenantId, "")
    persistChatJobEvent(jobId, %*{"type": "route", "intent": route.intent, "model": modelRoleName(route.primaryModel), "route": route.raw})
    if hasVisualInput(messages):
      discard store.exec("UPDATE chat_jobs SET model=?, updated_at=? WHERE job_id=?", @[%modelRoleName(mrGemini38), %nowF(), %jobId])
      let response = await visualChat(messages, tenantId)
      if response.reasoningContent.len > 0 or response.content.len > 0:
        var deltaEvent = %*{"type": "delta", "model": modelRoleName(mrGemini38)}
        if response.content.len > 0:
          deltaEvent["content"] = %response.content
        if response.reasoningContent.len > 0:
          deltaEvent["reasoning_content"] = %response.reasoningContent
        persistChatJobEvent(jobId, deltaEvent)
      persistChatJobEvent(jobId, %*{"type": "done", "model": modelRoleName(mrGemini38), "task_id": "", "usage": response.usage, "finish_reason": "stop"})
      return
    if routeNeedsExecution(route):
      let spec = %*{"goal": goal, "messages": copy(messages), "max_steps": req{"max_steps"}.getInt(0)}
      let h = createTask(goal, spec, tenantId)
      h.applyRoute(route)
      discard store.exec("UPDATE chat_jobs SET model=?, task_id=?, updated_at=? WHERE job_id=?", @[%modelRoleName(route.primaryModel), %h.taskId, %nowF(), %jobId])
      discard h.launchTask()
      var lastTaskSequence = 0'i64
      let timeoutMs = positiveEnvInt("CHAT_JOB_TIMEOUT_MS", 3_600_000)
      let started = getMonoTime()
      while true:
        if int((getMonoTime() - started).inMilliseconds) >= timeoutMs:
          acquire(h.lock)
          h.stopRequested = true
          h.status = "halted"
          h.terminalReason = "chat job timeout"
          h.orchestratorState = osTerminal
          h.sigma["phase"] = %"terminal"
          release(h.lock)
          h.persistTask()
          raise newException(IOError, "routed chat job timed out")
        for r in store.query("SELECT sequence,event_json FROM task_events WHERE task_id=? AND sequence>? ORDER BY sequence ASC", @[%h.taskId, %lastTaskSequence]):
          lastTaskSequence = r.getInt("sequence", lastTaskSequence)
          persistChatJobEvent(jobId, %*{"type": "agent_event", "task_id": h.taskId, "event": r.getJson("event_json")})
        acquire(h.lock)
        let status = h.status
        let obs = copy(h.obs)
        let terminalReason = h.terminalReason
        release(h.lock)
        if status == "succeeded":
          let content = obs{"final"}.getStr(obs{"content"}.getStr("Task completed."))
          if content.len > 0:
            persistChatJobEvent(jobId, %*{"type": "delta", "model": modelRoleName(route.primaryModel), "content": content})
          let usage = taskUsage(h.taskId)
          persistChatJobEvent(jobId, %*{"type": "usage", "usage": usage})
          persistChatJobEvent(jobId, %*{"type": "done", "model": modelRoleName(route.primaryModel), "task_id": h.taskId, "usage": usage, "finish_reason": "stop"})
          break
        if status in ["failed", "halted", "stopped"]:
          raise newException(IOError, obs{"error"}.getStr(terminalReason))
        let state = store.query("SELECT status FROM chat_jobs WHERE job_id=?", @[%jobId])
        if state.len == 0 or state[0].getStr("status") in ["stopping", "stopped"]:
          acquire(h.lock)
          h.stopRequested = true
          h.status = "halted"
          h.terminalReason = "chat job stopped"
          h.orchestratorState = osTerminal
          h.sigma["phase"] = %"terminal"
          release(h.lock)
          h.persistTask()
          raise newException(IOError, "chat job stopped")
        await sleepAsync(200)
    else:
      let role = chooseSimpleSpecialist(route)
      discard store.exec("UPDATE chat_jobs SET model=?, updated_at=? WHERE job_id=?", @[%modelRoleName(role), %nowF(), %jobId])
      let specialistMessages = specialistChatMessages(role, messages)
      var resp: LlmResponse
      if modelSpec(role).provider == pkRequesty:
        resp = await streamRequestyJob(jobId, role, specialistMessages, tenantId)
      else:
        resp = await invokeModel(role, specialistMessages, false, tenantId, "")
        if resp.reasoningContent.len > 0 or resp.content.len > 0:
          var deltaEvent = %*{"type": "delta", "model": modelRoleName(role)}
          if resp.content.len > 0: deltaEvent["content"] = %resp.content
          if resp.reasoningContent.len > 0: deltaEvent["reasoning_content"] = %resp.reasoningContent
          persistChatJobEvent(jobId, deltaEvent)
        if resp.usage.kind == JObject and resp.usage.len > 0:
          persistChatJobEvent(jobId, %*{"type": "usage", "usage": resp.usage})
      persistChatJobEvent(jobId, %*{"type": "done", "model": modelRoleName(role), "task_id": "", "usage": resp.usage, "finish_reason": (if resp.finishReason.len > 0: resp.finishReason else: "stop")})
  except CatchableError as e:
    try:
      let stateRows = store.query("SELECT status FROM chat_jobs WHERE job_id=?", @[%jobId])
      if stateRows.len == 0 or stateRows[0].getStr("status") notin ["stopping", "stopped"]:
        persistChatJobEvent(jobId, %*{"type": "error", "message": e.msg})
      elif stateRows[0].getStr("status") == "stopping":
        persistChatJobEvent(jobId, %*{"type": "stopped", "message": "stopped by client"})
    except CatchableError:
      discard
  finally:
    releaseChatJob(jobId)

proc launchChatJob(jobId: string): bool =
  acquire(chatJobsLock)
  let alreadyActive = jobId in activeChatJobs
  release(chatJobsLock)
  if alreadyActive:
    return false
  asyncCheck runChatJob(jobId)
  true

proc resumePendingChatJobs() =
  for r in store.query("SELECT job_id FROM chat_jobs WHERE status IN ('queued','running') ORDER BY created_at ASC"):
    discard launchChatJob(r.getStr("job_id"))

