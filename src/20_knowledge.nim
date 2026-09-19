const StopWords = ["the", "and", "for", "with", "that", "this", "from", "into", "have", "has", "are", "was", "were", "not", "but", "you", "your", "then", "than", "will", "can", "any", "all", "its"]

proc tokenizeText(s: string): seq[string] =
  result = @[]
  var current = newStringOfCap(32)
  for ch in s:
    if ch.isAlphaNumeric() or ch == '_':
      current.add(ch.toLowerAscii())
    else:
      if current.len >= 2:
        result.add(current)
      current.setLen(0)
  if current.len >= 2:
    result.add(current)

proc contentTerms(s: string): seq[string] =
  result = @[]
  for term in tokenizeText(s):
    if term notin StopWords:
      result.add(term)

proc positiveEnvInt(name: string, fallback: int): int

proc textEmbedding(text: string, dims: int = EmbeddingDim): Future[seq[float]] {.async.} =
  let input = text.strip()
  if input.len == 0:
    return @[]
  let key = getEnv("REQUESTY_API_KEY", "").strip()
  if key.len == 0:
    raise newException(IOError, "REQUESTY_API_KEY is required for semantic embeddings")
  let model = envTrim("EMBEDDING_MODEL", "openai/text-embedding-3-small")
  let baseUrl = stripTrailingSlash(if RequestyBaseUrl.len > 0: RequestyBaseUrl else: DefaultRequestyBaseUrl)
  var client = newAsyncHttpClient(maxRedirects = 0)
  client.timeout = positiveEnvInt("EMBEDDING_HTTP_TIMEOUT_MS", 60000)
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  var requestBody = %*{"model": model, "input": input}
  if dims > 0:
    requestBody["dimensions"] = %dims
  try:
    let response = await client.request(baseUrl & "/embeddings", httpMethod = HttpPost, body = $requestBody)
    let responseBody = await response.body()
    if response.code.int < 200 or response.code.int >= 300:
      raise newException(IOError, "embedding provider status " & $response.code.int & ": " & responseBody)
    if responseBody.len > positiveEnvInt("EMBEDDING_RESPONSE_MAX_BYTES", 8 * 1024 * 1024):
      raise newException(IOError, "embedding response exceeded configured size limit")
    let parsed = parseJson(responseBody)
    if parsed{"data"}.kind != JArray or parsed["data"].elems.len == 0 or parsed["data"][0]{"embedding"}.kind != JArray:
      raise newException(IOError, "embedding provider returned no embedding vector")
    for item in parsed["data"][0]["embedding"].elems:
      if item.kind notin {JInt, JFloat}:
        raise newException(IOError, "embedding provider returned a non-numeric embedding value")
      result.add(item.getFloat())
    if result.len == 0:
      raise newException(IOError, "embedding provider returned an empty embedding vector")
  finally:
    client.close()

proc cosineSimilarity(a, b: seq[float]): float =
  if a.len == 0 or a.len != b.len:
    return 0.0
  result = 0.0
  for i in 0 ..< a.len:
    result += a[i] * b[i]

proc embToJson(v: seq[float]): string =
  var arr = newJArray()
  for value in v:
    arr.add(%value)
  result = $arr

proc jsonToEmb(s: string): seq[float] =
  result = @[]
  if s.len == 0:
    return
  try:
    let node = parseJson(s)
    if node.kind == JArray:
      for item in node.elems:
        result.add(item.getFloat())
  except CatchableError:
    result = @[]

proc rrfFuse(dense, sparse: seq[(string, float)], limit: int): seq[(string, float)] =
  var fused = initTable[string, float]()
  for i, item in dense:
    fused[item[0]] = fused.getOrDefault(item[0], 0.0) + 1.0 / (RrfK + (i + 1).float)
  for i, item in sparse:
    fused[item[0]] = fused.getOrDefault(item[0], 0.0) + 1.0 / (RrfK + (i + 1).float)
  result = @[]
  for key, score in fused:
    result.add((key, score))
  result.sort(proc(a, b: (string, float)): int = cmp(b[1], a[1]))
  if limit >= 0 and result.len > limit:
    result.setLen(limit)

proc updatePolicyWeight(tenantId, token: string, delta: float) =
  let key = token.strip().toLowerAscii()
  if key.len == 0:
    return
  discard store.exec("INSERT INTO policy_weights (tenant_id,token,weight,updates,updated_at) VALUES (?,?,?,1,?) ON CONFLICT(tenant_id,token) DO UPDATE SET weight=policy_weights.weight*0.95+excluded.weight*0.05,updates=policy_weights.updates+1,updated_at=excluded.updated_at", @[%tenantId, %key, %delta, %nowF()])

proc searchSkills(tenantId, queryText: string, limit: int): Future[seq[Row]] {.async.} =
  let rows = store.query("SELECT * FROM skills WHERE tenant_id=? AND active=1", @[%tenantId])
  if rows.len == 0:
    return @[]
  let actualLimit = max(1, limit)
  let qEmb = await textEmbedding(queryText)
  var dense: seq[(string, float)] = @[]
  var sparse: seq[(string, float)] = @[]
  var byId = initTable[string, Row]()
  let qTerms = contentTerms(queryText).toHashSet()
  for row in rows:
    let id = row.getStr("skill_id")
    if id.len == 0:
      continue
    byId[id] = row
    let corpus = row.getStr("name") & " " & row.getStr("domain") & " " & row.getStr("trigger_spec") & " " & row.getStr("procedure_spec") & " " & row.getStr("skill_code")
    var embedding = jsonToEmb(row.getStr("embedding_json"))
    if embedding.len != qEmb.len:
      embedding = await textEmbedding(corpus)
      discard store.exec("UPDATE skills SET embedding_json=?,updated_at=? WHERE skill_id=?", @[%embToJson(embedding), %nowF(), %id])
    dense.add((id, cosineSimilarity(qEmb, embedding)))
    let overlap = intersection(qTerms, contentTerms(corpus).toHashSet()).len.float
    if overlap > 0.0:
      sparse.add((id, overlap))
  dense.sort(proc(a, b: (string, float)): int = cmp(b[1], a[1]))
  sparse.sort(proc(a, b: (string, float)): int = cmp(b[1], a[1]))
  if fts5Available:
    let terms = contentTerms(queryText)
    if terms.len > 0:
      let ftsQuery = terms.mapIt(it.replace("\"", "")).join(" OR ")
      try:
        let ftsRows = store.query("SELECT skill_id, rank FROM skill_fts WHERE skill_fts MATCH ? AND tenant_id=? ORDER BY rank LIMIT ?", @[%ftsQuery, %tenantId, %(actualLimit * 8)])
        sparse = @[]
        for row in ftsRows:
          sparse.add((row.getStr("skill_id"), -row.getFloat("rank", 0.0)))
      except CatchableError:
        discard
  let fused = rrfFuse(dense, sparse, actualLimit * 4)
  var scored: seq[(Row, float)] = @[]
  for item in fused:
    if not byId.hasKey(item[0]):
      continue
    let row = byId[item[0]]
    let successes = row.getInt("success_count").float
    let failures = row.getInt("failure_count").float
    let prior = (successes + 1.0) / (successes + failures + 2.0)
    scored.add((row, item[1] * 100.0 + prior * 2.0 + row.getFloat("reward") * 0.5))
  scored.sort(proc(a, b: (Row, float)): int = cmp(b[1], a[1]))
  result = @[]
  for i in 0 ..< min(actualLimit, scored.len):
    result.add(scored[i][0])

proc learnedPolicySignals(tenantId, context: string, limit: int = 16): string =
  let rows = store.query("SELECT token,weight,updates FROM policy_weights WHERE tenant_id=? AND ABS(weight)>=0.02 ORDER BY ABS(weight) DESC,updates DESC", @[%tenantId])
  if rows.len == 0:
    return "No learned policy signals are available yet."
  let ctxTerms = contentTerms(context).toHashSet()
  var ranked: seq[(string, float, float, int64)] = @[]
  for row in rows:
    let key = row.getStr("token").strip()
    if key.len == 0:
      continue
    let parts = contentTerms(key)
    var overlap = 0
    for part in parts:
      if part in ctxTerms:
        inc overlap
    let relevance = if parts.len == 0: 0.0 else: overlap.float / parts.len.float
    let weight = row.getFloat("weight")
    let updates = row.getInt("updates")
    ranked.add((key, abs(weight) * (1.0 + relevance * 2.0), weight, updates))
  ranked.sort(proc(a, b: (string, float, float, int64)): int = cmp(b[1], a[1]))
  var lines: seq[string] = @[]
  for i in 0 ..< min(max(1, limit), ranked.len):
    let item = ranked[i]
    lines.add((if item[2] >= 0.0: "FAVOR " else: "AVOID ") & item[0] & " weight=" & formatFloat(item[2], ffDecimal, 4) & " evidence=" & $item[3])
  result = lines.join("\n")

proc searchKnowledge(tenantId, queryText: string, limit: int): Future[seq[Row]] {.async.} =
  let rows = store.query("SELECT * FROM knowledge_docs WHERE tenant_id=?", @[%tenantId])
  if rows.len == 0:
    return @[]
  let actualLimit = max(1, limit)
  let qEmb = await textEmbedding(queryText)
  let qTerms = contentTerms(queryText).toHashSet()
  var scored: seq[(Row, float)] = @[]
  for row in rows:
    let corpus = row.getStr("slug") & " " & row.getStr("category") & " " & row.getStr("content")
    let dense = cosineSimilarity(qEmb, await textEmbedding(corpus))
    let sparse = intersection(qTerms, contentTerms(corpus).toHashSet()).len.float
    scored.add((row, dense + sparse * 0.2))
  scored.sort(proc(a, b: (Row, float)): int = cmp(b[1], a[1]))
  result = @[]
  for i in 0 ..< min(actualLimit, scored.len):
    result.add(scored[i][0])

proc positiveEnvInt(name: string, fallback: int): int =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return fallback
  try:
    let parsed = parseInt(raw)
    if parsed > 0:
      return parsed
  except ValueError:
    discard
  fallback

proc digestOf(node: JsonNode): string =
  sha1Hex(canonical(node))

proc stalenessEncoding(elapsed: float): JsonNode =
  result = newJArray()
  for k in 0 ..< 4:
    let freq = pow(10.0, float(k) * 2.0 / 8.0)
    result.add(%sin(elapsed / freq))
    result.add(%cos(elapsed / freq))

proc policyNgrams(text: string, maxN: int = 3): seq[string] =
  let terms = contentTerms(text)
  var seen = initHashSet[string]()
  for n in 1 .. max(1, maxN):
    if terms.len < n:
      break
    for i in 0 .. terms.len - n:
      let key = terms[i ..< i + n].join(" ")
      if key.len >= 2 and key notin seen:
        seen.incl(key)
        result.add(key)

proc sanitizeKnowledgeName(s: string): string

proc safeJoin(tenant, rel: string): string =
  let tenantId = tenant.strip()
  if tenantId.len == 0:
    raise newException(ValueError, "tenant id is required")
  if tenantId in [".", ".."] or tenantId.contains("/") or tenantId.contains("\\") or '\0' in tenantId:
    raise newException(ValueError, "invalid tenant id")
  let tenantDir = sanitizeKnowledgeName(tenantId) & "-" & sha1Hex(tenantId)[0 .. 15]
  let workspaceBase = absolutePath(WorkspaceRoot)
  createDir(workspaceBase)
  if symlinkExists(workspaceBase):
    raise newException(ValueError, "workspace root cannot be a symbolic link")
  let base = absolutePath(workspaceBase / tenantDir)
  let rootClean = if workspaceBase.endsWith($DirSep): workspaceBase else: workspaceBase & $DirSep
  if not base.startsWith(rootClean):
    raise newException(ValueError, "tenant workspace escapes workspace root")
  if symlinkExists(base):
    raise newException(ValueError, "tenant workspace cannot be a symbolic link")
  createDir(base)
  let baseClean = if base.endsWith($DirSep): base else: base & $DirSep
  var cleaned = rel.replace('\\', '/')
  while cleaned.startsWith("/"):
    if cleaned.len == 1:
      cleaned = ""
    else:
      cleaned = cleaned[1 .. ^1]
  var parts: seq[string] = @[]
  for seg in cleaned.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    if seg == "..":
      if parts.len == 0:
        raise newException(ValueError, "path escapes workspace sandbox")
      parts.setLen(parts.len - 1)
      continue
    if '\0' in seg:
      raise newException(ValueError, "invalid path segment")
    parts.add(seg)
  var current = base
  for seg in parts:
    current = current / seg
    if symlinkExists(current):
      raise newException(ValueError, "symbolic links are not allowed in workspace paths")
  let cleanedPath = parts.join($DirSep)
  let full = if cleanedPath.len == 0: base else: absolutePath(baseClean / cleanedPath)
  if not (full == base or full.startsWith(baseClean)):
    raise newException(ValueError, "path escapes workspace sandbox")
  result = full

proc atomicWrite(full, content: string) =
  createDir(parentDir(full))
  let tmp = full & ".tmp." & $getTime().toUnix() & "." & newId("t")
  try:
    writeFile(tmp, content)
    moveFile(tmp, full)
  finally:
    if fileExists(tmp):
      try:
        removeFile(tmp)
      except CatchableError:
        discard

proc readLinesOf(full: string): seq[string] =
  if not fileExists(full):
    return @[]
  let raw = readFile(full)
  if raw.len == 0:
    return @[]
  result = raw.splitLines()
  if result.len > 0 and result[^1].len == 0 and raw.endsWith("\n"):
    result.setLen(result.len - 1)

proc evalMathExpression(expr: string): (bool, float, string) =
  var pos = 0
  var failed = false
  var errMsg = ""

  proc fail(msg: string): float =
    if not failed:
      failed = true
      errMsg = msg
    0.0

  proc skipWs() =
    while pos < expr.len and expr[pos] in {' ', '\t', '\r', '\n'}:
      inc pos

  proc parseExpr(): float
  proc parseUnary(): float

  proc parseNumber(): float =
    skipWs()
    let start = pos
    var sawDigit = false
    while pos < expr.len and expr[pos].isDigit():
      sawDigit = true
      inc pos
    if pos < expr.len and expr[pos] == '.':
      inc pos
      while pos < expr.len and expr[pos].isDigit():
        sawDigit = true
        inc pos
    if not sawDigit:
      return fail("invalid numeric literal at pos " & $start)
    if pos < expr.len and expr[pos] in {'e', 'E'}:
      let expStart = pos
      inc pos
      if pos < expr.len and expr[pos] in {'+', '-'}:
        inc pos
      let digitsStart = pos
      while pos < expr.len and expr[pos].isDigit():
        inc pos
      if pos == digitsStart:
        pos = expStart
        return fail("invalid numeric exponent at pos " & $expStart)
    try:
      result = parseFloat(expr[start ..< pos])
    except CatchableError:
      result = fail("invalid numeric literal at pos " & $start)

  proc parsePrimary(): float =
    skipWs()
    if pos >= expr.len:
      return fail("unexpected end of expression")
    if expr[pos] == '(':
      inc pos
      let value = parseExpr()
      skipWs()
      if pos >= expr.len or expr[pos] != ')':
        return fail("missing closing parenthesis")
      inc pos
      return value
    if expr[pos].isAlphaAscii():
      var name = ""
      while pos < expr.len and (expr[pos].isAlphaNumeric() or expr[pos] == '_'):
        name.add(expr[pos].toLowerAscii())
        inc pos
      skipWs()
      if name == "pi" and (pos >= expr.len or expr[pos] != '('):
        return PI
      if name == "e" and (pos >= expr.len or expr[pos] != '('):
        return E
      if pos >= expr.len or expr[pos] != '(':
        return fail("unknown constant or symbol: " & name)
      inc pos
      let a = parseExpr()
      skipWs()
      if pos >= expr.len or expr[pos] != ')':
        return fail("missing closing parenthesis")
      inc pos
      if failed:
        return 0.0
      case name
      of "sin": return sin(a)
      of "cos": return cos(a)
      of "tan": return tan(a)
      of "sqrt":
        if a < 0.0: return fail("domain error: sqrt of negative")
        return sqrt(a)
      of "abs": return abs(a)
      of "ln":
        if a <= 0.0: return fail("domain error: ln non-positive")
        return ln(a)
      of "log10":
        if a <= 0.0: return fail("domain error: log10 non-positive")
        return log10(a)
      of "exp": return exp(a)
      of "floor": return floor(a)
      of "ceil": return ceil(a)
      of "round": return round(a)
      else: return fail("unknown function: " & name)
    if expr[pos].isDigit() or expr[pos] == '.':
      return parseNumber()
    fail("invalid token at pos " & $pos)

  proc parsePower(): float =
    var value = parsePrimary()
    if failed:
      return 0.0
    skipWs()
    if pos + 1 < expr.len and expr[pos] == '*' and expr[pos + 1] == '*':
      pos += 2
      let rhs = parseUnary()
      if failed: return 0.0
      value = pow(value, rhs)
    elif pos < expr.len and expr[pos] == '^':
      inc pos
      let rhs = parseUnary()
      if failed: return 0.0
      value = pow(value, rhs)
    value

  proc parseUnary(): float =
    skipWs()
    if pos < expr.len and expr[pos] == '+':
      inc pos
      return parseUnary()
    if pos < expr.len and expr[pos] == '-':
      inc pos
      return -parseUnary()
    parsePower()

  proc parseTerm(): float =
    var value = parseUnary()
    while not failed:
      skipWs()
      if pos < expr.len and expr[pos] == '*' and not (pos + 1 < expr.len and expr[pos + 1] == '*'):
        inc pos
        value *= parseUnary()
      elif pos < expr.len and expr[pos] == '/':
        inc pos
        let d = parseUnary()
        if abs(d) < 1e-15: return fail("division by zero")
        value /= d
      elif pos < expr.len and expr[pos] == '%':
        inc pos
        let d = parseUnary()
        if abs(d) < 1e-15: return fail("modulo by zero")
        value = value - d * floor(value / d)
      else:
        break
    value

  proc parseExpr(): float =
    var value = parseTerm()
    while not failed:
      skipWs()
      if pos < expr.len and expr[pos] == '+':
        inc pos
        value += parseTerm()
      elif pos < expr.len and expr[pos] == '-':
        inc pos
        value -= parseTerm()
      else:
        break
    value

  let value = parseExpr()
  skipWs()
  if not failed and pos != expr.len:
    discard fail("trailing unparsed token at pos " & $pos)
  if failed:
    result = (false, 0.0, errMsg)
  else:
    result = (true, value, "")

proc sanitizeKnowledgeName(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.'}:
      result.add(ch)
    elif ch in {' ', '/', '\\', ':'}:
      result.add('-')
  while result.contains("--"):
    result = result.replace("--", "-")
  result = result.strip(chars = {'-', '.'})
  if result.len == 0:
    result = "entry"
  if result.len > 96:
    result.setLen(96)

proc runGit(repo: string, args: seq[string]): Future[(int, string)] {.async.} =
  var process: Process
  try:
    process = startProcess("git", workingDir = repo, args = args,
      options = {poUsePath, poStdErrToStdOut})
    while process.running():
      await sleepAsync(10)
    let exitCode = process.waitForExit(0)
    let output = process.outputStream().readAll()
    process.close()
    return (exitCode, output)
  except CatchableError:
    if not process.isNil:
      try:
        process.close()
      except CatchableError:
        discard
    raise

proc ensureKnowledgeRepo(tenant: string): Future[string] {.async.} =
  let tenantId = tenant.strip()
  if tenantId.len == 0:
    raise newException(ValueError, "tenant id is required")
  let safeTenant = sanitizeKnowledgeName(tenantId) & "-" & sha1Hex(tenantId)[0 .. 15]
  let root = absolutePath(knowledgeRoot)
  createDir(root)
  let dir = absolutePath(root / safeTenant)
  let rootClean = if root.endsWith($DirSep): root else: root & $DirSep
  if not dir.startsWith(rootClean):
    raise newException(ValueError, "knowledge repository escapes configured root")
  createDir(dir)
  if not dirExists(dir / ".git"):
    let initRes = await runGit(dir, @["init"])
    if initRes[0] != 0:
      raise newException(IOError, "git init failed: " & initRes[1])
    let emailRes = await runGit(dir, @["config", "user.email", "agent@runtime.local"])
    if emailRes[0] != 0:
      raise newException(IOError, "git config failed: " & emailRes[1])
    let nameRes = await runGit(dir, @["config", "user.name", "AutonomousRuntime"])
    if nameRes[0] != 0:
      raise newException(IOError, "git config failed: " & nameRes[1])
  result = dir

proc commitKnowledgeDoc(tenant, slug, category, body: string): Future[string] {.async.} =
  let repo = await ensureKnowledgeRepo(tenant)
  let safeSlug = sanitizeKnowledgeName(slug) & "-" & sha1Hex(slug)[0 .. 15]
  let safeCategory = sanitizeKnowledgeName(category) & "-" & sha1Hex(category)[0 .. 15]
  let rel = safeCategory & "_" & safeSlug & ".md"
  let full = repo / rel
  let contentHash = sha1Hex(body)
  let existing = store.query("SELECT doc_id,content_hash,git_commit_hash FROM knowledge_docs WHERE tenant_id=? AND slug=?", @[%tenant, %slug])
  if existing.len > 0 and existing[0].getStr("content_hash") == contentHash and fileExists(full):
    return existing[0].getStr("doc_id")
  atomicWrite(full, "# " & slug & "\nCategory: " & category & "\n\n" & body & "\n")
  let addRes = await runGit(repo, @["add", "--", rel])
  if addRes[0] != 0:
    raise newException(IOError, "git add failed: " & addRes[1])
  let commitRes = await runGit(repo, @["commit", "-m", "knowledge update: " & safeSlug])
  if commitRes[0] != 0:
    let statusRes = await runGit(repo, @["status", "--porcelain", "--", rel])
    if statusRes[0] != 0 or statusRes[1].strip().len > 0:
      raise newException(IOError, "git commit failed: " & commitRes[1])
  let revRes = await runGit(repo, @["rev-parse", "HEAD"])
  if revRes[0] != 0:
    raise newException(IOError, "git rev-parse failed: " & revRes[1])
  let commitHash = revRes[1].strip()
  let docId = if existing.len > 0: existing[0].getStr("doc_id") else: newId("doc")
  let ts = nowF()
  discard store.exec("INSERT INTO knowledge_docs (doc_id,tenant_id,slug,category,path,content_hash,git_commit_hash,content,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(tenant_id,slug) DO UPDATE SET category=excluded.category,path=excluded.path,content_hash=excluded.content_hash,git_commit_hash=excluded.git_commit_hash,content=excluded.content,updated_at=excluded.updated_at",
    @[%docId, %tenant, %slug, %category, %rel, %contentHash, %commitHash, %body, %ts, %ts])
  result = docId

