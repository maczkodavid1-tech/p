type
  DslInstruction = object
    keyword: string
    value: string

proc removeTree(path: string) =
  if not dirExists(path):
    return
  var children: seq[(PathComponent, string)] = @[]
  for kind, child in walkDir(path):
    children.add((kind, child))
  for item in children:
    case item[0]
    of pcDir:
      removeTree(item[1])
    of pcFile, pcLinkToFile, pcLinkToDir:
      try:
        removeFile(item[1])
      except CatchableError:
        try:
          removeDir(item[1])
        except CatchableError:
          discard
  try:
    removeDir(path)
  except CatchableError:
    discard

proc ensureDiagnosticSuite(tenantId: string) =
  let existing = store.query("SELECT domain FROM diagnostics WHERE tenant_id=?", @[%tenantId])
  var domains = initHashSet[string]()
  for row in existing:
    domains.incl(row.getStr("domain"))
  let definitions = @[
    ("arithmetic_rollout", %*{"goal": "Compute (17 * 6) + 5 with the deterministic math evaluator and store 107 in facts.answer.", "operation": "math", "expression": "(17 * 6) + 5"}, %*{"verifiers": [{"type": "state_path_equals", "path": "/facts/answer", "expected": 107}, {"type": "state_path_equals", "path": "/progress", "expected": 1.0}]}),
    ("filesystem_rollout", %*{"goal": "Create regression/output.txt with validation-gate-ok and verify the real file.", "operation": "file", "path": "regression/output.txt", "content": "validation-gate-ok\n"}, %*{"verifiers": [{"type": "file_contains", "path": "regression/output.txt", "needle": "validation-gate-ok"}, {"type": "state_path_equals", "path": "/progress", "expected": 1.0}]}),
    ("memory_rollout", %*{"goal": "Retrieve a reusable skill for file operations.", "operation": "memory", "query": "sandboxed file operations"}, %*{"verifiers": [{"type": "state_path_equals", "path": "/facts/memory_routed", "expected": true}, {"type": "state_path_equals", "path": "/progress", "expected": 1.0}]})
  ]
  for definition in definitions:
    if definition[0] in domains:
      continue
    discard store.exec("INSERT INTO diagnostics (diagnostic_id,tenant_id,domain,spec_json,expectation_json,created_at) VALUES (?,?,?,?,?,?)",
      @[%newId("diag"), %tenantId, %definition[0], %canonical(definition[1]), %canonical(definition[2]), %nowF()])

proc verifyDiagnosticSnapshot(sandboxTenant: string, expectation, sigma: JsonNode): (bool, JsonNode) =
  var report = newJArray()
  var allOk = true
  let verifiers = if not expectation.isNil and expectation.kind == JObject and expectation.hasKey("verifiers") and expectation["verifiers"].kind == JArray:
      expectation["verifiers"]
    elif not expectation.isNil and expectation.kind == JArray:
      expectation
    else:
      newJArray()
  if verifiers.elems.len == 0:
    return (false, %*[{"verifier": "configuration", "ok": false, "error": "diagnostic has no verifiers"}])
  for verifier in verifiers.elems:
    if verifier.kind != JObject:
      allOk = false
      report.add(%*{"verifier": "invalid", "ok": false})
      continue
    let kind = verifier{"type"}.getStr("")
    case kind
    of "state_path_equals":
      let path = verifier{"path"}.getStr("")
      let actual = jsonPointerGet(sigma, path)
      let expected = if verifier.hasKey("expected"): verifier["expected"] else: newJNull()
      let ok = not actual.isNil and jsonEquivalent(actual, expected)
      if not ok: allOk = false
      report.add(%*{"verifier": kind, "path": path, "ok": ok, "expected": expected, "actual": (if actual.isNil: newJNull() else: copy(actual))})
    of "file_exists":
      let rel = verifier{"path"}.getStr("")
      var ok = false
      try:
        ok = rel.len > 0 and fileExists(safeJoin(sandboxTenant, rel))
      except CatchableError:
        ok = false
      if not ok: allOk = false
      report.add(%*{"verifier": kind, "path": rel, "ok": ok})
    of "file_contains":
      let rel = verifier{"path"}.getStr("")
      let needle = verifier{"needle"}.getStr("")
      var ok = false
      try:
        let full = safeJoin(sandboxTenant, rel)
        ok = fileExists(full) and needle.len > 0 and needle in readFile(full)
      except CatchableError:
        ok = false
      if not ok: allOk = false
      report.add(%*{"verifier": kind, "path": rel, "needle": needle, "ok": ok})
    of "all_subgoals_resolved":
      var unresolved = 0
      if sigma.hasKey("subgoals") and sigma["subgoals"].kind == JArray:
        for item in sigma["subgoals"].elems:
          if item.kind == JObject and item{"status"}.getStr("open") in ["open", "in_progress", "queued", "running"]:
            inc unresolved
      let ok = unresolved == 0
      if not ok: allOk = false
      report.add(%*{"verifier": kind, "ok": ok, "unresolved": unresolved})
    of "no_blockers":
      let count = if sigma.hasKey("blockers") and sigma["blockers"].kind == JArray: sigma["blockers"].elems.len else: 0
      let ok = count == 0
      if not ok: allOk = false
      report.add(%*{"verifier": kind, "ok": ok, "blockers_count": count})
    else:
      allOk = false
      report.add(%*{"verifier": kind, "ok": false, "error": "unsupported diagnostic verifier"})
  (allOk, report)

proc validateSkillDsl(code: string): (bool, seq[string])

proc diagnosticAllowedTools(tenantId: string): HashSet[string] =
  allowedToolsForTenant(tenantId)

proc gatePythonProgram(skillCode: string, spec, expectation: JsonNode, observed: JsonNode): string =
  let code64 = base64.encode(skillCode)
  let spec64 = base64.encode(canonical(spec))
  let expectation64 = base64.encode(canonical(expectation))
  let observed64 = base64.encode(canonical(observed))
  result = "import ast,base64,json,math,os,pathlib,sys\n" &
    "dsl=base64.b64decode(" & escapeJson(code64) & ").decode()\n" &
    "spec=json.loads(base64.b64decode(" & escapeJson(spec64) & "))\n" &
    "expectation=json.loads(base64.b64decode(" & escapeJson(expectation64) & "))\n" &
    "observed=json.loads(base64.b64decode(" & escapeJson(observed64) & "))\n" &
    "root=(pathlib.Path.cwd()/'validation_sandbox').resolve()\n" &
    "root.mkdir(parents=True,exist_ok=True)\n" &
    "state={'facts':{},'progress':0.0,'subgoals':[],'blockers':[]}\n" &
    "errors=[]\n" &
    "trace=[]\n" &
    "operation_result={}\n" &
    "operation_done=False\n" &
    "def safe_path(rel):\n" &
    " p=(root/rel).resolve()\n" &
    " if root not in p.parents: raise RuntimeError('path escapes sandbox')\n" &
    " return p\n" &
    "def eval_math(node):\n" &
    " if isinstance(node,ast.Expression): return eval_math(node.body)\n" &
    " if isinstance(node,ast.Constant) and isinstance(node.value,(int,float)): return node.value\n" &
    " if isinstance(node,ast.UnaryOp):\n" &
    "  value=eval_math(node.operand)\n" &
    "  if isinstance(node.op,ast.UAdd): return value\n" &
    "  if isinstance(node.op,ast.USub): return -value\n" &
    " if isinstance(node,ast.BinOp):\n" &
    "  left=eval_math(node.left); right=eval_math(node.right)\n" &
    "  if isinstance(node.op,ast.Add): return left+right\n" &
    "  if isinstance(node.op,ast.Sub): return left-right\n" &
    "  if isinstance(node.op,ast.Mult): return left*right\n" &
    "  if isinstance(node.op,ast.Div): return left/right\n" &
    "  if isinstance(node.op,ast.Mod): return left%right\n" &
    "  if isinstance(node.op,ast.Pow): return left**right\n" &
    " raise RuntimeError('unsupported expression')\n" &
    "def execute_operation():\n" &
    " global operation_done,operation_result\n" &
    " if operation_done: return\n" &
    " operation=spec.get('operation','')\n" &
    " if operation=='math':\n" &
    "  value=eval_math(ast.parse(spec.get('expression',''),mode='eval'))\n" &
    "  state['facts']['answer']=value; state['progress']=1.0\n" &
    "  operation_result={'ok':True,'value':value}\n" &
    " elif operation=='file':\n" &
    "  target=safe_path(spec.get('path','')); content=spec.get('content','')\n" &
    "  target.parent.mkdir(parents=True,exist_ok=True); target.write_text(content)\n" &
    "  actual=target.read_text(); ok=target.is_file() and actual==content\n" &
    "  state['progress']=1.0 if ok else 0.0\n" &
    "  operation_result={'ok':ok,'path':spec.get('path',''),'output':actual}\n" &
    " elif operation=='memory':\n" &
    "  hits=int(observed.get('memory_hits',0)); state['facts']['memory_routed']=hits>0\n" &
    "  state['progress']=1.0 if hits>0 else 0.0\n" &
    "  operation_result={'ok':hits>0,'hits':hits,'query':spec.get('query','')}\n" &
    " else: raise RuntimeError('unsupported diagnostic operation')\n" &
    " operation_done=True\n" &
    "def verify_expectations():\n" &
    " verifiers=expectation.get('verifiers',expectation if isinstance(expectation,list) else [])\n" &
    " if not verifiers: raise RuntimeError('diagnostic has no verifiers')\n" &
    " for verifier in verifiers:\n" &
    "  kind=verifier.get('type','')\n" &
    "  if kind=='state_path_equals':\n" &
    "   current=state\n" &
    "   for part in verifier.get('path','').strip('/').split('/'):\n" &
    "    current=current.get(part) if isinstance(current,dict) else None\n" &
    "   if current!=verifier.get('expected'): raise RuntimeError('state verification failed: '+verifier.get('path',''))\n" &
    "  elif kind=='file_exists':\n" &
    "   if not safe_path(verifier.get('path','')).is_file(): raise RuntimeError('file existence verification failed')\n" &
    "  elif kind=='file_contains':\n" &
    "   target=safe_path(verifier.get('path',''))\n" &
    "   if not target.is_file() or verifier.get('needle','') not in target.read_text(): raise RuntimeError('file content verification failed')\n" &
    "  elif kind=='all_subgoals_resolved':\n" &
    "   if any(item.get('status') in ('open','in_progress','queued','running') for item in state.get('subgoals',[])): raise RuntimeError('subgoals remain unresolved')\n" &
    "  elif kind=='no_blockers':\n" &
    "   if state.get('blockers'): raise RuntimeError('blockers remain')\n" &
    "  else: raise RuntimeError('unsupported diagnostic verifier')\n" &
    "context={'completion_criteria':bool(expectation.get('verifiers',[])),'actual_file_state':False,'real_runtime_output':False,'browser_session':False,'image_generate_tool':False}\n" &
    "def run_instruction(keyword,value):\n" &
    " if keyword=='WHEN':\n" &
    "  if not value: raise RuntimeError('empty trigger')\n" &
    " elif keyword=='REQUIRE':\n" &
    "  if not context.get(value,False): raise RuntimeError('required runtime capability unavailable: '+value)\n" &
    " elif keyword=='STEP':\n" &
    "  if value in ('inspect','observe','diagnose','execute','modify','interact','repair','rerun'):\n" &
    "   execute_operation(); context['actual_file_state']=bool(operation_result.get('ok')); context['real_runtime_output']=bool(operation_result)\n" &
    "  else: raise RuntimeError('unsupported executable DSL step: '+value)\n" &
    " elif keyword=='VERIFY':\n" &
    "  if value not in ('reread_or_execute','completion_criteria_satisfied','zero_errors_remaining','requested_behavior','target_state','artifact_exists'):\n" &
    "   raise RuntimeError('unsupported executable DSL verifier: '+value)\n" &
    "  execute_operation(); verify_expectations()\n" &
    " elif keyword=='RECOVER':\n" &
    "  trace.append({'recover':value})\n" &
    "try:\n" &
    " for raw in dsl.splitlines():\n" &
    "  line=raw.strip()\n" &
    "  if line:\n" &
    "   parts=line.split(None,1)\n" &
    "   run_instruction(parts[0].upper(),parts[1].strip() if len(parts)>1 else '''')\n" &
    "except Exception as error:\n" &
    " errors.append(str(error))\n" &
    "print(json.dumps({'passed':not errors,'operation':operation_result,'state':state,'trace':trace,'errors':errors},separators=(',',':')))\n"

proc runGateSandbox(skillCode: string, spec, expectation: JsonNode, observed: JsonNode): Future[JsonNode] {.async.} =
  let createBody = %*{
    "api_key": requireEnv("INSTAVM_API_KEY"),
    "vm_lifetime_seconds": 900,
    "memory_mb": VmDefaultMemoryMb,
    "vcpu_count": VmDefaultVcpuCount,
    "metadata": {"purpose": "validation_gate"},
    "env": newJObject(),
    "prewarm": false
  }
  let (createStatus, createRaw, _) = await httpRequestAsync(InstaVmBaseUrl & "/v1/sessions/session", HttpPost, $createBody, instavmHeaders())
  if createStatus < 200 or createStatus >= 300:
    return %*{"passed": false, "error": "sandbox VM creation failed", "status": createStatus, "body": createRaw}
  var sessionId = ""
  try:
    let session = parseJson(createRaw)
    sessionId = session{"session_id"}.getStr(session{"id"}.getStr(""))
    if sessionId.len == 0:
      return %*{"passed": false, "error": "sandbox VM response has no session id"}
    let body = %*{
      "command": gatePythonProgram(skillCode, spec, expectation, observed),
      "session_id": sessionId,
      "language": "python"
    }
    let (status, raw, _) = await httpRequestAsync(InstaVmBaseUrl & "/execute", HttpPost, $body, instavmHeaders())
    if status < 200 or status >= 300:
      return %*{"passed": false, "error": "sandbox test execution failed", "status": status, "body": raw}
    let response = parseJson(raw)
    let output = response{"output"}.getStr(response{"stdout"}.getStr(""))
    var lines = output.splitLines()
    while lines.len > 0 and lines[^1].strip().len == 0:
      lines.setLen(lines.len - 1)
    if lines.len == 0:
      return %*{"passed": false, "error": "sandbox test produced no JSON output", "response": response}
    try:
      return parseJson(lines[^1])
    except CatchableError:
      return %*{"passed": false, "error": "sandbox test produced invalid JSON output", "response": response}
  except CatchableError as e:
    return %*{"passed": false, "error": e.msg}
  finally:
    if sessionId.len > 0:
      discard await httpRequestAsync(InstaVmBaseUrl & "/v1/sessions/" & encodeUrl(sessionId), HttpDelete, "", instavmHeaders())

proc runDiagnosticRolloutCase(tenantId: string, diagnostic: Row, candidateOverride: JsonNode = nil): Future[JsonNode] {.async.} =
  let spec = diagnostic.getJson("spec_json")
  let expectation = diagnostic.getJson("expectation_json")
  let sandboxTenant = sanitizeKnowledgeName(tenantId) & "_gate_" & newId("rollout")
  var sigma = defaultSigma(spec{"goal"}.getStr("diagnostic"))
  let operation = spec{"operation"}.getStr("")
  var operationResult = newJObject()
  var candidateEvidence = newJObject()
  var observed = newJObject()
  if not candidateOverride.isNil and candidateOverride.kind == JObject:
    let skillCode = candidateOverride{"skill_code"}.getStr("")
    let validation = validateSkillDsl(skillCode)
    if not validation[0]:
      return %*{"passed": false, "domain": diagnostic.getStr("domain"), "candidate_evaluated": true, "candidate_error": "invalid candidate DSL", "validation_errors": validation[1]}
    candidateEvidence = %*{
      "name": candidateOverride{"name"}.getStr(""),
      "domain": candidateOverride{"domain"}.getStr("general"),
      "dsl_valid": true
    }
  try:
    case operation
    of "math":
      let expression = spec{"expression"}.getStr("")
      let evaluated = evalMathExpression(expression)
      if evaluated[0]:
        sigma["facts"]["answer"] = %evaluated[1]
        sigma["progress"] = %1.0
        operationResult = %*{"ok": true, "value": evaluated[1]}
      else:
        operationResult = %*{"ok": false, "error": evaluated[2]}
    of "file":
      let rel = spec{"path"}.getStr("")
      let content = spec{"content"}.getStr("")
      let full = safeJoin(sandboxTenant, rel)
      atomicWrite(full, content)
      let verified = fileExists(full) and readFile(full) == content
      if verified:
        sigma["progress"] = %1.0
      operationResult = %*{"ok": verified, "path": rel, "sha1": sha1Hex(content)}
    of "memory":
      let query = spec{"query"}.getStr("file operations")
      let hits = await searchSkills(tenantId, query, 5)
      sigma["facts"]["memory_routed"] = %(hits.len > 0)
      if hits.len > 0:
        sigma["progress"] = %1.0
      operationResult = %*{"ok": hits.len > 0, "hits": hits.len}
      observed = %*{"memory_hits": hits.len}
    else:
      operationResult = %*{"ok": false, "error": "unsupported diagnostic operation"}
    let verified = verifyDiagnosticSnapshot(sandboxTenant, expectation, sigma)
    var candidateOk = candidateOverride.isNil or candidateOverride.kind != JObject
    if not candidateOk:
      let sandboxResult = await runGateSandbox(candidateOverride{"skill_code"}.getStr(""), spec, expectation, observed)
      candidateOk = sandboxResult{"passed"}.getBool(false)
      candidateEvidence["sandbox"] = sandboxResult
    return %*{"passed": verified[0] and candidateOk, "domain": diagnostic.getStr("domain"), "operation": operationResult, "verification": verified[1], "state": sigma, "candidate_evaluated": not candidateOverride.isNil, "candidate_evidence": candidateEvidence}
  finally:
    try:
      removeTree(safeJoin(sandboxTenant, "."))
    except CatchableError:
      discard

proc validateSkillDsl(code: string): (bool, seq[string]) =
  var errors: seq[string] = @[]
  let text = code.strip()
  if text.len == 0:
    errors.add("skill_code is empty")
    return (false, errors)
  var sawWhen = false
  var sawStep = false
  var sawVerify = false
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let upper = line.toUpperAscii()
    if upper.startsWith("WHEN "):
      sawWhen = true
    elif upper.startsWith("REQUIRE "):
      discard
    elif upper.startsWith("STEP "):
      sawStep = true
    elif upper.startsWith("VERIFY "):
      sawVerify = true
    elif upper.startsWith("RECOVER "):
      discard
    else:
      errors.add("unsupported DSL statement: " & line)
  if not sawWhen: errors.add("missing WHEN statement")
  if not sawStep: errors.add("missing STEP statement")
  if not sawVerify: errors.add("missing VERIFY statement")
  (errors.len == 0, errors)

proc runRegressionGate(tenantId: string, candidateOverride: JsonNode = nil): Future[JsonNode] {.async.} =
  ensureDiagnosticSuite(tenantId)
  var tests = newJArray()
  var passed = 0
  var total = 0
  let diagnostics = store.query("SELECT * FROM diagnostics WHERE tenant_id=? ORDER BY created_at ASC", @[%tenantId])
  for diagnostic in diagnostics:
    let resultNode = await runDiagnosticRolloutCase(tenantId, diagnostic, candidateOverride)
    let ok = resultNode{"passed"}.getBool(false)
    inc total
    if ok: inc passed
    tests.add(%*{"name": "micro_rollout:" & diagnostic.getStr("domain"), "passed": ok, "executed": true, "result": resultNode})
  let stateProbe = defaultSigma("state regression")
  let patch = %*{"progress": 0.5, "facts": {"gate": true}}
  let patchValidation = validatePatch(patch)
  let merged = deepMerge(stateProbe, patch)
  let stateValidation = validateSigma(merged)
  let stateOk = patchValidation[0] and stateValidation[0] and merged{"progress"}.getFloat(0.0) == 0.5 and merged{"facts"}{"gate"}.getBool(false)
  inc total
  if stateOk: inc passed
  tests.add(%*{"name": "state_merge_validation", "passed": stateOk, "executed": true})
  let mathProbe = evalMathExpression("(17 * 6) + 5")
  let mathOk = mathProbe[0] and abs(mathProbe[1] - 107.0) < 1e-9
  inc total
  if mathOk: inc passed
  tests.add(%*{"name": "deterministic_math", "passed": mathOk, "executed": true})
  let score = if total > 0: passed.float / total.float else: 0.0
  return %*{"total": total, "passed": passed, "score": score, "tests": tests, "all_passed": passed == total}

proc coreRegressionPassed(report: JsonNode): bool =
  if report.isNil or report.kind != JObject or not report.hasKey("tests") or report["tests"].kind != JArray:
    return false
  var sawCore = false
  for test in report["tests"].elems:
    if test.kind != JObject:
      continue
    let name = test{"name"}.getStr("")
    if name.startsWith("micro_rollout:"):
      continue
    sawCore = true
    if not test{"passed"}.getBool(false):
      return false
  sawCore

proc validateAndActivate(gate: ValidationGate, tenantId: string, candidate: JsonNode): Future[JsonNode] {.async.} =
  if candidate.isNil or candidate.kind != JObject:
    return %*{"accepted": false, "error": "candidate must be an object"}
  let name = candidate{"name"}.getStr("").strip()
  let domain = candidate{"domain"}.getStr("general").strip()
  let trigger = candidate{"trigger_spec"}.getStr(candidate{"trigger"}.getStr("")).strip()
  let procedure = candidate{"procedure_spec"}.getStr(candidate{"procedure"}.getStr("")).strip()
  let skillCode = candidate{"skill_code"}.getStr("").strip()
  if name.len < 3 or trigger.len < 5 or procedure.len < 20 or skillCode.len < 20:
    return %*{"accepted": false, "error": "candidate is incomplete"}
  let dsl = validateSkillDsl(skillCode)
  if not dsl[0]:
    return %*{"accepted": false, "error": "invalid skill DSL", "validation_errors": dsl[1]}
  acquire(skillGateLock)
  if skillGateBusy:
    release(skillGateLock)
    return %*{"accepted": false, "error": "validation gate busy"}
  skillGateBusy = true
  release(skillGateLock)
  try:
    let before = await runRegressionGate(tenantId)
    let after = await runRegressionGate(tenantId, candidate)
    let accepted = coreRegressionPassed(after) and after{"all_passed"}.getBool(false) and after{"score"}.getFloat(0.0) + gate.epsilon >= before{"score"}.getFloat(0.0)
    if not accepted:
      return %*{"accepted": false, "before": before, "after": after, "reason": "candidate failed regression validation"}
    let preconditions = if candidate.hasKey("preconditions") and candidate["preconditions"].kind == JArray: canonical(candidate["preconditions"]) else: "[]"
    let postconditions = if candidate.hasKey("postconditions") and candidate["postconditions"].kind == JArray: canonical(candidate["postconditions"]) else: "[]"
    let failureModes = if candidate.hasKey("failure_modes") and candidate["failure_modes"].kind == JArray: canonical(candidate["failure_modes"]) else: "[]"
    let embedding = embToJson(await textEmbedding(name & " " & domain & " " & trigger & " " & procedure & " " & skillCode))
    let existing = store.query("SELECT skill_id FROM skills WHERE tenant_id=? AND name=?", @[%tenantId, %name])
    let ts = nowF()
    var skillId = ""
    if existing.len > 0:
      skillId = existing[0].getStr("skill_id")
      discard store.exec("UPDATE skills SET domain=?,trigger_spec=?,procedure_spec=?,skill_code=?,preconditions_json=?,postconditions_json=?,failure_modes_json=?,version=version+1,active=1,embedding_json=?,updated_at=? WHERE skill_id=? AND tenant_id=?",
        @[%domain, %trigger, %procedure, %skillCode, %preconditions, %postconditions, %failureModes, %embedding, %ts, %skillId, %tenantId])
    else:
      skillId = newId("skill")
      discard store.exec("INSERT INTO skills (skill_id,tenant_id,name,domain,trigger_spec,procedure_spec,skill_code,preconditions_json,postconditions_json,failure_modes_json,version,active,success_count,failure_count,reward,embedding_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,1,1,0,0,0.0,?,?,?)",
        @[%skillId, %tenantId, %name, %domain, %trigger, %procedure, %skillCode, %preconditions, %postconditions, %failureModes, %embedding, %ts, %ts])
    return %*{"accepted": true, "skill_id": skillId, "before": before, "after": after}
  finally:
    acquire(skillGateLock)
    skillGateBusy = false
    release(skillGateLock)

proc consider(agent: MetaAgent, tenantId: string, sourceTaskId: string = ""): Future[JsonNode] {.async.} =
  let groups = store.query("SELECT failure_point,attribution,COUNT(*) AS occurrences,MAX(created_at) AS latest FROM reflections WHERE tenant_id=? GROUP BY failure_point,attribution HAVING COUNT(*)>=? ORDER BY latest DESC LIMIT ?", @[%tenantId, %agent.minOccurrences, %agent.maxCandidates])
  var decisions = newJArray()
  for group in groups:
    let failurePoint = group.getStr("failure_point").strip()
    let attribution = group.getStr("attribution").strip()
    let occurrences = group.getInt("occurrences", 0)
    if failurePoint.len == 0:
      continue
    let signature = sha1Hex(failurePoint.toLowerAscii() & "|" & attribution.toLowerAscii())
    let prior = store.query("SELECT occurrences,status FROM meta_agent_events WHERE tenant_id=? AND signature=?", @[%tenantId, %signature])
    if prior.len > 0 and occurrences <= prior[0].getInt("occurrences", 0):
      continue
    let evidenceRows = store.query("SELECT task_id,patch_json,failure_point,pivot_action,attribution,verifier_report_json FROM reflections WHERE tenant_id=? AND failure_point=? AND attribution=? ORDER BY created_at DESC LIMIT ?", @[%tenantId, %failurePoint, %attribution, %agent.lookback])
    var evidence = newJArray()
    for row in evidenceRows:
      evidence.add(%*{"task_id": row.getStr("task_id"), "failure_point": row.getStr("failure_point"), "pivot_action": row.getStr("pivot_action"), "attribution": row.getStr("attribution"), "patch": row.getJson("patch_json"), "verifier_report": row.getJson("verifier_report_json")})
    let response = await invokeModel(mrGpt6Astra, %*[
      {"role": "system", "content": promptText("meta_skill_synthesis")},
      {"role": "user", "content": "Source task: " & sourceTaskId & "\nFailure: " & failurePoint & "\nAttribution: " & attribution & "\nOccurrences: " & $occurrences & "\nEvidence:\n" & canonical(evidence)}
    ], true, tenantId, sourceTaskId)
    let candidate = parseJsonObjectLoose(response.content)
    var validation = %*{"accepted": false, "error": "candidate generation returned invalid JSON"}
    if not candidate.isNil:
      validation = await agent.gate.validateAndActivate(tenantId, candidate)
    let status = if validation{"accepted"}.getBool(false): "accepted" else: "rejected"
    let candidateText = if candidate.isNil: "{}" else: canonical(candidate)
    discard store.exec("INSERT INTO meta_agent_events (event_id,tenant_id,signature,occurrences,candidate_json,validation_json,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(tenant_id,signature) DO UPDATE SET occurrences=excluded.occurrences,candidate_json=excluded.candidate_json,validation_json=excluded.validation_json,status=excluded.status,updated_at=excluded.updated_at",
      @[%newId("meta"), %tenantId, %signature, %occurrences, %candidateText, %canonical(validation), %status, %nowF(), %nowF()])
    decisions.add(%*{"signature": signature, "status": status, "candidate": (if candidate.isNil: newJObject() else: candidate), "validation": validation})
  return %*{"tenant_id": tenantId, "decisions": decisions, "considered": groups.len}

proc upsertSeed(name, domain, trigger, procedure, skillCode: string): Future[void] {.async.} =
  let existing = store.query("SELECT skill_id FROM skills WHERE tenant_id=? AND name=?", @[%defaultTenantId, %name])
  let embedding = embToJson(await textEmbedding(name & " " & domain & " " & trigger & " " & procedure & " " & skillCode))
  let ts = nowF()
  if existing.len > 0:
    discard store.exec("UPDATE skills SET domain=?,trigger_spec=?,procedure_spec=?,skill_code=?,embedding_json=?,active=1,updated_at=? WHERE skill_id=?",
      @[%domain, %trigger, %procedure, %skillCode, %embedding, %ts, %existing[0].getStr("skill_id")])
  else:
    discard store.exec("INSERT INTO skills (skill_id,tenant_id,name,domain,trigger_spec,procedure_spec,skill_code,reward,active,embedding_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,0.0,1,?,?,?)",
      @[%newId("skill"), %defaultTenantId, %name, %domain, %trigger, %procedure, %skillCode, %embedding, %ts, %ts])

proc consolidateKnowledgeOnce() {.async.} =
  let tenantId = defaultTenantId
  let reflections = store.query("SELECT failure_point,pivot_action,attribution,verifier_report_json,created_at FROM reflections WHERE tenant_id=? ORDER BY created_at DESC LIMIT 64", @[%tenantId])
  if reflections.len == 0:
    return
  var evidence = newJArray()
  for row in reflections:
    evidence.add(%*{"failure_point": row.getStr("failure_point"), "pivot_action": row.getStr("pivot_action"), "attribution": row.getStr("attribution"), "verifier_report": row.getJson("verifier_report_json"), "created_at": row.getFloat("created_at")})
  let response = await invokeModel(mrOrchestrator, %*[
    {"role": "system", "content": promptText("knowledge_consolidation")},
    {"role": "user", "content": "Reflections:\n" & canonical(evidence)}
  ], true, tenantId, "")
  let node = parseJsonObjectLoose(response.content)
  if node.isNil:
    return
  let slug = node{"slug"}.getStr("").strip()
  let body = node{"body"}.getStr("").strip()
  if slug.len == 0 or body.len == 0:
    return
  discard await commitKnowledgeDoc(tenantId, slug, node{"category"}.getStr("operational"), body)
  discard await metaAgent.consider(tenantId)

proc knowledgeConsolidationLoop() {.async.} =
  while true:
    try:
      await consolidateKnowledgeOnce()
    except CatchableError:
      discard
    await sleepAsync(300000)

