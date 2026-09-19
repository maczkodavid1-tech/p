proc runTokenLevelDistillation(h: TaskHandle, reflectionPatch: JsonNode) {.async.} =
  acquire(h.lock)
  let goal = h.sigma{"goal"}.getStr(h.title)
  let obs = copy(h.obs)
  release(h.lock)
  let teacherPrompt = %*[
    {"role": "system", "content": promptText("distillation_teacher")},
    {"role": "user", "content": "Goal:\n" & goal & "\nObservation:\n" & canonical(obs) & "\nReflection:\n" & canonical(reflectionPatch)}
  ]
  let teacher = await callChatCompletionsAsync(teacherPrompt, maxTokens = 131072, temperature = 0.0, logprobs = true, topLogprobs = 20)
  if teacher.totalTokens > 0 and not chargeTokens(h.tenantId, h.taskId, teacher.totalTokens):
    h.haltForBudget()
    return
  let studentPrompt = %*[
    {"role": "system", "content": promptText("distillation_student")},
    {"role": "user", "content": "Goal:\n" & goal & "\nObservation:\n" & canonical(obs)}
  ]
  let student = await callChatCompletionsAsync(studentPrompt, maxTokens = 131072, temperature = 0.0, logprobs = true, topLogprobs = 20)
  if student.totalTokens > 0 and not chargeTokens(h.tenantId, h.taskId, student.totalTokens):
    h.haltForBudget()
    return
  let aligned = findAlignedTokenWindow(teacher.logprobs, student.logprobs)
  if aligned.len == 0:
    h.recordModelContext(mrGpt6Astra, "distillation_teacher", teacher.content, %*{"aligned_positions": 0, "reverse_kl": newJNull()})
    h.recordModelContext(mrGpt6Astra, "distillation_student", student.content, %*{"aligned_positions": 0})
    return
  var reverseKl = 0.0
  for pair in aligned:
    reverseKl += tokenReverseKl(teacher.logprobs[pair[0]], student.logprobs[pair[1]])
  reverseKl /= aligned.len.float
  let signalText = teacher.content & " " & reflectionPatch{"pivot_action"}.getStr("")
  let magnitude = clamp(0.02 + reverseKl * 0.01, 0.01, 0.2)
  for token in policyNgrams(signalText, 3):
    updatePolicyWeight(h.tenantId, token, magnitude)
  h.recordModelContext(mrGpt6Astra, "distillation_teacher", teacher.content, %*{"aligned_positions": aligned.len, "reverse_kl": reverseKl})
  h.recordModelContext(mrGpt6Astra, "distillation_student", student.content, %*{"aligned_positions": aligned.len})

proc reflectAndDistill(h: TaskHandle, verifierReport: JsonNode) {.async.} =
  acquire(h.lock)
  let state = copy(h.sigma)
  let observation = copy(h.obs)
  release(h.lock)
  let messages = %*[
    {"role": "system", "content": promptText("failure_diagnosis")},
    {"role": "user", "content": "State:\n" & canonical(state) & "\nObservation:\n" & canonical(observation) & "\nVerifier report:\n" & canonical(verifierReport)}
  ]
  let response = await invokeModel(mrGpt6Astra, messages, true, h.tenantId, h.taskId)
  let reflection = parseJsonObjectLoose(response.content)
  if reflection.isNil:
    return
  let patch = if reflection.hasKey("patch") and reflection["patch"].kind == JObject: copy(reflection["patch"]) else: newJObject()
  h.persistReflection(reflection{"failure_point"}.getStr("validation failed"), reflection{"pivot_action"}.getStr("replan from exact evidence"), reflection{"attribution"}.getStr("unknown"), patch, verifierReport)
  await h.runTokenLevelDistillation(reflection)

proc haltForBudget(h: TaskHandle) =
  if h.isNil:
    return
  acquire(h.lock)
  h.status = "halted"
  h.stopRequested = true
  h.verified = false
  h.terminalReason = "token budget exhausted"
  h.sigma["phase"] = %"terminal"
  h.orchestratorState = osTerminal
  h.obs = %*{"status": "halted", "error": "token budget exhausted"}
  release(h.lock)
  h.persistTask()
  h.emit(%*{"type": "done", "status": "halted", "verified": false, "reason": "token budget exhausted"})

proc defaultSigma(goal: string): JsonNode =
  %*{
    "goal": goal,
    "progress": 0.0,
    "phase": "perceive",
    "route": newJObject(),
    "plan": {
      "steps": newJArray(),
      "current_step_id": "",
      "completed_step_ids": newJArray()
    },
    "subgoals": newJArray(),
    "constraints": newJArray(),
    "facts": newJObject(),
    "blockers": newJArray(),
    "artifacts": newJArray(),
    "model_context": newJObject(),
    "runtime": {
      "instavm_session_id": "",
      "instavm_vm_id": "",
      "browser_session_id": "",
      "pty_id": "",
      "pty_ws_url": "",
      "workspace": "/app"
    },
    "system1": {
      "queued_actions": newJArray()
    },
    "system2": {
      "gate": 0.0,
      "subgoal": "",
      "strategy": "",
      "cognition": newJArray(),
      "last_observation_digest": ""
    },
    "completion_checklist": newJArray(),
    "handoffs": newJArray(),
    "step_summary": "initialized"
  }

proc ensureStateShape(sigma: JsonNode, goal: string) =
  if not sigma.hasKey("goal"): sigma["goal"] = %goal
  if not sigma.hasKey("progress"): sigma["progress"] = %0.0
  if not sigma.hasKey("phase"): sigma["phase"] = %"perceive"
  if not sigma.hasKey("route") or sigma["route"].kind != JObject: sigma["route"] = newJObject()
  if not sigma.hasKey("plan") or sigma["plan"].kind != JObject: sigma["plan"] = %*{"steps": newJArray(), "current_step_id": "", "completed_step_ids": newJArray()}
  if not sigma["plan"].hasKey("steps") or sigma["plan"]["steps"].kind != JArray: sigma["plan"]["steps"] = newJArray()
  if not sigma["plan"].hasKey("completed_step_ids") or sigma["plan"]["completed_step_ids"].kind != JArray: sigma["plan"]["completed_step_ids"] = newJArray()
  if not sigma.hasKey("subgoals") or sigma["subgoals"].kind != JArray: sigma["subgoals"] = newJArray()
  if not sigma.hasKey("constraints") or sigma["constraints"].kind != JArray: sigma["constraints"] = newJArray()
  if not sigma.hasKey("facts") or sigma["facts"].kind != JObject: sigma["facts"] = newJObject()
  if not sigma.hasKey("blockers") or sigma["blockers"].kind != JArray: sigma["blockers"] = newJArray()
  if not sigma.hasKey("artifacts") or sigma["artifacts"].kind != JArray: sigma["artifacts"] = newJArray()
  if not sigma.hasKey("model_context") or sigma["model_context"].kind != JObject: sigma["model_context"] = newJObject()
  if not sigma.hasKey("runtime") or sigma["runtime"].kind != JObject: sigma["runtime"] = newJObject()
  for entry in [("instavm_session_id", ""), ("instavm_vm_id", ""), ("browser_session_id", ""), ("pty_id", ""), ("pty_ws_url", ""), ("workspace", "/app")]:
    let key = entry[0]
    let value = entry[1]
    if not sigma["runtime"].hasKey(key): sigma["runtime"][key] = %value
  if not sigma.hasKey("system1") or sigma["system1"].kind != JObject: sigma["system1"] = newJObject()
  if not sigma["system1"].hasKey("queued_actions") or sigma["system1"]["queued_actions"].kind != JArray: sigma["system1"]["queued_actions"] = newJArray()
  if not sigma.hasKey("system2") or sigma["system2"].kind != JObject: sigma["system2"] = newJObject()
  if not sigma["system2"].hasKey("gate"): sigma["system2"]["gate"] = %0.0
  if not sigma["system2"].hasKey("subgoal"): sigma["system2"]["subgoal"] = %""
  if not sigma["system2"].hasKey("strategy"): sigma["system2"]["strategy"] = %""
  if not sigma["system2"].hasKey("cognition") or sigma["system2"]["cognition"].kind != JArray: sigma["system2"]["cognition"] = newJArray()
  if not sigma["system2"].hasKey("last_observation_digest"): sigma["system2"]["last_observation_digest"] = %""
  if not sigma.hasKey("completion_checklist") or sigma["completion_checklist"].kind != JArray: sigma["completion_checklist"] = newJArray()
  if not sigma.hasKey("handoffs") or sigma["handoffs"].kind != JArray: sigma["handoffs"] = newJArray()
  if not sigma.hasKey("step_summary"): sigma["step_summary"] = %"initialized"

proc countNodes(n: JsonNode): int =
  if n.isNil:
    return 0
  result = 1
  case n.kind
  of JObject:
    for _, value in n.fields:
      result += countNodes(value)
  of JArray:
    for value in n.elems:
      result += countNodes(value)
  else:
    discard

proc trimArrayTail(arr: JsonNode, keep: int) =
  if arr.isNil or arr.kind != JArray:
    return
  let actualKeep = max(0, keep)
  if arr.elems.len <= actualKeep:
    return
  if actualKeep == 0:
    arr.elems.setLen(0)
  else:
    arr.elems = arr.elems[arr.elems.len - actualKeep .. ^1]

proc pruneSigma(sigma: JsonNode) =
  if sigma.isNil or sigma.kind != JObject:
    return
  if sigma.hasKey("subgoals") and sigma["subgoals"].kind == JArray:
    var active = newJArray()
    var done = newJArray()
    for item in sigma["subgoals"].elems:
      let status = if item.kind == JObject: item{"status"}.getStr("").toLowerAscii() else: ""
      if status in ["done", "completed", "succeeded", "resolved"]:
        done.add(copy(item))
      else:
        active.add(copy(item))
    trimArrayTail(done, 8)
    for item in done.elems:
      active.add(item)
    sigma["subgoals"] = active
  if sigma.hasKey("blockers") and sigma["blockers"].kind == JArray:
    trimArrayTail(sigma["blockers"], 16)
  if sigma.hasKey("handoffs") and sigma["handoffs"].kind == JArray:
    trimArrayTail(sigma["handoffs"], 64)
  if sigma.hasKey("model_context") and sigma["model_context"].kind == JObject:
    for key, value in sigma["model_context"].fields:
      if value.kind == JArray:
        trimArrayTail(sigma["model_context"][key], 32)
  if sigma.hasKey("system1") and sigma["system1"].kind == JObject:
    let queue = sigma["system1"]{"queued_actions"}
    if not queue.isNil and queue.kind == JArray:
      trimArrayTail(queue, 256)
  if sigma.hasKey("facts") and sigma["facts"].kind == JObject and sigma["facts"].len > 512:
    var replacement = newJObject()
    var keys: seq[string] = @[]
    for key, _ in sigma["facts"].fields:
      keys.add(key)
    keys.sort()
    let start = max(0, keys.len - 512)
    for i in start ..< keys.len:
      replacement[keys[i]] = copy(sigma["facts"][keys[i]])
    sigma["facts"] = replacement

proc deepMerge(base, patch: JsonNode): JsonNode =
  if patch.isNil:
    return copyOrEmpty(base)
  if patch.kind != JObject:
    return copy(patch)
  var merged = if not base.isNil and base.kind == JObject: copy(base) else: newJObject()
  for key, value in patch.fields:
    if value.kind == JNull:
      if merged.hasKey(key):
        merged.delete(key)
    elif value.kind == JObject and merged.hasKey(key) and merged[key].kind == JObject:
      merged[key] = deepMerge(merged[key], value)
    else:
      merged[key] = copy(value)
  result = merged

proc collectForbiddenKeys(node: JsonNode, path = ""): seq[string] =
  result = @[]
  if node.isNil:
    return
  case node.kind
  of JObject:
    for key, value in node.fields:
      let lowered = key.toLowerAscii()
      let fullPath = if path.len == 0: key else: path & "." & key
      if lowered in ["history", "transcript", "messages", "chain_of_thought", "chain-of-thought", "private_reasoning", "reasoning_trace"]:
        result.add(fullPath)
      result.add(collectForbiddenKeys(value, fullPath))
  of JArray:
    for i, value in node.elems:
      result.add(collectForbiddenKeys(value, path & "[" & $i & "]"))
  else:
    discard

proc validatePatch(patch: JsonNode): (bool, seq[string]) =
  var errors: seq[string] = @[]
  if patch.isNil or patch.kind != JObject:
    errors.add("state patch must be a JSON object")
    return (false, errors)
  errors.add(collectForbiddenKeys(patch))
  if patch.hasKey("task_id") or patch.hasKey("tenant_id"):
    errors.add("state patch cannot modify runtime identity")
  (errors.len == 0, errors)

proc validateSigma(sigma: JsonNode): (bool, seq[string]) =
  var errors: seq[string] = @[]
  if sigma.isNil or sigma.kind != JObject:
    errors.add("state must be a JSON object")
    return (false, errors)
  for key in ["goal", "progress", "phase", "subgoals", "constraints", "facts", "blockers", "artifacts", "step_summary", "system1", "route", "plan", "runtime", "completion_checklist"]:
    if not sigma.hasKey(key):
      errors.add("missing state key: " & key)
  if sigma.hasKey("goal") and sigma["goal"].kind != JString:
    errors.add("goal must be a string")
  if sigma.hasKey("progress") and sigma["progress"].kind notin {JInt, JFloat}:
    errors.add("progress must be numeric")
  if sigma.hasKey("phase") and sigma["phase"].kind != JString:
    errors.add("phase must be a string")
  for key in ["subgoals", "constraints", "blockers", "artifacts", "completion_checklist"]:
    if sigma.hasKey(key) and sigma[key].kind != JArray:
      errors.add(key & " must be an array")
  for key in ["facts", "system1", "route", "plan", "runtime"]:
    if sigma.hasKey(key) and sigma[key].kind != JObject:
      errors.add(key & " must be an object")
  errors.add(collectForbiddenKeys(sigma))
  (errors.len == 0, errors)

proc decodePointerToken(token: string): string =
  result = token.replace("~1", "/").replace("~0", "~")

proc jsonPointerGet(root: JsonNode, pointer: string): JsonNode =
  if root.isNil:
    return nil
  if pointer.len == 0:
    return root
  if pointer[0] != '/':
    return nil
  var current = root
  for rawToken in pointer[1 .. ^1].split('/'):
    let token = decodePointerToken(rawToken)
    if current.isNil:
      return nil
    case current.kind
    of JObject:
      if not current.hasKey(token):
        return nil
      current = current[token]
    of JArray:
      if token == "-":
        return nil
      try:
        let idx = parseInt(token)
        if idx < 0 or idx >= current.elems.len:
          return nil
        current = current[idx]
      except ValueError:
        return nil
    else:
      return nil
  current

proc jsonEquivalent(a, b: JsonNode): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  canonical(a) == canonical(b)

proc persistTask(h: TaskHandle) =
  acquire(h.lock)
  pruneSigma(h.sigma)
  let stateCopy = copy(h.sigma)
  let obsCopy = copy(h.obs)
  let status = h.status
  let reason = h.terminalReason
  let verified = h.verified
  release(h.lock)
  discard store.exec("UPDATE tasks SET state_json=?, latest_obs_json=?, status=?, terminal_reason=?, verified=?, updated_at=? WHERE task_id=?",
    @[%($stateCopy), %($obsCopy), %status, %reason, %(if verified: 1 else: 0), %nowF(), %h.taskId])

proc checkpoint(h: TaskHandle, action, receipt: JsonNode) =
  acquire(h.lock)
  let stateCopy = copy(h.sigma)
  let obsCopy = copy(h.obs)
  release(h.lock)
  let rows = store.query("SELECT COALESCE(MAX(step_index),-1) AS step_index FROM checkpoints WHERE task_id=?", @[%h.taskId])
  let stepIndex = if rows.len > 0: rows[0].getInt("step_index", -1) + 1 else: 0
  let digest = sha1Hex(canonical(stateCopy) & canonical(obsCopy) & canonical(action) & canonical(receipt))
  discard store.exec("INSERT INTO checkpoints (task_id, tenant_id, step_index, state_json, obs_json, action_json, patch_json, receipt_json, digest, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
    @[%h.taskId, %(if h.tenantId.len > 0: h.tenantId else: defaultTenantId), %stepIndex, %($stateCopy), %($obsCopy), %($action), %"{}", %($receipt), %digest, %nowF()])
  discard store.exec("UPDATE tasks SET step_index=?, updated_at=? WHERE task_id=?", @[%stepIndex, %nowF(), %h.taskId])
  acquire(h.lock)
  h.stepIndex = stepIndex.int
  release(h.lock)

proc persistTaskEvent(taskId: string, ev: JsonNode) =
  discard store.exec("INSERT INTO task_events (task_id, sequence, event_json, created_at) SELECT ?, COALESCE(MAX(sequence),0)+1, ?, ? FROM task_events WHERE task_id=?",
    @[%taskId, %($ev), %nowF(), %taskId])

proc emit(h: TaskHandle, ev: JsonNode) =
  var event = copy(ev)
  if event.kind != JObject:
    event = %*{"type": "event", "payload": event}
  if not event.hasKey("task_id"):
    event["task_id"] = %h.taskId
  event["time"] = %nowF()
  persistTaskEvent(h.taskId, event)
  acquire(h.lock)
  let localSubs = h.subscribers
  release(h.lock)
  for sub in localSubs:
    try:
      sub.cb(event)
    except CatchableError:
      discard
  acquire(sseLock)
  let globalSubs = sseSubscribers.getOrDefault("default", @[])
  release(sseLock)
  for sub in globalSubs:
    try:
      sub.cb(event)
    except CatchableError:
      discard

proc transitionOrchestrator(h: TaskHandle, nextState: OrchestratorState) =
  acquire(h.lock)
  let previous = h.orchestratorState
  let graph = buildOrchestratorGraph()
  if not canOrchestratorTransition(graph, previous, nextState):
    release(h.lock)
    raise newException(ValueError, "invalid orchestrator transition: " & orchestratorStateName(previous) & " -> " & orchestratorStateName(nextState))
  h.orchestratorState = nextState
  h.sigma["phase"] = %orchestratorStateName(nextState)
  release(h.lock)
  if previous != nextState:
    h.emit(%*{"type": "orchestrator_state", "from": orchestratorStateName(previous), "to": orchestratorStateName(nextState)})

proc recordModelContext(h: TaskHandle, role: ModelRole, phase, content: string, metadata: JsonNode) =
  let key = modelRoleName(role)
  let meta = if metadata.isNil: newJObject() else: copy(metadata)
  let entry = %*{"time": nowF(), "phase": phase, "content": content, "metadata": meta}
  acquire(h.lock)
  if not h.sigma["model_context"].hasKey(key) or h.sigma["model_context"][key].kind != JArray:
    h.sigma["model_context"][key] = newJArray()
  h.sigma["model_context"][key].add(entry)
  release(h.lock)

proc subAgentTreeJson(taskId: string): JsonNode =
  result = newJArray()
  for r in store.query("SELECT agent_id,parent_agent_id,model_role,name,goal,status,result,error,created_at,updated_at FROM subagents WHERE task_id=? ORDER BY created_at ASC", @[%taskId]):
    result.add(%*{
      "agent_id": r.getStr("agent_id"),
      "parent_agent_id": r.getStr("parent_agent_id"),
      "model": r.getStr("model_role"),
      "name": r.getStr("name"),
      "goal": r.getStr("goal"),
      "status": r.getStr("status"),
      "result": r.getStr("result"),
      "error": r.getStr("error"),
      "created_at": r.getFloat("created_at"),
      "updated_at": r.getFloat("updated_at")
    })

proc runningSubAgentCount(taskId: string): int =
  let rows = store.query("SELECT COUNT(*) AS n FROM subagents WHERE task_id=? AND status IN ('queued','running','stopping')", @[%taskId])
  if rows.len > 0:
    return rows[0].getInt("n").int
  0

proc recordHandoff(h: TaskHandle, fromRole, toRole: ModelRole, reason: string, payload: JsonNode = nil) =
  let data = if payload.isNil: newJObject() else: copy(payload)
  let item = %*{"time": nowF(), "from": modelRoleName(fromRole), "to": modelRoleName(toRole), "reason": reason, "payload": data}
  acquire(h.lock)
  h.sigma["handoffs"].add(item)
  release(h.lock)
  h.emit(%*{"type": "model_handoff", "from": modelRoleName(fromRole), "to": modelRoleName(toRole), "reason": reason})

proc currentTraceStep(taskId: string): int64 =
  let rows = store.query("SELECT COALESCE(MAX(step_index),-1) AS step_index FROM raw_traces WHERE task_id=?", @[%taskId])
  if rows.len == 0: 0'i64 else: rows[0].getInt("step_index", -1) + 1'i64

proc logRawTrace(h: TaskHandle, skillId: string, preState, action, observation, delta, postState, receipt: JsonNode, success: bool, latencyMs: int) =
  let stepIndex = currentTraceStep(h.taskId)
  let traceId = newId("trace")
  let digest = sha1Hex(h.taskId & ":" & $stepIndex & ":" & canonical(preState) & ":" & canonical(action) & ":" & canonical(observation) & ":" & canonical(postState) & ":" & canonical(receipt))
  discard store.exec("INSERT INTO raw_traces (trace_id, task_id, tenant_id, step_index, initial_state_json, skill_id, action_json, obs_json, delta_json, post_state_json, success, latency_ms, receipt_json, immutable_hash, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    @[%traceId, %h.taskId, %(if h.tenantId.len > 0: h.tenantId else: defaultTenantId), %stepIndex, %($preState), %skillId, %($action), %($observation), %($delta), %($postState), %(if success: 1 else: 0), %latencyMs, %($receipt), %digest, %nowF()])

proc persistCognition(h: TaskHandle, vector: JsonNode, gate: float, subgoal, strategy: string, route: JsonNode) =
  let stepIndex = currentTraceStep(h.taskId)
  discard store.exec("INSERT INTO cognition (cog_id, task_id, tenant_id, step_index, vector_json, gate, subgoal, strategy, route_json, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
    @[%newId("cog"), %h.taskId, %(if h.tenantId.len > 0: h.tenantId else: defaultTenantId), %stepIndex, %($vector), %gate, %subgoal, %strategy, %($route), %nowF()])

proc persistReflection(h: TaskHandle, failurePoint, pivotAction, attribution: string, patch, verifier: JsonNode) =
  discard store.exec("INSERT INTO reflections (reflection_id, task_id, tenant_id, patch_json, failure_point, pivot_action, attribution, verifier_report_json, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
    @[%newId("ref"), %h.taskId, %(if h.tenantId.len > 0: h.tenantId else: defaultTenantId), %($patch), %failurePoint, %pivotAction, %attribution, %($verifier), %nowF()])
  let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
  for token in contentTerms(failurePoint & " " & attribution & " " & pivotAction):
    updatePolicyWeight(tenant, token, -0.02)

proc validatePlanGraph(plan: JsonNode, completedIds: HashSet[string] = initHashSet[string]()) =
  if plan.isNil or plan.kind != JArray:
    raise newException(ValueError, "plan must be an array")
  var ids = completedIds
  var localIds = initHashSet[string]()
  for step in plan.elems:
    if step.kind != JObject:
      raise newException(ValueError, "plan step must be an object")
    let id = step{"id"}.getStr("").strip()
    if id.len == 0:
      raise newException(ValueError, "plan step id is required")
    if id in localIds or id in completedIds:
      raise newException(ValueError, "duplicate plan step id: " & id)
    localIds.incl(id)
    ids.incl(id)
  var dependencies = initTable[string, seq[string]]()
  for step in plan.elems:
    let id = step{"id"}.getStr("").strip()
    let deps = step{"depends_on"}
    if deps.kind != JArray:
      raise newException(ValueError, "plan step depends_on must be an array")
    var depList: seq[string] = @[]
    for dep in deps.elems:
      if dep.kind != JString:
        raise newException(ValueError, "plan dependency must be a string")
      let depId = dep.getStr("").strip()
      if depId.len == 0:
        raise newException(ValueError, "plan dependency must not be empty")
      if depId == id:
        raise newException(ValueError, "plan step cannot depend on itself: " & id)
      if depId notin ids:
        raise newException(ValueError, "plan references unknown dependency: " & depId)
      depList.add(depId)
    dependencies[id] = depList
  var visiting = initHashSet[string]()
  var visited = initHashSet[string]()
  proc visit(id: string) =
    if id in completedIds or id in visited:
      return
    if id in visiting:
      raise newException(ValueError, "plan dependency cycle detected at: " & id)
    visiting.incl(id)
    for depId in dependencies.getOrDefault(id, @[]):
      if depId in localIds:
        visit(depId)
    visiting.excl(id)
    visited.incl(id)
  for id in localIds:
    visit(id)

proc toolCatalog(): JsonNode

proc routeDecisionFromJson(node: JsonNode): RouteDecision =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "orchestrator returned no JSON object")
  result.raw = copy(node)
  result.intent = node{"intent"}.getStr("").strip()
  if result.intent.len == 0:
    raise newException(ValueError, "orchestrator route is missing intent")
  let primaryName = node{"primary_model"}.getStr("").strip()
  if primaryName.len == 0:
    raise newException(ValueError, "orchestrator route is missing primary_model")
  result.primaryModel = parseModelRole(primaryName)
  if result.primaryModel == mrOrchestrator:
    raise newException(ValueError, "orchestrator cannot select itself as primary specialist")
  result.secondaryModels = @[]
  if node.hasKey("secondary_models"):
    if node["secondary_models"].kind != JArray:
      raise newException(ValueError, "secondary_models must be an array")
    for it in node["secondary_models"].elems:
      if it.kind != JString:
        raise newException(ValueError, "secondary_models entries must be strings")
      let role = parseModelRole(it.getStr(""))
      if role == mrOrchestrator:
        raise newException(ValueError, "orchestrator cannot be selected as a secondary specialist")
      if role != result.primaryModel and role notin result.secondaryModels:
        result.secondaryModels.add(role)
  result.requiresVm = node{"requires_vm"}.getBool(false)
  result.requiresBrowser = node{"requires_browser"}.getBool(false)
  result.requiresDesktop = node{"requires_desktop"}.getBool(false)
  result.requiresVisualAnalysis = node{"requires_visual_analysis"}.getBool(false)
  result.requiresDocumentAnalysis = node{"requires_document_analysis"}.getBool(false)
  result.requiresImageGeneration = node{"requires_image_generation"}.getBool(false)
  result.plan = newJArray()
  if node.hasKey("plan"):
    if node["plan"].kind != JArray:
      raise newException(ValueError, "plan must be an array")
    for i, item in node["plan"].elems:
      result.plan.add(normalizePlanStep(item, i))
  result.delegations = newJArray()
  if node.hasKey("delegations"):
    if node["delegations"].kind != JArray:
      raise newException(ValueError, "delegations must be an array")
    for item in node["delegations"].elems:
      if item.kind != JObject:
        raise newException(ValueError, "delegation entries must be objects")
      let modelName = item{"model"}.getStr("").strip()
      let goal = item{"goal"}.getStr("").strip()
      if modelName.len == 0 or goal.len == 0:
        raise newException(ValueError, "every delegation requires model and goal")
      let role = parseModelRole(modelName)
      var normalized = copy(item)
      normalized["model"] = %modelRoleName(role)
      result.delegations.add(normalized)
  result.completionCriteria = if node.hasKey("completion_criteria") and node["completion_criteria"].kind == JArray: copy(node["completion_criteria"]) else: newJArray()
  validatePlanGraph(result.plan)
  let executionRequired = result.requiresVm or result.requiresBrowser or result.requiresDesktop or result.requiresVisualAnalysis or result.requiresDocumentAnalysis or result.requiresImageGeneration or result.delegations.elems.len > 0
  if executionRequired and result.plan.elems.len == 0:
    raise newException(ValueError, "execution routes must contain at least one explicit plan step")
  if result.plan.elems.len > 0 and result.completionCriteria.elems.len == 0:
    raise newException(ValueError, "execution routes must contain completion_criteria")
  result.raw["primary_model"] = %modelRoleName(result.primaryModel)
  var normalizedSecondary = newJArray()
  for role in result.secondaryModels:
    normalizedSecondary.add(%modelRoleName(role))
  result.raw["secondary_models"] = normalizedSecondary
  result.raw["plan"] = copy(result.plan)
  result.raw["delegations"] = copy(result.delegations)

proc routeTask(goal: string, sigma: JsonNode, obs: JsonNode, tenantId = "", taskId = ""): Future[RouteDecision] {.async.} =
  let systemText = promptText("orchestrator_router") & "\n\n" & promptText("image_generation")
  let baseUserText = "GOAL:\n" & goal & "\n\nCURRENT STATE:\n" & canonical(sigma) & "\n\nLATEST OBSERVATION:\n" & canonical(obs) & "\n\nAVAILABLE REAL TOOLS:\n" & canonical(toolCatalog()) & "\n\nAVAILABLE MODEL REFERENCE SKILLS:\n" & referenceSkillCatalog() & "\n\nVALID SPECIALIST MODEL ROLE IDS:\n" & configuredModelRoleNames().join(", ") & "\n\nVALID SUBAGENT MODEL ROLE IDS:\n" & configuredSubAgentModelRoleNames().join(", ")
  var messages = %*[
    {"role": "system", "content": systemText},
    {"role": "user", "content": baseUserText}
  ]
  var lastError = ""
  for attempt in 0 .. 2:
    let resp = await vmcoCall(messages, true)
    if tenantId.len > 0 and resp.totalTokens > 0 and not chargeTokens(tenantId, taskId, resp.totalTokens):
      raise newException(IOError, "token budget exhausted")
    let node = parseJsonObjectLoose(resp.content)
    try:
      return routeDecisionFromJson(node)
    except CatchableError as e:
      lastError = e.msg
      messages.add(%*{"role": "assistant", "content": resp.content})
      messages.add(%*{"role": "user", "content": "The routing object was invalid: " & e.msg & "\nRe-evaluate the complete task using the reference skills and return a corrected routing JSON object. You must make the model choice yourself; do not ask the backend to infer it."})
  raise newException(ValueError, "orchestrator failed to return a valid model decision: " & lastError)

proc applyRoute(h: TaskHandle, route: RouteDecision) =
  acquire(h.lock)
  h.sigma["route"] = copy(route.raw)
  var steps = copy(route.plan)
  for i in 0 ..< steps.elems.len:
    if steps[i].kind == JObject and not steps[i].hasKey("status"):
      steps[i]["status"] = %"pending"
  h.sigma["plan"] = %*{
    "steps": steps,
    "current_step_id": "",
    "completed_step_ids": newJArray(),
    "completion_criteria": copy(route.completionCriteria)
  }
  h.sigma["completion_checklist"] = newJArray()
  for criterion in route.completionCriteria.elems:
    h.sigma["completion_checklist"].add(%*{"criterion": criterion.getStr($criterion), "status": "pending", "evidence": ""})
  h.sigma["step_summary"] = %("routed: " & route.intent)
  if route.delegations.kind == JArray and route.delegations.elems.len > 0:
    for delegation in route.delegations.elems:
      var args = copy(delegation)
      h.sigma["system1"]["queued_actions"].add(%*{"tool": "spawn_subagent", "args": args})
    h.sigma["system1"]["queued_actions"].add(%*{"tool": "wait_subagents", "args": %*{"scope": "direct_children"}})
  h.lastPlannedDigest = sha1Hex(canonical(h.sigma))
  release(h.lock)
  h.transitionOrchestrator(osDeliberate)
  h.persistTask()
  h.emit(%*{"type": "route", "intent": route.intent, "model": modelRoleName(route.primaryModel), "route": route.raw})
  h.emit(%*{"type": "plan", "steps": route.plan, "completion_criteria": route.completionCriteria})

proc currentPlanStep(sigma: JsonNode): JsonNode =
  if sigma.isNil or sigma.kind != JObject:
    return nil
  let plan = sigma{"plan"}
  if plan.kind != JObject:
    return nil
  let steps = plan{"steps"}
  if steps.kind != JArray:
    return nil
  var byId = initTable[string, string]()
  for step in steps.elems:
    if step.kind != JObject:
      raise newException(ValueError, "persisted plan contains a non-object step")
    let id = step{"id"}.getStr("").strip()
    if id.len == 0:
      raise newException(ValueError, "persisted plan contains a step without id")
    if byId.hasKey(id):
      raise newException(ValueError, "persisted plan contains duplicate step id: " & id)
    byId[id] = step{"status"}.getStr("")
  for step in steps.elems:
    let status = step{"status"}.getStr("pending")
    if status notin ["pending", "running", "blocked", "needs_replan"]:
      continue
    var depsOk = true
    let deps = step{"depends_on"}
    if deps.kind != JArray:
      raise newException(ValueError, "persisted plan depends_on must be an array")
    for dep in deps.elems:
      if dep.kind != JString:
        raise newException(ValueError, "persisted plan dependency must be a string")
      let depId = dep.getStr("").strip()
      if depId.len == 0 or not byId.hasKey(depId):
        raise newException(ValueError, "persisted plan references an invalid dependency")
      if byId[depId] != "completed":
        depsOk = false
        break
    if depsOk:
      return copy(step)
  nil

proc setStepStatus(h: TaskHandle, stepId, status: string) =
  if status notin ["pending", "running", "blocked", "needs_replan", "completed", "failed"]:
    raise newException(ValueError, "invalid plan step status: " & status)
  acquire(h.lock)
  let steps = h.sigma{"plan"}{"steps"}
  var matches = 0
  if steps.kind == JArray:
    for i in 0 ..< steps.elems.len:
      if steps[i].kind == JObject and steps[i]{"id"}.getStr("") == stepId:
        inc matches
        steps[i]["status"] = %status
        if status == "completed":
          var already = false
          let done = h.sigma["plan"]["completed_step_ids"]
          for it in done.elems:
            if it.kind == JString and it.getStr("") == stepId:
              already = true
              break
          if not already:
            done.add(%stepId)
  if matches != 1:
    release(h.lock)
    raise newException(ValueError, "plan step id is missing or ambiguous: " & stepId)
  h.sigma["plan"]["current_step_id"] = %(if status == "running": stepId else: "")
  release(h.lock)
  h.persistTask()

proc updateProgress(h: TaskHandle) =
  acquire(h.lock)
  let steps = h.sigma{"plan"}{"steps"}
  if steps.kind == JArray and steps.elems.len > 0:
    var done = 0
    for step in steps.elems:
      if step.kind == JObject and step{"status"}.getStr("") == "completed":
        inc done
    h.sigma["progress"] = %(done.float / steps.elems.len.float)
  release(h.lock)
  h.persistTask()

proc replaceRemainingPlan(h: TaskHandle, replacement: JsonNode) =
  if replacement.isNil or replacement.kind != JArray or replacement.elems.len == 0:
    raise newException(ValueError, "replacement plan must contain at least one model-selected step")
  acquire(h.lock)
  let existing = copy(h.sigma{"plan"}{"steps"})
  release(h.lock)
  var completedSteps = newJArray()
  var completedIds = initHashSet[string]()
  if existing.kind == JArray:
    for step in existing.elems:
      if step.kind == JObject and step{"status"}.getStr("") == "completed":
        let id = step{"id"}.getStr("").strip()
        if id.len == 0 or id in completedIds:
          raise newException(ValueError, "completed plan contains missing or duplicate step id")
        completedIds.incl(id)
        completedSteps.add(copy(step))
  var normalizedReplacement = newJArray()
  for i, item in replacement.elems:
    normalizedReplacement.add(normalizePlanStep(item, i))
  validatePlanGraph(normalizedReplacement, completedIds)
  var mergedSteps = newJArray()
  for step in completedSteps.elems:
    mergedSteps.add(copy(step))
  for step in normalizedReplacement.elems:
    mergedSteps.add(copy(step))
  acquire(h.lock)
  h.sigma["plan"]["steps"] = mergedSteps
  h.sigma["plan"]["current_step_id"] = %""
  release(h.lock)
  h.updateProgress()

proc registerTool(name, description: string, schema: JsonNode, handler: ToolHandler) =
  toolRegistry[name] = ToolSpec(name: name, description: description, schema: schema, handler: handler)

proc toolCatalog(): JsonNode =
  result = newJArray()
  for name, spec in toolRegistry:
    result.add(%*{"name": name, "description": spec.description, "arguments": spec.schema})

proc instavmHeaders(): HttpHeaders =
  let key = requireEnv("INSTAVM_API_KEY")
  result = newHttpHeaders({
    "X-API-Key": key,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })

proc runtimeNode(h: TaskHandle): JsonNode =
  acquire(h.lock)
  result = copy(h.sigma["runtime"])
  release(h.lock)

proc saveRuntimeField(h: TaskHandle, key, value: string) =
  acquire(h.lock)
  h.sigma["runtime"][key] = %value
  release(h.lock)
  h.persistTask()

proc createInstaVmSession(h: TaskHandle): Future[string] {.async.} =
  let existing = h.runtimeNode(){"instavm_session_id"}.getStr("")
  if existing.len > 0:
    return existing
  let body = %*{
    "api_key": requireEnv("INSTAVM_API_KEY"),
    "vm_lifetime_seconds": VmLifetimeSeconds,
    "memory_mb": VmDefaultMemoryMb,
    "vcpu_count": VmDefaultVcpuCount,
    "metadata": {"task_id": h.taskId},
    "env": newJObject(),
    "prewarm": false
  }
  let (status, raw, _) = await httpRequestAsync(InstaVmBaseUrl & "/v1/sessions/session", HttpPost, $body, instavmHeaders())
  if status < 200 or status >= 300:
    raise newException(IOError, "InstaVM session status " & $status & ": " & raw)
  let j = parseJson(raw)
  let sid = j{"session_id"}.getStr(j{"id"}.getStr(""))
  if sid.len == 0:
    raise newException(IOError, "InstaVM session response has no session_id")
  h.saveRuntimeField("instavm_session_id", sid)
  if j{"vm_id"}.getStr("").len > 0:
    h.saveRuntimeField("instavm_vm_id", j{"vm_id"}.getStr(""))
  h.emit(%*{"type": "runtime", "runtime": "instavm", "session_id": sid})
  return sid

proc instavmExecute(h: TaskHandle, command, language: string): Future[ToolResult] {.async.} =
  let sid = await h.createInstaVmSession()
  let body = %*{
    "command": command,
    "session_id": sid,
    "language": language
  }
  let (status, raw, _) = await httpRequestAsync(InstaVmBaseUrl & "/execute", HttpPost, $body, instavmHeaders())
  if status < 200 or status >= 300:
    return ToolResult(ok: false, payload: %*{"status": status, "body": raw}, receipt: "instavm:execute:error", message: "InstaVM execute status " & $status)
  let j = parseJson(raw)
  let success = j{"success"}.getBool(status >= 200 and status < 300)
  let output = j{"output"}.getStr("")
  var payload = copy(j)
  if payload.kind != JObject:
    payload = %*{"raw": j}
  payload["session_id"] = %sid
  if not payload.hasKey("stdout"):
    payload["stdout"] = %output
  if not payload.hasKey("stderr"):
    payload["stderr"] = %j{"error"}.getStr("")
  if j{"vm_id"}.getStr("").len > 0:
    h.saveRuntimeField("instavm_vm_id", j{"vm_id"}.getStr(""))
  return ToolResult(ok: success, payload: payload, receipt: "instavm:execute:" & sha1Hex(command & $status), message: (if success: "execution completed" else: j{"error"}.getStr(output)))

proc instavmJson(h: TaskHandle, path: string, httpMethodValue: HttpMethod, body: JsonNode = nil): Future[ToolResult] {.async.} =
  discard await h.createInstaVmSession()
  let bodyText = if body.isNil: "" else: $body
  let (status, raw, _) = await httpRequestAsync(InstaVmBaseUrl & path, httpMethodValue, bodyText, instavmHeaders())
  var payload: JsonNode
  try:
    payload = parseJson(raw)
  except CatchableError:
    payload = %*{"body_base64": base64.encode(raw)}
  let ok = status >= 200 and status < 300
  return ToolResult(ok: ok, payload: payload, receipt: "instavm:" & sha1Hex(path & bodyText & $status), message: (if ok: "ok" else: "InstaVM status " & $status))

proc browserSession(h: TaskHandle): Future[string] {.async.} =
  let existing = h.runtimeNode(){"browser_session_id"}.getStr("")
  if existing.len > 0:
    return existing
  let sid = await h.createInstaVmSession()
  let body = %*{
    "session_id": sid,
    "viewport_width": 1920,
    "viewport_height": 1080
  }
  let res = await h.instavmJson("/v1/browser/sessions", HttpPost, body)
  if not res.ok:
    raise newException(IOError, res.message & ": " & canonical(res.payload))
  let bid = res.payload{"session_id"}.getStr(res.payload{"id"}.getStr(res.payload{"browser_session_id"}.getStr("")))
  if bid.len == 0:
    raise newException(IOError, "InstaVM browser session response has no session id")
  h.saveRuntimeField("browser_session_id", bid)
  return bid

proc browserAction(h: TaskHandle, action: string, args: JsonNode): Future[ToolResult] {.async.} =
  let bid = await h.browserSession()
  var body = if args.isNil or args.kind != JObject: newJObject() else: copy(args)
  body["session_id"] = %bid
  return await h.instavmJson("/v1/browser/interactions/" & action, HttpPost, body)

proc desktopProxy(h: TaskHandle, path: string, httpMethodValue: HttpMethod, body: JsonNode = nil): Future[ToolResult] {.async.} =
  let sid = await h.createInstaVmSession()
  return await h.instavmJson("/v1/computeruse/" & encodeUrl(sid) & path, httpMethodValue, body)

proc shellQuote(s: string): string =
  result = "'" & s.replace("'", "'\\''") & "'"

proc addArtifact(h: TaskHandle, name, path, kind, mimeType: string, metadata: JsonNode = nil): string =
  let id = newId("artifact")
  let meta = if metadata.isNil: newJObject() else: copy(metadata)
  discard store.exec("INSERT INTO artifacts (artifact_id, task_id, name, path, kind, mime_type, metadata_json, created_at) VALUES (?,?,?,?,?,?,?,?)",
    @[%id, %h.taskId, %name, %path, %kind, %mimeType, %($meta), %nowF()])
  let item = %*{"artifact_id": id, "name": name, "path": path, "kind": kind, "mime_type": mimeType, "metadata": meta}
  acquire(h.lock)
  h.sigma["artifacts"].add(item)
  release(h.lock)
  h.persistTask()
  h.emit(%*{"type": "artifact", "artifact": item})
  id

proc spawnSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult]
proc waitSubAgentsTool(h: TaskHandle, args: JsonNode): Future[ToolResult]
proc listSubAgentsTool(h: TaskHandle, args: JsonNode): Future[ToolResult]
proc getSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult]
proc messageSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult]
proc stopSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult]

