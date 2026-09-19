proc respondJson(req: Request, code: HttpCode, body: JsonNode): Future[void] {.async.} =
  let headers = newHttpHeaders({
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Api-Key"
  })
  await req.respond(code, $body, headers)

proc sendChunked(req: Request, payload: string): Future[void] {.async.} =
  if payload.len == 0:
    return
  await req.client.send(toHex(payload.len) & "\c\L" & payload & "\c\L")

proc handleTaskEvents(req: Request, taskId: string) {.async.} =
  let h = restoreTask(taskId)
  if h.isNil:
    await respondJson(req, Http404, %*{"error": "task not found"})
    return
  let headers = newHttpHeaders({
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
    "Transfer-Encoding": "chunked",
    "Access-Control-Allow-Origin": "*"
  })
  await req.client.send("HTTP/1.1 200 OK\c\L")
  await req.sendHeaders(headers)
  await req.client.send("\c\L")
  let past = store.query("SELECT event_json FROM task_events WHERE task_id=? ORDER BY sequence ASC", @[%taskId])
  for r in past:
    await sendChunked(req, "data: " & r.getStr("event_json") & "\c\L\c\L")
  var queue = initDeque[JsonNode]()
  var queueLock: Lock
  initLock(queueLock)
  var alive = true
  let subId = newId("sub")
  let cb = proc(ev: JsonNode) {.closure.} =
    acquire(queueLock)
    queue.addLast(copy(ev))
    release(queueLock)
  acquire(h.lock)
  h.subscribers.add((subId, cb))
  release(h.lock)
  try:
    while alive:
      await sleepAsync(200)
      var events: seq[JsonNode] = @[]
      acquire(queueLock)
      while queue.len > 0:
        events.add(queue.popFirst())
      release(queueLock)
      for ev in events:
        try:
          await sendChunked(req, "data: " & canonical(ev) & "\c\L\c\L")
        except CatchableError:
          alive = false
          break
      acquire(h.lock)
      let terminal = h.status in ["succeeded", "failed", "halted"]
      release(h.lock)
      if terminal and events.len == 0:
        break
  finally:
    acquire(h.lock)
    var nextSubs: seq[tuple[id: string, cb: proc(ev: JsonNode) {.closure.}]] = @[]
    for existing in h.subscribers:
      if existing.id != subId:
        nextSubs.add(existing)
    h.subscribers = nextSubs
    release(h.lock)
    deinitLock(queueLock)
    try:
      await req.client.send("0\c\L\c\L")
    except CatchableError:
      discard

proc handleChatJobEvents(req: Request, jobId: string) {.async.} =
  let rows = store.query("SELECT job_id FROM chat_jobs WHERE job_id=?", @[%jobId])
  if rows.len == 0:
    await respondJson(req, Http404, %*{"error": "chat job not found"})
    return
  var lastSeq = 0'i64
  let lastEventHeader = req.headers.getOrDefault("Last-Event-ID")
  if lastEventHeader.len > 0:
    try:
      lastSeq = max(0'i64, parseBiggestInt($lastEventHeader[0]).int64)
    except ValueError:
      lastSeq = 0
  let headers = newHttpHeaders({
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
    "Transfer-Encoding": "chunked",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Last-Event-ID"
  })
  try:
    await req.client.send("HTTP/1.1 200 OK\c\L")
    await req.sendHeaders(headers)
    await req.client.send("\c\L")
    await sendChunked(req, "data: " & canonical(%*{"type": "connected", "job_id": jobId}) & "\c\L\c\L")
    var lastPing = nowF()
    while not req.client.isClosed():
      let events = store.query("SELECT sequence, event_json FROM chat_job_events WHERE job_id=? AND sequence>? ORDER BY sequence ASC", @[%jobId, %lastSeq])
      for r in events:
        lastSeq = r.getInt("sequence", lastSeq)
        await sendChunked(req, "id: " & $lastSeq & "\c\Ldata: " & r.getStr("event_json") & "\c\L\c\L")
      let job = store.query("SELECT status FROM chat_jobs WHERE job_id=?", @[%jobId])
      let status = if job.len > 0: job[0].getStr("status") else: "failed"
      if status in ["succeeded", "failed", "stopped"] and events.len == 0:
        break
      if nowF() - lastPing >= 15.0:
        lastPing = nowF()
        await sendChunked(req, ": ping\c\L\c\L")
      await sleepAsync(200)
  except CatchableError:
    discard
  finally:
    try:
      await req.client.send("0\c\L\c\L")
    except CatchableError:
      discard

var sseClients {.threadvar.}: seq[SseClient]

proc pushSse(c: SseClient, payload: string) =
  if c.isNil or not c.alive:
    return
  acquire(c.lock)
  c.queue.addLast(payload)
  release(c.lock)

proc broadcastTenant(tenantId: string, ev: JsonNode) =
  let payload = "data: " & canonical(ev) & "\n\n"
  acquire(sseLock)
  var live: seq[SseClient] = @[]
  for client in sseClients:
    if client.alive:
      if client.tenantId == tenantId:
        pushSse(client, payload)
      live.add(client)
  sseClients = live
  release(sseLock)

proc attachBroadcast(h: TaskHandle) =
  if h.isNil:
    return
  acquire(h.lock)
  if not h.broadcastAttached:
    let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
    h.subscribers.add((id: "broadcast:" & h.taskId, cb: proc(ev: JsonNode) {.closure.} = broadcastTenant(tenant, ev)))
    h.broadcastAttached = true
  release(h.lock)

proc cookieValue(req: Request, name: string): string =
  let raw = req.headers.getOrDefault("Cookie")
  for part in raw.split(';'):
    let pair = part.strip()
    let idx = pair.find('=')
    if idx > 0 and pair[0 ..< idx].strip() == name:
      return decodeUrl(pair[idx + 1 .. ^1].strip())
  ""

proc createBrowserSession(tenantId: string): string =
  let token = newId("session") & newId("token")
  let sessionId = newId("browser")
  let lifetime = positiveEnvInt("BROWSER_SESSION_SECONDS", 2_592_000)
  let now = nowF()
  discard store.exec("DELETE FROM browser_sessions WHERE expires_at<=?", @[%now])
  discard store.exec("INSERT INTO browser_sessions (session_id,tenant_id,token_hash,expires_at,created_at) VALUES (?,?,?,?,?)", @[%sessionId, %tenantId, %sha1Hex(token), %(now + float(lifetime)), %now])
  token

proc sessionCookie(token: string): string =
  let lifetime = positiveEnvInt("BROWSER_SESSION_SECONDS", 2_592_000)
  var value = "agent_session=" & encodeUrl(token) & "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" & $lifetime
  if getEnv("AGENT_COOKIE_SECURE", "").strip().toLowerAscii() in ["1", "true", "yes", "on"]:
    value.add("; Secure")
  value

proc authenticate(req: Request): Option[Row] =
  var credential = ""
  let auth = req.headers.getOrDefault("Authorization").strip()
  if auth.toLowerAscii().startsWith("bearer ") and auth.len > 7:
    credential = auth[7 .. ^1].strip()
  if credential.len == 0:
    credential = req.headers.getOrDefault("X-Api-Key").strip()
  if credential.len > 0:
    let hash = sha1Hex(credential)
    let rows = store.query("SELECT * FROM tenants WHERE api_key_hash=? AND api_key_hash<>'' LIMIT 1", @[%hash])
    if rows.len > 0:
      return some(rows[0])
  let sessionToken = cookieValue(req, "agent_session")
  if sessionToken.len > 0:
    let rows = store.query("SELECT t.* FROM browser_sessions s JOIN tenants t ON t.tenant_id=s.tenant_id WHERE s.token_hash=? AND s.expires_at>? LIMIT 1", @[%sha1Hex(sessionToken), %nowF()])
    if rows.len > 0:
      return some(rows[0])
  none(Row)

proc ensureDefaultTenant(): Row =
  let tenantId = ensureLocalTenant()
  let configuredKey = getEnv("AGENT_API_KEY", "").strip()
  if configuredKey.len > 0:
    discard store.exec("UPDATE tenants SET api_key_hash=? WHERE tenant_id=?", @[%sha1Hex(configuredKey), %tenantId])
  let rows = store.query("SELECT * FROM tenants WHERE tenant_id=?", @[%tenantId])
  if rows.len == 0:
    raise newException(DbError, "default tenant could not be created")
  let allowedRaw = rows[0].getStr("allowed_tools", "[]")
  var allowed = parseJson(allowedRaw)
  if allowed.kind != JArray:
    raise newException(DbError, "default tenant allowed_tools is invalid")
  if allowed.elems.len == 0:
    var tools = newJArray()
    for name, _ in toolRegistry:
      tools.add(%name)
    discard store.exec("UPDATE tenants SET allowed_tools=? WHERE tenant_id=? AND allowed_tools='[]'", @[%canonical(tools), %tenantId])
  let fresh = store.query("SELECT * FROM tenants WHERE tenant_id=?", @[%tenantId])
  if fresh.len == 0:
    raise newException(DbError, "default tenant could not be loaded")
  fresh[0]

proc handleSse(req: Request, tenantId: string) {.async.} =
  let client = SseClient(req: req, tenantId: tenantId, alive: true, queue: initDeque[string]())
  initLock(client.lock)
  acquire(sseLock)
  sseClients.add(client)
  release(sseLock)
  let headers = newHttpHeaders({
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
    "Transfer-Encoding": "chunked",
    "Access-Control-Allow-Origin": "*"
  })
  try:
    await req.client.send("HTTP/1.1 200 OK\c\L")
    await req.sendHeaders(headers)
    await req.client.send("\c\L")
    await sendChunked(req, "data: " & canonical(%*{"type": "connected", "tenant_id": tenantId, "time": nowF()}) & "\c\L\c\L")
    var lastPing = nowF()
    while client.alive and not req.client.isClosed():
      var batch: seq[string] = @[]
      acquire(client.lock)
      while client.queue.len > 0:
        batch.add(client.queue.popFirst())
      release(client.lock)
      for payload in batch:
        await sendChunked(req, payload.replace("\n", "\c\L"))
      if nowF() - lastPing > 15.0:
        lastPing = nowF()
        await sendChunked(req, ": ping\c\L\c\L")
      await sleepAsync(100)
  except CatchableError:
    discard
  finally:
    client.alive = false
    acquire(sseLock)
    var live: seq[SseClient] = @[]
    for item in sseClients:
      if item != client:
        live.add(item)
    sseClients = live
    release(sseLock)
    try:
      await req.client.send("0\c\L\c\L")
    except CatchableError:
      discard

proc sendChatStreamEvent(req: Request, event: JsonNode): Future[void] {.async.} =
  await sendChunked(req, "data: " & canonical(event) & "\c\L\c\L")

proc stopTaskTree(taskId: string)

proc streamChatCompletionsAsync(req: Request, messages: JsonNode,
                                maxTokens: int = 0,
                                temperature: float = 0.96,
                                topP: float = 1.0,
                                tenantId: string = "local"): Future[void] {.async.} =
  let requestNode = %*{"messages": copy(messages), "stream": true, "max_tokens": maxTokens, "temperature": temperature, "top_p": topP}
  let jobId = createChatJob(requestNode, tenantId)
  discard launchChatJob(jobId)
  let headers = newHttpHeaders({
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
    "Transfer-Encoding": "chunked"
  })
  await req.client.send("HTTP/1.1 200 OK\c\L")
  await req.sendHeaders(headers)
  await req.client.send("\c\L")
  await sendChatStreamEvent(req, %*{"type": "meta", "job_id": jobId})
  var lastSequence = 0'i64
  var finished = false
  var model = ""
  var lastPing = nowF()
  try:
    while not finished:
      let rows = store.query("SELECT sequence,event_json FROM chat_job_events WHERE job_id=? AND sequence>? ORDER BY sequence ASC", @[%jobId, %lastSequence])
      for row in rows:
        lastSequence = row.getInt("sequence", lastSequence)
        let event = row.getJson("event_json")
        let eventType = event{"type"}.getStr("")
        if event.hasKey("model"):
          model = event{"model"}.getStr(model)
        case eventType
        of "delta":
          var delta = newJObject()
          let content = event{"content"}.getStr(event{"delta"}.getStr(""))
          let reasoning = event{"reasoning_content"}.getStr(event{"reasoning"}.getStr(""))
          if content.len > 0: delta["content"] = %content
          if reasoning.len > 0: delta["reasoning_content"] = %reasoning
          let chunk = %*{"id": jobId, "object": "chat.completion.chunk", "created": getTime().toUnix(), "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": newJNull()}]}
          await sendChatStreamEvent(req, chunk)
        of "agent_event", "route", "usage", "started":
          await sendChatStreamEvent(req, event)
        of "stopped":
          await sendChatStreamEvent(req, %*{"type": "stopped", "job_id": jobId})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
        of "done":
          let finishReason = event{"finish_reason"}.getStr("stop")
          let chunk = %*{"id": jobId, "object": "chat.completion.chunk", "created": getTime().toUnix(), "model": event{"model"}.getStr(model), "choices": [{"index": 0, "delta": newJObject(), "finish_reason": finishReason}], "usage": (if event.hasKey("usage"): event["usage"] else: newJObject())}
          await sendChatStreamEvent(req, chunk)
          await sendChatStreamEvent(req, %*{"type": "done", "job_id": jobId, "task_id": event{"task_id"}.getStr(""), "usage": (if event.hasKey("usage"): event["usage"] else: newJObject())})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
        of "error":
          await sendChatStreamEvent(req, %*{"type": "error", "message": event{"message"}.getStr("chat job failed"), "job_id": jobId})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
        else:
          discard
      if not finished:
        let stateRows = store.query("SELECT status,error FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%jobId, %tenantId])
        if stateRows.len == 0:
          await sendChatStreamEvent(req, %*{"type": "error", "message": "chat job disappeared", "job_id": jobId})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
        elif stateRows[0].getStr("status") == "failed":
          await sendChatStreamEvent(req, %*{"type": "error", "message": stateRows[0].getStr("error", "chat job failed"), "job_id": jobId})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
        elif stateRows[0].getStr("status") == "stopped":
          await sendChatStreamEvent(req, %*{"type": "stopped", "job_id": jobId})
          await sendChunked(req, "data: [DONE]\c\L\c\L")
          finished = true
      if not finished and nowF() - lastPing > 15.0:
        lastPing = nowF()
        await sendChunked(req, ": ping\c\L\c\L")
      if not finished:
        await sleepAsync(100)
  except CatchableError:
    try:
      let rows = store.query("SELECT task_id,status FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%jobId, %tenantId])
      if rows.len > 0 and rows[0].getStr("status") in ["queued", "running"]:
        discard store.exec("UPDATE chat_jobs SET status='stopping',updated_at=? WHERE job_id=? AND tenant_id=?", @[%nowF(), %jobId, %tenantId])
        let taskId = rows[0].getStr("task_id")
        if taskId.len > 0:
          stopTaskTree(taskId)
        persistChatJobEvent(jobId, %*{"type": "stopped", "message": "stream disconnected"})
    except CatchableError:
      discard
  finally:
    try:
      await req.client.send("0\c\L\c\L")
    except CatchableError:
      discard

proc mimeForPath(path: string): string =
  let ext = splitFile(path).ext.toLowerAscii()
  case ext
  of ".html": "text/html; charset=utf-8"
  of ".webmanifest", ".json": "application/manifest+json; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".svg": "image/svg+xml"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".webp": "image/webp"
  of ".ico": "image/x-icon"
  else: "application/octet-stream"

proc staticPath(urlPath: string): string =
  var rel = urlPath
  if rel == "/": rel = "/index.html"
  rel = decodeUrl(rel)
  if '\0' in rel or rel.contains("..") or rel.contains('\\'):
    raise newException(ValueError, "invalid static path")
  while rel.startsWith("/"):
    rel = rel[1 .. ^1]
  let base = absolutePath(PublicRoot)
  let candidate = absolutePath(base / rel)
  if not (candidate == base or candidate.startsWith(base & DirSep)):
    raise newException(ValueError, "static path escapes public root")
  candidate

proc serveStatic(req: Request, urlPath: string, issueSession: bool): Future[bool] {.async.} =
  var path: string
  try:
    path = staticPath(urlPath)
  except CatchableError:
    return false
  if not fileExists(path):
    return false
  let maxBytes = positiveEnvInt("STATIC_MAX_BYTES", 33_554_432)
  let size = getFileSize(path)
  if size < 0 or size > maxBytes:
    return false
  var headers = newHttpHeaders({"Content-Type": mimeForPath(path), "Cache-Control": (if urlPath in ["/", "/index.html"]: "no-cache" else: "public, max-age=86400")})
  if issueSession:
    let token = createBrowserSession(defaultTenantId)
    headers["Set-Cookie"] = sessionCookie(token)
  await req.respond(Http200, readFile(path), headers)
  return true

proc stopTaskTree(taskId: string) =
  let h = restoreTask(taskId)
  if not h.isNil:
    acquire(h.lock)
    h.stopRequested = true
    if h.status notin ["succeeded", "failed", "halted", "stopped"]:
      h.status = "halted"
    h.verified = false
    h.terminalReason = "stopped by client"
    h.orchestratorState = osTerminal
    h.sigma["phase"] = %"terminal"
    release(h.lock)
    h.persistTask()
  discard store.exec("UPDATE subagents SET stop_requested=1,status=CASE WHEN status IN ('succeeded','failed','stopped') THEN status ELSE 'stopping' END,updated_at=? WHERE task_id=?", @[%nowF(), %taskId])
  acquire(subAgentsLock)
  for _, agent in activeSubAgents.mpairs:
    if agent.taskId == taskId:
      acquire(agent.lock)
      if agent.status notin ["succeeded", "failed", "stopped"]:
        agent.stopRequested = true
        agent.status = "stopping"
      release(agent.lock)
  release(subAgentsLock)

proc handleHttpRequest(req: Request) {.async, gcsafe.} =
  let path = req.url.path
  if req.reqMethod == HttpOptions:
    let headers = newHttpHeaders({"Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Api-Key"})
    await req.respond(Http204, "", headers)
    return
  if req.reqMethod == HttpGet and (path in ["/", "/index.html"] or path == "/manifest.webmanifest" or path.startsWith("/icons/") or path.startsWith("/splash/")):
    if await serveStatic(req, path, path in ["/", "/index.html"]):
      return
    await respondJson(req, Http404, %*{"error": "static asset not found"})
    return
  if path == "/api/health" and req.reqMethod == HttpGet:
    let dbReady = not store.isNil and not store.handle.isNil
    await respondJson(req, Http200, %*{"ok": dbReady, "status": (if dbReady: "ready" else: "not_ready"), "time": nowF(), "models": {"orchestrator": VmcoModel, "gpt6_astra": Gpt6AstraModel, "glm52": Glm52Model, "gemini38": Gemini38Model, "minimax_m3": MiniMaxM3Model, "grok43": Grok43Model}})
    return
  let auth = authenticate(req)
  if auth.isNone:
    await respondJson(req, Http401, %*{"error": "authentication required"})
    return
  let tenant = auth.get()
  let tenantId = tenant.getStr("tenant_id")

  if path == "/api/diagnostics/run" and req.reqMethod == HttpPost:
    try:
      let report = await runRegressionGate(tenantId)
      await respondJson(req, Http200, report)
    except CatchableError as e:
      await respondJson(req, Http500, %*{"error": e.msg})
    return
  if path == "/api/chat" and req.reqMethod == HttpPost:
    var body: JsonNode
    try:
      body = parseJson(req.body)
    except CatchableError:
      await respondJson(req, Http400, %*{"error": {"message": "invalid JSON body"}})
      return
    if not body.hasKey("messages") or body["messages"].kind != JArray or body["messages"].elems.len == 0:
      await respondJson(req, Http400, %*{"error": {"message": "messages array required"}})
      return
    if body{"stream"}.getBool(false):
      await streamChatCompletionsAsync(req, body["messages"], body{"max_tokens"}.getInt(0), body{"temperature"}.getFloat(0.96), body{"top_p"}.getFloat(1.0), tenantId)
      return
    try:
      let chat = await directChat(body["messages"], tenantId)
      var msg = %*{"role": "assistant", "content": chat.content}
      if chat.reasoningContent.len > 0:
        msg["reasoning_content"] = %chat.reasoningContent
      await respondJson(req, Http200, %*{
        "id": newId("chatcmpl"),
        "object": "chat.completion",
        "created": getTime().toUnix(),
        "model": chat.model,
        "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}],
        "usage": chat.usage,
        "task_id": chat.taskId
      })
    except CatchableError as e:
      await respondJson(req, Http502, %*{"error": {"message": e.msg}})
    return
  let chatJobPrefix = "/api/chat/jobs/"
  if path.startsWith(chatJobPrefix):
    let rest = path[chatJobPrefix.len .. ^1]
    let parts = rest.split('/')
    if parts.len == 2 and parts[1] == "events" and req.reqMethod == HttpGet:
      let owned = store.query("SELECT job_id FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%parts[0], %tenantId])
      if owned.len == 0:
        await respondJson(req, Http404, %*{"error": "chat job not found"})
        return
      await handleChatJobEvents(req, parts[0])
      return
    if parts.len == 2 and parts[1] == "stop" and req.reqMethod == HttpPost:
      let rows = store.query("SELECT task_id,status FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%parts[0], %tenantId])
      if rows.len == 0:
        await respondJson(req, Http404, %*{"error": "chat job not found"})
        return
      let taskId = rows[0].getStr("task_id")
      discard store.exec("UPDATE chat_jobs SET status='stopping',updated_at=? WHERE job_id=? AND tenant_id=? AND status IN ('queued','running')", @[%nowF(), %parts[0], %tenantId])
      if taskId.len > 0:
        stopTaskTree(taskId)
      persistChatJobEvent(parts[0], %*{"type": "stopped", "message": "stopped by client"})
      await respondJson(req, Http200, %*{"job_id": parts[0], "status": "stopped", "task_id": taskId})
      return
    if parts.len == 1 and req.reqMethod == HttpGet:
      let rows = store.query("SELECT * FROM chat_jobs WHERE job_id=? AND tenant_id=?", @[%parts[0], %tenantId])
      if rows.len == 0:
        await respondJson(req, Http404, %*{"error": "chat job not found"})
        return
      let r = rows[0]
      await respondJson(req, Http200, %*{"job_id": r.getStr("job_id"), "status": r.getStr("status"), "content": r.getStr("content"), "reasoning_content": r.getStr("reasoning"), "error": r.getStr("error"), "model": r.getStr("model"), "task_id": r.getStr("task_id"), "usage": r.getJson("usage_json"), "prompt_tokens": r.getInt("prompt_tokens"), "completion_tokens": r.getInt("completion_tokens"), "total_tokens": r.getInt("total_tokens"), "created_at": r.getFloat("created_at"), "updated_at": r.getFloat("updated_at")})
      return

  if path == "/api/events" and req.reqMethod == HttpGet:
    await handleSse(req, tenantId)
    return
  let artifactPrefix = "/api/artifacts/"
  if path.startsWith(artifactPrefix) and req.reqMethod == HttpGet:
    let artifactId = path[artifactPrefix.len .. ^1]
    let rows = store.query("SELECT a.* FROM artifacts a JOIN tasks t ON t.task_id=a.task_id WHERE a.artifact_id=? AND t.tenant_id=?", @[%artifactId, %tenantId])
    if rows.len == 0:
      await respondJson(req, Http404, %*{"error": "artifact not found"})
      return
    let r = rows[0]
    let artifactPath = absolutePath(r.getStr("path"))
    let artifactRoot = absolutePath(WorkspaceRoot / "artifacts")
    if not artifactPath.startsWith(artifactRoot & DirSep) or not fileExists(artifactPath):
      await respondJson(req, Http404, %*{"error": "artifact file not found"})
      return
    let maxBytes = positiveEnvInt("ARTIFACT_DOWNLOAD_MAX_BYTES", 268_435_456)
    if getFileSize(artifactPath) > maxBytes:
      await respondJson(req, Http413, %*{"error": "artifact exceeds download limit"})
      return
    let headers = newHttpHeaders({"Content-Type": r.getStr("mime_type", "application/octet-stream"), "Content-Disposition": "attachment; filename=\"" & r.getStr("name").replace("\"", "") & "\"", "Cache-Control": "private, no-store"})
    await req.respond(Http200, readFile(artifactPath), headers)
    return

  if path == "/api/runs" and req.reqMethod == HttpPost:
    var body: JsonNode
    try:
      body = parseJson(req.body)
    except CatchableError:
      await respondJson(req, Http400, %*{"error": "invalid JSON body"})
      return
    let title = body{"title"}.getStr(body{"goal"}.getStr(body{"message"}.getStr("autonomous task")))
    let spec = if body.hasKey("spec") and body["spec"].kind == JObject: copy(body["spec"]) else: %*{"goal": title}
    let h = createTask(title, spec, tenantId)
    discard h.launchTask()
    await respondJson(req, Http201, %*{"task_id": h.taskId, "status": h.status, "goal": title})
    return
  if path == "/api/runs" and req.reqMethod == HttpGet:
    var arr = newJArray()
    for r in store.query("SELECT * FROM tasks WHERE tenant_id=? ORDER BY updated_at DESC", @[%tenantId]):
      arr.add(%*{
        "task_id": r.getStr("task_id"),
        "title": r.getStr("title"),
        "status": r.getStr("status"),
        "step_index": r.getInt("step_index"),
        "max_steps": r.getInt("max_steps"),
        "tokens_used": r.getInt("tokens_used"),
        "verified": r.getInt("verified") == 1,
        "created_at": r.getFloat("created_at"),
        "updated_at": r.getFloat("updated_at")
      })
    await respondJson(req, Http200, %*{"runs": arr})
    return
  if path.startsWith("/api/runs/"):
    let rest = path[10 .. ^1]
    let parts = rest.split('/')
    let taskId = parts[0]
    let h = restoreTask(taskId)
    if h.isNil or h.tenantId != tenantId:
      await respondJson(req, Http404, %*{"error": "task not found"})
      return
    if parts.len == 1 and req.reqMethod == HttpGet:
      let taskRows = store.query("SELECT step_index,max_steps,tokens_used FROM tasks WHERE task_id=?", @[%taskId])
      let persistedStep = if taskRows.len > 0: taskRows[0].getInt("step_index") else: 0
      let persistedMax = if taskRows.len > 0: taskRows[0].getInt("max_steps") else: 0
      let persistedTokens = if taskRows.len > 0: taskRows[0].getInt("tokens_used") else: 0
      acquire(h.lock)
      let payload = %*{
        "task_id": h.taskId,
        "title": h.title,
        "status": h.status,
        "step_index": persistedStep,
        "max_steps": persistedMax,
        "tokens_used": persistedTokens,
        "verified": h.verified,
        "terminal_reason": h.terminalReason,
        "paused": h.paused,
        "transition_busy": h.transitionBusy,
        "loop_active": h.loopActive.load(moAcquire),
        "sigma": copy(h.sigma),
        "obs": copy(h.obs)
      }
      release(h.lock)
      await respondJson(req, Http200, payload)
      return
    if parts.len == 2 and parts[1] == "events" and req.reqMethod == HttpGet:
      await handleTaskEvents(req, taskId)
      return
    if parts.len == 2 and parts[1] == "stop" and req.reqMethod == HttpPost:
      stopTaskTree(taskId)
      h.checkpoint(newJObject(), %*{"operator": "stop"})
      h.emit(%*{"type": "done", "status": "halted", "verified": false, "reason": "stopped by operator"})
      await respondJson(req, Http200, %*{"task_id": taskId, "status": "halted"})
      return
    if parts.len == 2 and parts[1] == "pause" and req.reqMethod == HttpPost:
      acquire(h.lock)
      h.paused = true
      let status = h.status
      release(h.lock)
      h.persistTask()
      await respondJson(req, Http200, %*{"task_id": taskId, "status": status, "paused": true})
      return
    if parts.len == 2 and parts[1] == "resume" and req.reqMethod == HttpPost:
      acquire(h.lock)
      let terminal = h.status in ["succeeded"] and h.verified
      if not terminal:
        h.paused = false
        h.stopRequested = false
        h.status = "running"
        h.terminalReason = ""
        if h.sigma{"phase"}.getStr("") == "terminal": h.sigma["phase"] = %"perceive"
        h.orchestratorState = osPerceive
      release(h.lock)
      if terminal:
        await respondJson(req, Http409, %*{"error": "task is already completed", "task_id": taskId})
        return
      h.persistTask()
      discard h.launchTask()
      await respondJson(req, Http200, %*{"task_id": taskId, "status": h.status, "paused": false, "loop_active": h.loopActive.load(moAcquire)})
      return
    if parts.len == 2 and parts[1] == "message" and req.reqMethod == HttpPost:
      var body: JsonNode
      try:
        body = parseJson(req.body)
      except CatchableError:
        await respondJson(req, Http400, %*{"error": "invalid JSON body"})
        return
      let msg = body{"message"}.getStr(body{"content"}.getStr(""))
      if msg.len == 0:
        await respondJson(req, Http400, %*{"error": "message required"})
        return
      acquire(h.lock)
      h.obs["operator_message"] = %msg
      h.obs["operator_message_at"] = %nowF()
      h.sigma["route"] = newJObject()
      h.paused = false
      h.stopRequested = false
      if h.status in ["halted", "failed", "queued"]: h.status = "running"
      h.orchestratorState = osPerceive
      h.sigma["phase"] = %"perceive"
      release(h.lock)
      h.persistTask()
      discard h.launchTask()
      await respondJson(req, Http200, %*{"task_id": taskId, "injected": true, "status": h.status})
      return
    if parts.len == 2 and parts[1] == "traces" and req.reqMethod == HttpGet:
      var arr = newJArray()
      for r in store.query("SELECT * FROM raw_traces WHERE task_id=? ORDER BY step_index ASC,created_at ASC", @[%taskId]):
        arr.add(%*{
          "trace_id": r.getStr("trace_id"),
          "task_id": r.getStr("task_id"),
          "tenant_id": r.getStr("tenant_id"),
          "step_index": r.getInt("step_index"),
          "initial_state": r.getJson("initial_state_json"),
          "skill_id": r.getStr("skill_id"),
          "action": r.getJson("action_json"),
          "obs": r.getJson("obs_json"),
          "delta": r.getJson("delta_json"),
          "post_state": r.getJson("post_state_json"),
          "success": r.getInt("success") == 1,
          "latency_ms": r.getInt("latency_ms"),
          "receipt": r.getJson("receipt_json"),
          "immutable_hash": r.getStr("immutable_hash"),
          "created_at": r.getFloat("created_at")
        })
      await respondJson(req, Http200, %*{"traces": arr})
      return
    if parts.len == 2 and parts[1] == "checkpoints" and req.reqMethod == HttpGet:
      var arr = newJArray()
      for r in store.query("SELECT * FROM checkpoints WHERE task_id=? ORDER BY step_index ASC", @[%taskId]):
        arr.add(%*{"checkpoint_id": r.getInt("ckpt_id"), "step_index": r.getInt("step_index"), "state": r.getJson("state_json"), "obs": r.getJson("obs_json"), "action": r.getJson("action_json"), "patch": r.getJson("patch_json"), "receipt": r.getJson("receipt_json"), "digest": r.getStr("digest"), "created_at": r.getFloat("created_at")})
      await respondJson(req, Http200, %*{"checkpoints": arr})
      return
    if parts.len == 2 and parts[1] == "artifacts" and req.reqMethod == HttpGet:
      var arr = newJArray()
      for r in store.query("SELECT * FROM artifacts WHERE task_id=? ORDER BY created_at ASC", @[%taskId]):
        arr.add(%*{"artifact_id": r.getStr("artifact_id"), "name": r.getStr("name"), "path": r.getStr("path"), "kind": r.getStr("kind"), "mime_type": r.getStr("mime_type"), "metadata": r.getJson("metadata_json"), "created_at": r.getFloat("created_at")})
      await respondJson(req, Http200, %*{"artifacts": arr})
      return
  if path == "/api/tools" and req.reqMethod == HttpGet:
    await respondJson(req, Http200, %*{"tools": toolCatalog()})
    return
  if path == "/api/skills" and req.reqMethod == HttpGet:
    var arr = newJArray()
    for r in store.query("SELECT * FROM skills WHERE tenant_id=? AND active=1 ORDER BY reward DESC, updated_at DESC", @[%tenantId]):
      arr.add(%*{"skill_id": r.getStr("skill_id"), "name": r.getStr("name"), "domain": r.getStr("domain"), "trigger": r.getStr("trigger_spec"), "procedure": r.getStr("procedure_spec"), "skill_code": r.getStr("skill_code"), "reward": r.getFloat("reward")})
    await respondJson(req, Http200, %*{"skills": arr})
    return
  if path == "/api/skills" and req.reqMethod == HttpPost:
    var body: JsonNode
    try:
      body = parseJson(req.body)
    except CatchableError:
      await respondJson(req, Http400, %*{"error": "invalid JSON body"})
      return
    let name = body{"name"}.getStr("").strip()
    let trigger = body{"trigger_spec"}.getStr(body{"trigger"}.getStr(""))
    let procedure = body{"procedure_spec"}.getStr(body{"procedure"}.getStr(""))
    let skillCode = body{"skill_code"}.getStr("")
    if name.len == 0 or trigger.len == 0 or procedure.len == 0 or skillCode.len == 0:
      await respondJson(req, Http400, %*{"error": "name, trigger_spec, procedure_spec and skill_code are required"})
      return
    let id = newId("skill")
    let ts = nowF()
    discard store.exec("INSERT INTO skills (skill_id, tenant_id, name, domain, trigger_spec, procedure_spec, skill_code, reward, active, created_at, updated_at) VALUES (?,?,?,?,?,?,?,0.0,1,?,?) ON CONFLICT(tenant_id,name) DO UPDATE SET domain=excluded.domain,trigger_spec=excluded.trigger_spec,procedure_spec=excluded.procedure_spec,skill_code=excluded.skill_code,active=1,updated_at=excluded.updated_at",
      @[%id, %tenantId, %name, %body{"domain"}.getStr("general"), %trigger, %procedure, %skillCode, %ts, %ts])
    await respondJson(req, Http201, %*{"accepted": true, "name": name})
    return
  await respondJson(req, Http404, %*{"error": "endpoint not found"})

