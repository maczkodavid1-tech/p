proc specialistSystem(role: ModelRole): string =
  let base = case role
  of mrGpt6Astra: promptText("gpt6_astra")
  of mrGlm52: promptText("glm52")
  of mrGemini38: promptText("gemini38")
  of mrMiniMaxM3: promptText("minimax_m3")
  of mrGrok43: promptText("grok43")
  of mrOrchestrator: promptText("orchestrator_router")
  if role in {mrGemini38, mrGrok43}:
    return base & "\n\n" & promptText("image_generation")
  base

proc subAgentSystem(role: ModelRole): string =
  let core = promptText("subagent_core")
  if role == mrOrchestrator:
    return core & "\n\n" & promptText("subagent_orchestrator")
  core & "\n\nMODEL SPECIALIZATION:\n" & specialistSystem(role)

proc buildStepMessages(h: TaskHandle, step: JsonNode, role: ModelRole): JsonNode =
  acquire(h.lock)
  let sigma = copy(h.sigma)
  let obs = copy(h.obs)
  let spec = copy(h.spec)
  release(h.lock)
  let queryText = step{"goal"}.getStr("") & " " & sigma{"step_summary"}.getStr("") & " " & canonical(obs)
  let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
  var memory = %*{"skills": newJArray(), "knowledge": newJArray(), "policy_signals": learnedPolicySignals(tenant, queryText, 12)}
  for r in searchSkills(tenant, queryText, 8):
    memory["skills"].add(%*{"name": r.getStr("name"), "domain": r.getStr("domain"), "procedure": r.getStr("procedure_spec"), "skill_code": r.getStr("skill_code"), "reward": r.getFloat("reward")})
  for r in searchKnowledge(tenant, queryText, 8):
    memory["knowledge"].add(%*{"slug": r.getStr("slug"), "category": r.getStr("category"), "content": r.getStr("content")})
  let userText = "TASK SPECIFICATION:\n" & canonical(spec) &
    "\n\nCURRENT AUTONOMOUS STATE:\n" & canonical(sigma) &
    "\n\nACTIVE PLAN STEP:\n" & canonical(step) &
    "\n\nLATEST REAL OBSERVATION:\n" & canonical(obs) &
    "\n\nRELEVANT LEARNED MEMORY:\n" & canonical(memory) &
    "\n\nACTIVE SUBAGENT TREE:\n" & canonical(subAgentTreeJson(h.taskId)) &
    "\n\nAVAILABLE REAL TOOLS:\n" & canonical(toolCatalog()) &
    "\n\nGENERATED IMAGE HISTORY:\n" & canonical(imageGenerationCatalogJson(h.taskId, 12)) &
    "\n\nVALID SUBAGENT MODEL ROLE IDS:\n" & configuredSubAgentModelRoleNames().join(", ")
  result = %*[
    {"role": "system", "content": specialistSystem(role)},
    {"role": "user", "content": userText}
  ]
  if role in {mrGemini38, mrGrok43} and spec.hasKey("messages") and spec["messages"].kind == JArray:
    for original in spec["messages"].elems:
      if original.kind == JObject:
        let content = original{"content"}
        if content.kind == JArray:
          var hasMedia = false
          for part in content.elems:
            if part.kind == JObject and part{"type"}.getStr("") in ["image", "image_url", "input_image", "video", "video_url", "input_video"]:
              hasMedia = true
              break
          if hasMedia:
            result.add(copy(original))
  if role in {mrGemini38, mrGrok43}:
    let imageContext = imageContextMessage(h, role, imageContextBudget(result))
    if not imageContext.isNil:
      result.add(imageContext)


proc descriptorAccepts(value: JsonNode, descriptor: string): bool =
  let d = descriptor.strip().toLowerAscii()
  if d.len == 0:
    return true
  let base = d.replace(" optional", "").strip()
  if base == "string": return value.kind == JString
  if base == "int" or base == "integer": return value.kind == JInt
  if base == "number" or base == "float": return value.kind in {JInt, JFloat}
  if base == "bool" or base == "boolean": return value.kind == JBool
  if base == "object": return value.kind == JObject
  if base == "array": return value.kind == JArray
  if base == "string[]":
    if value.kind != JArray: return false
    for item in value.elems:
      if item.kind != JString: return false
    return true
  if '|' in base:
    let choices = base.split('|').mapIt(it.strip())
    if value.kind == JString:
      return value.getStr("") in choices
    return false
  true

proc validateToolArguments(spec: ToolSpec, args: JsonNode): string =
  if args.isNil or args.kind != JObject:
    return "tool arguments must be an object"
  if spec.schema.isNil or spec.schema.kind != JObject:
    return ""
  for key, descriptorNode in spec.schema.fields:
    if descriptorNode.kind != JString:
      continue
    let descriptor = descriptorNode.getStr("")
    let optional = descriptor.toLowerAscii().contains("optional")
    if not args.hasKey(key):
      if not optional:
        return "missing required tool argument: " & key
      continue
    if not descriptorAccepts(args[key], descriptor):
      return "invalid tool argument type or value for " & key & ": expected " & descriptor
  for key, _ in args.fields:
    if key.startsWith("_actor_"):
      continue
    if not spec.schema.hasKey(key):
      return "unknown tool argument: " & key
  ""

proc executeToolAction(h: TaskHandle, action: JsonNode, actorModel = "", actorStepId = ""): Future[ToolResult] {.async.} =
  if action.isNil or action.kind != JObject:
    return ToolResult(ok: true, payload: newJObject(), receipt: "none", message: "no action")
  let name = action{"tool"}.getStr("")
  if name.len == 0 or name == "none":
    return ToolResult(ok: true, payload: newJObject(), receipt: "none", message: "no action")
  if not toolRegistry.hasKey(name):
    return ToolResult(ok: false, payload: %*{"tool": name}, receipt: "unknown", message: "unknown tool: " & name)
  if name notin h.allowedTools:
    return ToolResult(ok: false, payload: %*{"tool": name}, receipt: "forbidden", message: "tool is not allowed for this tenant/task: " & name)
  var args = action{"args"}
  if args.isNil:
    args = newJObject()
  if args.kind != JObject:
    return ToolResult(ok: false, payload: %*{"tool": name}, receipt: "invalid_args", message: "tool args must be an object")
  if actorModel.len > 0 and args{"_actor_model"}.getStr("").strip().len == 0:
    args["_actor_model"] = %actorModel
  if actorStepId.len > 0 and args{"_actor_step_id"}.getStr("").strip().len == 0:
    args["_actor_step_id"] = %actorStepId
  if h.taskId.len > 0 and args{"_actor_task_id"}.getStr("").strip().len == 0:
    args["_actor_task_id"] = %h.taskId
  let argumentError = validateToolArguments(toolRegistry[name], args)
  if argumentError.len > 0:
    return ToolResult(ok: false, payload: %*{"tool": name, "args": args}, receipt: "invalid_args", message: argumentError)
  h.emit(%*{"type": "tool_start", "tool": name, "args": args})
  let started = getMonoTime()
  try:
    result = await toolRegistry[name].handler(h, args)
  except CatchableError as e:
    result = ToolResult(ok: false, payload: %*{"error": e.msg}, receipt: "error", message: e.msg)
  let elapsed = int((getMonoTime() - started).inMilliseconds)
  h.emit(%*{"type": "tool_result", "tool": name, "ok": result.ok, "payload": result.payload, "message": result.message, "latency_ms": elapsed})

proc verifyStepCompletion(h: TaskHandle, step, modelNode: JsonNode, toolRes: ToolResult, role: ModelRole): Future[(bool, JsonNode)] {.async.} =
  var evidence = %*{
    "step": copy(step),
    "model_role": modelRoleName(role),
    "model_output": copy(modelNode),
    "tool": {"ok": toolRes.ok, "payload": copy(toolRes.payload), "receipt": toolRes.receipt, "message": toolRes.message}
  }
  if not toolRes.ok:
    return (false, %*{"verified": false, "reason": "tool execution failed", "evidence": evidence})
  let systemText = promptText("step_verifier")
  let userText = "Verify whether this exact plan step is complete from concrete evidence only. Do not infer success from the specialist claiming success.\n\n" & canonical(evidence)
  let resp = await cerebrasCall(%*[{"role": "system", "content": systemText}, {"role": "user", "content": userText}], true)
  if resp.totalTokens > 0 and not chargeTokens(h.tenantId, h.taskId, resp.totalTokens):
    h.haltForBudget()
    return (false, %*{"verified": false, "reason": "token budget exhausted"})
  let node = parseJsonObjectLoose(resp.content)
  if node.isNil or node{"verified"}.kind != JBool:
    return (false, %*{"verified": false, "reason": "step verifier returned invalid structured output", "raw": resp.content})
  let verified = node{"verified"}.getBool(false)
  return (verified, node)

proc modelStep(h: TaskHandle, step: JsonNode): Future[(bool, string)] {.async.} =
  let role = parseModelRole(step{"model"}.getStr(""))
  if role == mrOrchestrator:
    raise newException(ValueError, "orchestrator cannot execute a specialist plan step")
  let stepId = step{"id"}.getStr("step")
  acquire(h.lock)
  let preState = copy(h.sigma)
  release(h.lock)
  h.setStepStatus(stepId, "running")
  h.transitionOrchestrator(osAct)
  h.emit(%*{"type": "model_start", "model": modelRoleName(role), "provider": providerName(modelSpec(role).provider), "step_id": stepId})
  let messages = h.buildStepMessages(step, role)
  let modelStarted = getMonoTime()
  let resp = await invokeModel(role, messages, role != mrGemini38, h.tenantId, h.taskId)
  let modelLatency = int((getMonoTime() - modelStarted).inMilliseconds)
  h.recordModelContext(role, "step_output", resp.content, %*{"step_id": stepId, "provider": providerName(resp.provider), "model": resp.model, "finish_reason": resp.finishReason})
  h.emit(%*{"type": "model_output", "model": modelRoleName(role), "step_id": stepId, "content": resp.content, "latency_ms": modelLatency})
  let node = parseJsonObjectLoose(resp.content)
  if node.isNil:
    acquire(h.lock)
    h.obs = %*{"status": "model_output_invalid", "step_id": stepId, "model": modelRoleName(role), "content": resp.content}
    h.sigma["step_summary"] = %"specialist output was not a usable structured object"
    let postState = copy(h.sigma)
    let observation = copy(h.obs)
    release(h.lock)
    let receipt = %*{"model": resp.model, "provider": providerName(resp.provider), "finish_reason": resp.finishReason}
    h.logRawTrace("", preState, newJObject(), observation, newJObject(), postState, receipt, false, modelLatency)
    h.transitionOrchestrator(osReflect)
    h.persistReflection("model_output_invalid", "ask the orchestrator to decide the next specialist or retry strategy from the exact recorded output", modelRoleName(role), %*{"step_id": stepId, "raw_output": resp.content}, observation)
    h.setStepStatus(stepId, "needs_replan")
    h.persistTask()
    return (false, "")
  var action: JsonNode = newJNull()
  var summary = node{"summary"}.getStr("")
  var finalText = node{"final"}.getStr("")
  var requestedComplete = node{"step_complete"}.getBool(false)
  if role in {mrGemini38, mrGrok43} and node.hasKey("images"):
    if node["images"].kind != JArray or node["images"].elems.len == 0:
      h.transitionOrchestrator(osReflect)
      h.setStepStatus(stepId, "needs_replan")
      acquire(h.lock)
      h.obs = %*{"status": "model_output_invalid", "step_id": stepId, "error": modelRoleName(role) & " images output must be a non-empty array"}
      release(h.lock)
      h.persistTask()
      return (false, "")
    action = %*{"tool": "image_generate", "args": %*{"images": node["images"], "_actor_model": modelRoleName(role), "_actor_step_id": stepId}}
    finalText = canonical(node)
    if summary.len == 0:
      summary = modelRoleName(role) & " directed " & $node["images"].elems.len & " FlyMyAI image generation"
    requestedComplete = node{"step_complete"}.getBool(true)
  else:
    if node.hasKey("action"):
      action = node["action"]
    if node{"step_complete"}.kind != JBool:
      h.transitionOrchestrator(osReflect)
      h.setStepStatus(stepId, "needs_replan")
      acquire(h.lock)
      h.obs = %*{"status": "model_output_invalid", "step_id": stepId, "error": "step_complete boolean required"}
      release(h.lock)
      h.persistTask()
      return (false, finalText)
  var toolRes = ToolResult(ok: true, payload: newJObject(), receipt: "none", message: "no action")
  var totalLatency = modelLatency
  if not action.isNil and action.kind == JObject and action{"tool"}.getStr("").len > 0:
    let toolStarted = getMonoTime()
    toolRes = await h.executeToolAction(action, modelRoleName(role), stepId)
    totalLatency += int((getMonoTime() - toolStarted).inMilliseconds)
    acquire(h.lock)
    h.obs = %*{
      "status": (if toolRes.ok: "tool_completed" else: "tool_failed"),
      "step_id": stepId,
      "model": modelRoleName(role),
      "action": copy(action),
      "tool_result": copy(toolRes.payload),
      "message": toolRes.message,
      "receipt": toolRes.receipt
    }
    h.sigma["step_summary"] = %(if summary.len > 0: summary else: toolRes.message)
    let postState = copy(h.sigma)
    let observation = copy(h.obs)
    release(h.lock)
    let receipt = %*{"receipt": toolRes.receipt, "ok": toolRes.ok, "model": resp.model, "provider": providerName(resp.provider)}
    h.logRawTrace("", preState, action, observation, %*{"summary": summary}, postState, receipt, toolRes.ok, totalLatency)
    h.checkpoint(action, receipt)
    h.persistTask()
    if not toolRes.ok:
      h.transitionOrchestrator(osReflect)
      h.persistReflection("tool_failure:" & action{"tool"}.getStr(""), "return the exact tool failure to the strategic orchestrator for a fresh model decision", modelRoleName(role), %*{"step_id": stepId, "action": action, "result": toolRes.payload}, observation)
      h.setStepStatus(stepId, "needs_replan")
      h.persistTask()
      return (false, finalText)
  else:
    acquire(h.lock)
    h.obs = %*{"status": "model_completed", "step_id": stepId, "model": modelRoleName(role), "summary": summary, "content": finalText}
    h.sigma["step_summary"] = %(if summary.len > 0: summary else: finalText)
    let postState = copy(h.sigma)
    let observation = copy(h.obs)
    release(h.lock)
    let receipt = %*{"model": resp.model, "provider": providerName(resp.provider), "finish_reason": resp.finishReason}
    h.logRawTrace("", preState, newJObject(), observation, %*{"summary": summary}, postState, receipt, requestedComplete, modelLatency)
    h.checkpoint(newJObject(), receipt)
    h.persistTask()
  if requestedComplete:
    let verified = await h.verifyStepCompletion(step, node, toolRes, role)
    acquire(h.lock)
    h.obs["step_verification"] = copy(verified[1])
    release(h.lock)
    if verified[0]:
      h.setStepStatus(stepId, "completed")
      h.updateProgress()
      h.emit(%*{"type": "progress", "step_id": stepId, "status": "completed", "verification": verified[1]})
      h.persistTask()
      return (true, finalText)
    h.transitionOrchestrator(osReflect)
    h.setStepStatus(stepId, "needs_replan")
    h.persistReflection("step_verification_failed", "replan from concrete verification evidence", modelRoleName(role), %*{"step_id": stepId, "output": node}, verified[1])
    h.persistTask()
  return (false, finalText)

proc completionCheck(h: TaskHandle): Future[(bool, string)]

proc verifyTerminal(h: TaskHandle): (bool, JsonNode) =
  acquire(h.lock)
  let sigma = copy(h.sigma)
  let spec = copy(h.spec)
  let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
  release(h.lock)
  var report = newJArray()
  var allOk = true
  var configured = false
  if spec.hasKey("verifiers") and spec["verifiers"].kind == JArray:
    for verifier in spec["verifiers"].elems:
      if verifier.kind != JObject:
        allOk = false
        report.add(%*{"verifier": "invalid", "ok": false, "error": "verifier must be an object"})
        continue
      configured = true
      let kind = verifier{"type"}.getStr(verifier{"verifier"}.getStr(""))
      case kind
      of "state_path_equals":
        let path = verifier{"path"}.getStr("")
        let actual = jsonPointerGet(sigma, path)
        let expected = if verifier.hasKey("expected"): verifier["expected"] elif verifier.hasKey("value"): verifier["value"] else: newJNull()
        let ok = not actual.isNil and jsonEquivalent(actual, expected)
        if not ok: allOk = false
        report.add(%*{"verifier": kind, "path": path, "ok": ok, "expected": expected, "actual": (if actual.isNil: newJNull() else: copy(actual))})
      of "file_exists":
        let rel = verifier{"path"}.getStr("")
        var ok = false
        try:
          ok = rel.len > 0 and fileExists(safeJoin(tenant, rel))
        except CatchableError:
          ok = false
        if not ok: allOk = false
        report.add(%*{"verifier": kind, "path": rel, "ok": ok})
      of "file_contains":
        let rel = verifier{"path"}.getStr("")
        let needle = verifier{"needle"}.getStr(verifier{"text"}.getStr(""))
        var ok = false
        try:
          let full = safeJoin(tenant, rel)
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
      of "image_generated":
        let required = max(1, verifier{"count"}.getInt(1).int)
        let policyFilter = verifier{"policy"}.getStr("").strip().toLowerAscii()
        let minBytes = max(0, verifier{"min_bytes"}.getInt(0).int)
        let imageFilter = verifier{"image_id"}.getStr("").strip()
        var imageSql = "SELECT image_id, paths_json FROM image_generations WHERE task_id=? AND status='succeeded'"
        var imageParams = @[%h.taskId]
        if policyFilter.len > 0:
          imageSql.add(" AND policy=?")
          imageParams.add(%policyFilter)
        if imageFilter.len > 0:
          imageSql.add(" AND image_id=?")
          imageParams.add(%imageFilter)
        imageSql.add(" ORDER BY created_at DESC")
        var produced = 0
        var satisfied = 0
        for r in store.query(imageSql, imageParams):
          let paths = r.getJson("paths_json", newJArray())
          if paths.kind != JArray:
            continue
          for entry in paths.elems:
            if entry.kind != JObject:
              continue
            inc produced
            let storedPath = absolutePath(entry{"path"}.getStr(""))
            let storedBytes = entry{"bytes"}.getInt(0).int
            if storedPath.len > 0 and fileExists(storedPath) and storedBytes >= minBytes:
              inc satisfied
        let ok = satisfied >= required
        if not ok: allOk = false
        report.add(%*{"verifier": kind, "policy": policyFilter, "image_id": imageFilter, "ok": ok, "required": required, "satisfied": satisfied, "produced": produced, "min_bytes": minBytes})
      of "artifact_exists":
        let artifactKind = verifier{"kind"}.getStr("").strip().toLowerAscii()
        let nameFilter = verifier{"name"}.getStr("").strip()
        let artifactFilter = verifier{"artifact_id"}.getStr("").strip()
        let required = max(1, verifier{"count"}.getInt(1).int)
        var artifactSql = "SELECT artifact_id, name, kind, path, mime_type FROM artifacts WHERE task_id=?"
        var artifactParams = @[%h.taskId]
        if artifactKind.len > 0:
          artifactSql.add(" AND kind=?")
          artifactParams.add(%artifactKind)
        if artifactFilter.len > 0:
          artifactSql.add(" AND artifact_id=?")
          artifactParams.add(%artifactFilter)
        var matched = newJArray()
        for r in store.query(artifactSql, artifactParams):
          let storedPath = absolutePath(r.getStr("path"))
          if storedPath.len == 0 or not fileExists(storedPath):
            continue
          let storedName = r.getStr("name")
          if nameFilter.len > 0 and nameFilter notin storedName:
            continue
          matched.add(%*{"artifact_id": r.getStr("artifact_id"), "name": storedName, "kind": r.getStr("kind"), "mime_type": r.getStr("mime_type"), "path": r.getStr("path")})
        let ok = matched.elems.len >= required
        if not ok: allOk = false
        report.add(%*{"verifier": kind, "kind_filter": artifactKind, "name": nameFilter, "artifact_id": artifactFilter, "ok": ok, "required": required, "matched": matched.elems.len, "artifacts": matched})
      else:
        allOk = false
        report.add(%*{"verifier": kind, "ok": false, "error": "unknown verifier"})
  if not configured:
    let progress = sigma{"progress"}.getFloat(0.0)
    let progressOk = progress >= 0.999
    if not progressOk: allOk = false
    report.add(%*{"verifier": "state_path_equals", "path": "/progress", "ok": progressOk, "expected": 1.0, "actual": progress})
    var unresolved = 0
    if sigma.hasKey("subgoals") and sigma["subgoals"].kind == JArray:
      for item in sigma["subgoals"].elems:
        if item.kind == JObject and item{"status"}.getStr("open") in ["open", "in_progress", "queued", "running"]:
          inc unresolved
    let subgoalOk = unresolved == 0
    if not subgoalOk: allOk = false
    report.add(%*{"verifier": "all_subgoals_resolved", "ok": subgoalOk, "unresolved": unresolved})
    let blockers = if sigma.hasKey("blockers") and sigma["blockers"].kind == JArray: sigma["blockers"].elems.len else: 0
    let blockerOk = blockers == 0
    if not blockerOk: allOk = false
    report.add(%*{"verifier": "no_blockers", "ok": blockerOk, "blockers_count": blockers})
  if spec.hasKey("required_files") and spec["required_files"].kind == JArray:
    for item in spec["required_files"].elems:
      let rel = item.getStr("")
      var ok = false
      try:
        ok = rel.len > 0 and fileExists(safeJoin(tenant, rel))
      except CatchableError:
        ok = false
      if not ok: allOk = false
      report.add(%*{"verifier": "file_exists", "path": rel, "ok": ok})
  (allOk, report)

proc finalizeTask(h: TaskHandle, finalText: string = "") {.async.} =
  let deterministic = verifyTerminal(h)
  acquire(h.lock)
  h.obs["verification_report"] = copy(deterministic[1])
  release(h.lock)
  if not deterministic[0]:
    h.verified = false
    h.persistReflection("terminal_verification_failed", "continue work until deterministic terminal requirements are satisfied", "runtime", %*{"final": finalText}, deterministic[1])
    h.persistTask()
    h.emit(%*{"type": "verification_failed", "verification_report": deterministic[1]})
    return
  acquire(h.lock)
  h.verified = true
  h.status = "succeeded"
  h.terminalReason = "all configured verifiers satisfied"
  h.sigma["progress"] = %1.0
  h.sigma["phase"] = %"terminal"
  h.orchestratorState = osTerminal
  if finalText.len > 0:
    h.obs["final"] = %finalText
  release(h.lock)
  h.persistTask()
  h.emit(%*{"type": "done", "status": "succeeded", "verified": true, "content": finalText, "verification_report": deterministic[1]})

proc execute(engine: StateTransitionEngine, h: TaskHandle) {.async.} =
  if engine.isNil or h.isNil:
    return
  if h.transitionBusy:
    return
  h.transitionBusy = true
  try:
    var attempt = 0
    while attempt < max(1, engine.maxRetries):
      acquire(h.lock)
      let step = currentPlanStep(h.sigma)
      release(h.lock)
      if step.isNil:
        return
      try:
        discard await h.modelStep(step)
        return
      except CatchableError:
        inc attempt
        if attempt >= max(1, engine.maxRetries):
          raise
        await sleepAsync(100 * attempt)
  finally:
    h.transitionBusy = false

proc executeStep(h: TaskHandle) {.async.} =
  if transitionEngine.isNil:
    transitionEngine = newStateTransitionEngine()
  await transitionEngine.execute(h)

proc executeMicroAction(h: TaskHandle): Future[bool] {.async.} =
  acquire(h.lock)
  if not h.sigma.hasKey("system1") or h.sigma["system1"].kind != JObject or not h.sigma["system1"].hasKey("queued_actions") or h.sigma["system1"]["queued_actions"].kind != JArray or h.sigma["system1"]["queued_actions"].elems.len == 0:
    release(h.lock)
    return false
  let action = copy(h.sigma["system1"]["queued_actions"][0])
  let microStepId = h.sigma{"plan"}{"current_step_id"}.getStr("")
  h.sigma["system1"]["queued_actions"].elems.delete(0)
  release(h.lock)
  if action.kind != JObject:
    return false
  let result = await h.executeToolAction(action, modelRoleName(mrOrchestrator), microStepId)
  acquire(h.lock)
  inc h.stepIndex
  h.obs = %*{"status": (if result.ok: "tool_completed" else: "tool_failed"), "action": action, "tool_result": result.payload, "message": result.message, "receipt": result.receipt}
  release(h.lock)
  h.checkpoint(action, %*{"receipt": result.receipt, "ok": result.ok})
  h.persistTask()
  return result.ok

proc completionCheck(h: TaskHandle): Future[(bool, string)] {.async.} =
  h.transitionOrchestrator(osValidate)
  acquire(h.lock)
  let sigma = copy(h.sigma)
  let obs = copy(h.obs)
  let goal = h.sigma{"goal"}.getStr(h.title)
  var expectedCriteria = newJArray()
  if h.sigma{"plan"}{"completion_criteria"}.kind == JArray:
    expectedCriteria = copy(h.sigma{"plan"}{"completion_criteria"})
  elif h.sigma{"route"}{"completion_criteria"}.kind == JArray:
    expectedCriteria = copy(h.sigma{"route"}{"completion_criteria"})
  release(h.lock)
  if runningSubAgentCount(h.taskId) > 0:
    return (false, "")
  let userText = "GOAL:\n" & goal & "\n\nEXPECTED COMPLETION CRITERIA:\n" & canonical(expectedCriteria) & "\n\nSTATE:\n" & canonical(sigma) & "\n\nLATEST OBSERVATION:\n" & canonical(obs) & "\n\nSUBAGENT TREE:\n" & canonical(subAgentTreeJson(h.taskId))
  let resp = await cerebrasCall(%*[{"role": "system", "content": promptText("completion_evaluator")}, {"role": "user", "content": userText}], true)
  if resp.totalTokens > 0 and not chargeTokens(h.tenantId, h.taskId, resp.totalTokens):
    h.haltForBudget()
    return (false, "")
  h.recordModelContext(mrOrchestrator, "completion_check", resp.content, %*{"model": resp.model, "provider": providerName(resp.provider)})
  let node = parseJsonObjectLoose(resp.content)
  if node.isNil or node{"complete"}.kind != JBool or node{"criteria"}.kind != JArray:
    h.persistReflection("completion_check_invalid", "re-evaluate completion from recorded evidence with one result per configured criterion", "orchestrator", %*{"raw_output": resp.content}, obs)
    h.persistTask()
    return (false, "")
  let criteria = node["criteria"]
  if expectedCriteria.elems.len > 0 and criteria.elems.len != expectedCriteria.elems.len:
    h.persistReflection("completion_check_invalid", "criteria count must exactly match configured completion criteria", "orchestrator", %*{"expected_count": expectedCriteria.elems.len, "actual_count": criteria.elems.len}, node)
    return (false, "")
  var allSatisfied = true
  var normalized = newJArray()
  for i, item in criteria.elems:
    if item.kind != JObject or item{"satisfied"}.kind != JBool:
      allSatisfied = false
      continue
    let satisfied = item{"satisfied"}.getBool(false)
    if not satisfied:
      allSatisfied = false
    var entry = copy(item)
    if expectedCriteria.elems.len > i:
      entry["criterion"] = copy(expectedCriteria[i])
    entry["status"] = %(if satisfied: "satisfied" else: "unsatisfied")
    normalized.add(entry)
  acquire(h.lock)
  h.sigma["completion_checklist"] = normalized
  release(h.lock)
  h.persistTask()
  let complete = node{"complete"}.getBool(false) and allSatisfied and (expectedCriteria.elems.len == 0 or normalized.elems.len == expectedCriteria.elems.len)
  if complete:
    return (true, node{"final_response"}.getStr("Task completed."))
  let nextPlan = node{"next_plan"}
  if nextPlan.kind == JArray and nextPlan.elems.len > 0:
    h.replaceRemainingPlan(nextPlan)
    acquire(h.lock)
    h.sigma["step_summary"] = %node{"reason"}.getStr("additional work required")
    release(h.lock)
    h.persistTask()
    h.emit(%*{"type": "plan_replaced", "steps": nextPlan, "reason": node{"reason"}.getStr("")})
  else:
    h.persistReflection("completion_criteria_unsatisfied", "produce additional concrete plan steps", "orchestrator", %*{"reason": node{"reason"}.getStr("")}, node)
  return (false, "")

proc tryBeginTransition(h: TaskHandle): bool =
  acquire(h.lock)
  if h.transitionBusy or h.status != "running" or h.paused or h.stopRequested:
    release(h.lock)
    return false
  h.transitionBusy = true
  release(h.lock)
  true

proc endTransition(h: TaskHandle) =
  acquire(h.lock)
  h.transitionBusy = false
  release(h.lock)

proc system2Think(h: TaskHandle) {.async.} =
  if not h.tryBeginTransition():
    return
  try:
    acquire(h.lock)
    let needsRoute = h.sigma{"route"}.kind != JObject or h.sigma{"route"}.len == 0
    let goal = h.sigma{"goal"}.getStr(h.title)
    let sigma = copy(h.sigma)
    let obs = copy(h.obs)
    let obsDigest = sha1Hex(canonical(obs))
    let previousDigest = h.sigma{"system2"}{"last_observation_digest"}.getStr("")
    let obsStatus = h.obs{"status"}.getStr("")
    release(h.lock)
    if needsRoute:
      let route = await routeTask(goal, sigma, obs, h.tenantId, h.taskId)
      h.applyRoute(route)
      let vector = newJArray()
      h.persistCognition(vector, 1.0, route.intent, "initial model-decided route and task decomposition", route.raw)
      acquire(h.lock)
      h.sigma["system2"]["last_observation_digest"] = %obsDigest
      h.sigma["system2"]["gate"] = %1.0
      h.sigma["system2"]["subgoal"] = %route.intent
      h.sigma["system2"]["strategy"] = %"initial model-decided route and task decomposition"
      release(h.lock)
      h.persistTask()
      return
    if obsDigest == previousDigest:
      return
    let strategicTrigger = obsStatus in ["tool_failed", "step_error", "model_output_invalid", "orchestrator_error"] or sigma{"blockers"}.len > 0 or currentPlanStep(sigma).isNil
    if not strategicTrigger:
      acquire(h.lock)
      h.sigma["system2"]["last_observation_digest"] = %obsDigest
      release(h.lock)
      h.persistTask()
      return
    let systemText = promptText("orchestrator_system2")
    let userText = "GOAL:\n" & goal & "\n\nSTATE:\n" & canonical(sigma) & "\n\nLATEST OBSERVATION:\n" & canonical(obs) & "\n\nSUBAGENT TREE:\n" & canonical(subAgentTreeJson(h.taskId)) & "\n\nTOOLS:\n" & canonical(toolCatalog()) & "\n\nAVAILABLE MODEL REFERENCE SKILLS:\n" & referenceSkillCatalog() & "\n\nVALID SPECIALIST MODEL ROLE IDS:\n" & configuredModelRoleNames().join(", ") & "\n\nVALID SUBAGENT MODEL ROLE IDS:\n" & configuredSubAgentModelRoleNames().join(", ")
    let resp = await cerebrasCall(%*[{"role": "system", "content": systemText}, {"role": "user", "content": userText}], true)
    if resp.totalTokens > 0 and not chargeTokens(h.tenantId, h.taskId, resp.totalTokens):
      h.haltForBudget()
      return
    h.recordModelContext(mrOrchestrator, "system2", resp.content, %*{"model": resp.model})
    let node = parseJsonObjectLoose(resp.content)
    if node.isNil:
      h.persistReflection("system2_output_invalid", "re-run strategic analysis from exact observation", "orchestrator", %*{"raw_output": resp.content}, obs)
      return
    if not node.hasKey("cognition") or node["cognition"].kind != JArray or node["cognition"].elems.len != 16:
      h.persistReflection("system2_cognition_invalid", "return exactly 16 numeric cognition values", "orchestrator", %*{"raw_output": resp.content}, obs)
      return
    var vector = copy(node["cognition"])
    for item in vector.elems:
      if item.kind notin {JInt, JFloat}:
        h.persistReflection("system2_cognition_invalid", "every cognition entry must be numeric", "orchestrator", %*{"raw_output": resp.content}, obs)
        return
    let gate = max(0.0, min(1.0, node{"gate"}.getFloat(0.5)))
    let subgoal = node{"subgoal"}.getStr("")
    let strategy = node{"strategy"}.getStr("")
    acquire(h.lock)
    h.sigma["system2"]["gate"] = %gate
    h.sigma["system2"]["subgoal"] = %subgoal
    h.sigma["system2"]["strategy"] = %strategy
    h.sigma["system2"]["cognition"] = copy(vector)
    h.sigma["system2"]["last_observation_digest"] = %obsDigest
    if node.hasKey("queued_actions") and node["queued_actions"].kind == JArray:
      for action in node["queued_actions"].elems:
        if action.kind == JObject and action{"tool"}.getStr("").len > 0:
          h.sigma["system1"]["queued_actions"].add(copy(action))
    let shouldReplacePlan = node{"replan"}.getBool(false) and node.hasKey("next_plan") and node["next_plan"].kind == JArray and node["next_plan"].elems.len > 0
    let replacementPlan = if shouldReplacePlan: copy(node["next_plan"]) else: newJArray()
    release(h.lock)
    if shouldReplacePlan:
      h.replaceRemainingPlan(replacementPlan)
      h.emit(%*{"type": "plan_replaced", "steps": replacementPlan, "reason": strategy})
    h.persistCognition(vector, gate, subgoal, strategy, node)
    h.persistTask()
    h.emit(%*{"type": "cognition", "gate": gate, "subgoal": subgoal, "strategy": strategy, "cognition": vector})
  except CatchableError as e:
    acquire(h.lock)
    h.obs = %*{"status": "orchestrator_error", "error": e.msg}
    release(h.lock)
    h.persistTask()
    h.emit(%*{"type": "orchestrator_error", "error": e.msg})
  finally:
    h.endTransition()

proc system1Tick(h: TaskHandle) {.async.} =
  if not h.tryBeginTransition():
    return
  try:
    var queuedAction: JsonNode = nil
    var queuedActorStep = ""
    acquire(h.lock)
    if h.maxSteps > 0 and h.stepIndex >= h.maxSteps:
      h.status = "halted"
      h.stopRequested = true
      h.verified = false
      h.terminalReason = "max_steps reached"
      h.sigma["phase"] = %"terminal"
      h.orchestratorState = osTerminal
      release(h.lock)
      h.persistTask()
      h.emit(%*{"type": "halted", "reason": "max_steps reached"})
      return
    let preState = copy(h.sigma)
    let routeReady = h.sigma{"route"}.kind == JObject and h.sigma{"route"}.len > 0
    if h.sigma{"system1"}{"queued_actions"}.kind == JArray and h.sigma["system1"]["queued_actions"].elems.len > 0:
      queuedAction = copy(h.sigma["system1"]["queued_actions"][0])
      h.sigma["system1"]["queued_actions"].elems.delete(0)
      queuedActorStep = h.sigma{"plan"}{"current_step_id"}.getStr("")
    let step = if routeReady: currentPlanStep(h.sigma) else: nil
    release(h.lock)
    if not routeReady:
      return
    if not queuedAction.isNil:
      h.transitionOrchestrator(osAct)
      let started = getMonoTime()
      let toolRes = await h.executeToolAction(queuedAction, modelRoleName(mrOrchestrator), queuedActorStep)
      let latency = int((getMonoTime() - started).inMilliseconds)
      acquire(h.lock)
      h.obs = %*{"status": (if toolRes.ok: "tool_completed" else: "tool_failed"), "step_id": h.sigma{"plan"}{"current_step_id"}.getStr(""), "model": "orchestrator", "action": queuedAction, "tool_result": toolRes.payload, "message": toolRes.message, "receipt": toolRes.receipt}
      h.sigma["step_summary"] = %toolRes.message
      let postState = copy(h.sigma)
      let observation = copy(h.obs)
      release(h.lock)
      let receipt = %*{"receipt": toolRes.receipt, "ok": toolRes.ok, "source": "system2_queue"}
      h.logRawTrace("", preState, queuedAction, observation, %*{"source": "system2_queue"}, postState, receipt, toolRes.ok, latency)
      h.checkpoint(queuedAction, receipt)
      if not toolRes.ok:
        h.persistReflection("queued_tool_failure:" & queuedAction{"tool"}.getStr(""), "return the exact tool failure to the strategic orchestrator for a fresh model decision", "system2", %*{"action": queuedAction, "result": toolRes.payload}, observation)
      h.persistTask()
      return
    if step.isNil:
      let completeResult = await h.completionCheck()
      if completeResult[0]:
        h.transitionOrchestrator(osConsolidate)
        await h.finalizeTask(completeResult[1])
      return
    discard await h.modelStep(step)
  except CatchableError as e:
    acquire(h.lock)
    let failedStepId = h.sigma{"plan"}{"current_step_id"}.getStr("")
    h.obs = %*{"status": "step_error", "step_id": failedStepId, "error": e.msg}
    h.sigma["step_summary"] = %("step error: " & e.msg)
    let verifier = copy(h.obs)
    release(h.lock)
    if failedStepId.len > 0:
      h.setStepStatus(failedStepId, "needs_replan")
    h.persistReflection("step_error", "return the exact runtime exception to the strategic orchestrator for a fresh model decision", "runtime", %*{"step_id": failedStepId, "error": e.msg}, verifier)
    h.persistTask()
    h.emit(%*{"type": "step_error", "step_id": failedStepId, "error": e.msg})
  finally:
    h.endTransition()

proc system2Loop(h: TaskHandle) {.async.} =
  while true:
    await sleepAsync(System2HzInterval)
    acquire(h.lock)
    let keep = h.status in ["running", "queued"] and not h.stopRequested
    let should = h.status == "running" and not h.paused
    release(h.lock)
    if not keep:
      break
    if should:
      await h.system2Think()

proc system1Loop(h: TaskHandle) {.async.} =
  while true:
    await sleepAsync(System1HzInterval)
    acquire(h.lock)
    let keep = h.status in ["running", "queued"] and not h.stopRequested
    let should = h.status == "running" and not h.paused
    release(h.lock)
    if not keep:
      break
    if should:
      await h.system1Tick()
      await sleepAsync(200)

proc taskSupervisor(h: TaskHandle) {.async.} =
  let s2 = h.system2Loop()
  try:
    await h.system1Loop()
  finally:
    acquire(h.lock)
    if h.status notin ["running", "queued"]:
      h.stopRequested = true
    let terminal = h.status in ["succeeded", "failed", "halted", "stopped"]
    release(h.lock)
    try:
      await s2
    except CatchableError:
      discard
    h.loopActive.store(false, moRelease)
    if terminal:
      acquire(tasksLock)
      if activeTasks.hasKey(h.taskId):
        activeTasks.del(h.taskId)
      release(tasksLock)

proc launchTask(h: TaskHandle): bool =
  var expected = false
  if not h.loopActive.compareExchange(expected, true, moAcquireRelease, moAcquire):
    return false
  acquire(h.lock)
  h.status = "running"
  h.stopRequested = false
  h.paused = false
  release(h.lock)
  h.persistTask()
  asyncCheck h.taskSupervisor()
  true

proc attachBroadcast(h: TaskHandle)

proc allowedToolsForTenant(tenantId: string): HashSet[string] =
  result = initHashSet[string]()
  let rows = store.query("SELECT allowed_tools FROM tenants WHERE tenant_id=?", @[%tenantId])
  if rows.len == 0:
    return
  let raw = rows[0].getStr("allowed_tools", "[]")
  let node = parseJson(raw)
  if node.kind != JArray:
    raise newException(DbError, "tenant allowed_tools is not an array")
  for item in node.elems:
    if item.kind != JString:
      raise newException(DbError, "tenant allowed_tools contains a non-string entry")
    let name = item.getStr("")
    if toolRegistry.hasKey(name):
      result.incl(name)

proc createTask(title: string, spec: JsonNode, tenantId: string = ""): TaskHandle =
  let taskId = newId("task")
  let resolvedTenant = if tenantId.len > 0: tenantId else: defaultTenantId
  let nSpec = if spec.isNil or spec.kind != JObject: %*{"goal": title} else: copy(spec)
  let goal = nSpec{"goal"}.getStr(title)
  var sigma = if nSpec.hasKey("initial_state") and nSpec["initial_state"].kind == JObject: copy(nSpec["initial_state"]) else: defaultSigma(goal)
  ensureStateShape(sigma, goal)
  let obs = %*{"status": "initialized", "message": "agent task launched"}
  let ts = nowF()
  let requestedMaxSteps = nSpec{"max_steps"}.getInt(0)
  discard store.exec("INSERT INTO tasks (task_id, tenant_id, title, spec_json, initial_state_json, state_json, latest_obs_json, status, step_index, max_steps, tokens_used, terminal_reason, verified, created_at, updated_at) VALUES (?,?,?,?,?,?,?,'queued',0,?,0,'',0,?,?)",
    @[%taskId, %resolvedTenant, %title, %($nSpec), %($sigma), %($sigma), %($obs), %requestedMaxSteps, %ts, %ts])
  result = TaskHandle(taskId: taskId, tenantId: resolvedTenant, title: title, spec: nSpec, sigma: sigma, obs: obs, stepIndex: 0, maxSteps: requestedMaxSteps, status: "queued", terminalReason: "", verified: false, paused: false, stopRequested: false, transitionBusy: false, orchestratorState: osPerceive, subscribers: @[], cognition: newJObject(), cognitionAt: 0.0, allowedTools: initHashSet[string](), broadcastAttached: false, lastPlannedDigest: "")
  result.allowedTools = allowedToolsForTenant(resolvedTenant)
  initLock(result.lock)
  result.loopActive.store(false, moRelaxed)
  acquire(tasksLock)
  activeTasks[taskId] = result
  release(tasksLock)
  attachBroadcast(result)
  result.checkpoint(newJObject(), %*{"status": "initialized"})

proc restoreTask(taskId: string): TaskHandle =
  acquire(tasksLock)
  if activeTasks.hasKey(taskId):
    result = activeTasks[taskId]
    release(tasksLock)
    return
  release(tasksLock)
  let rows = store.query("SELECT * FROM tasks WHERE task_id=?", @[%taskId])
  if rows.len == 0:
    return nil
  let r = rows[0]
  var sigma = r.getJson("state_json", defaultSigma(r.getStr("title")))
  ensureStateShape(sigma, sigma{"goal"}.getStr(r.getStr("title")))
  let phase = sigma{"phase"}.getStr("perceive").toLowerAscii()
  let orch = case phase
    of "deliberate": osDeliberate
    of "act": osAct
    of "validate": osValidate
    of "reflect": osReflect
    of "consolidate": osConsolidate
    of "terminal": osTerminal
    else: osPerceive
  var restoredCognition = newJObject()
  var cognitionAt = 0.0
  let cognitionRows = store.query("SELECT vector_json,gate,subgoal,strategy,route_json,created_at FROM cognition WHERE task_id=? ORDER BY created_at DESC LIMIT 1", @[%taskId])
  if cognitionRows.len > 0:
    restoredCognition = %*{"vector": cognitionRows[0].getJson("vector_json", newJArray()), "gate": cognitionRows[0].getFloat("gate"), "subgoal": cognitionRows[0].getStr("subgoal"), "strategy": cognitionRows[0].getStr("strategy"), "route": cognitionRows[0].getJson("route_json")}
    cognitionAt = cognitionRows[0].getFloat("created_at")
  result = TaskHandle(taskId: taskId, tenantId: r.getStr("tenant_id", defaultTenantId), title: r.getStr("title"), spec: r.getJson("spec_json"), sigma: sigma, obs: r.getJson("latest_obs_json"), stepIndex: r.getInt("step_index").int, maxSteps: r.getInt("max_steps").int, status: r.getStr("status"), terminalReason: r.getStr("terminal_reason"), verified: r.getInt("verified") == 1, paused: false, stopRequested: false, transitionBusy: false, orchestratorState: orch, subscribers: @[], cognition: restoredCognition, cognitionAt: cognitionAt, allowedTools: initHashSet[string](), broadcastAttached: false, lastPlannedDigest: "")
  result.allowedTools = allowedToolsForTenant(result.tenantId)
  initLock(result.lock)
  result.loopActive.store(false, moRelaxed)
  if result.status notin ["succeeded", "failed", "halted", "stopped"]:
    acquire(tasksLock)
    activeTasks[taskId] = result
    release(tasksLock)
    attachBroadcast(result)

proc subAgentSnapshot(agentId: string): JsonNode =
  let rows = store.query("SELECT * FROM subagents WHERE agent_id=?", @[%agentId])
  if rows.len == 0:
    return nil
  let r = rows[0]
  %*{
    "agent_id": r.getStr("agent_id"),
    "task_id": r.getStr("task_id"),
    "parent_agent_id": r.getStr("parent_agent_id"),
    "model": r.getStr("model_role"),
    "name": r.getStr("name"),
    "goal": r.getStr("goal"),
    "instructions": r.getStr("instructions"),
    "context": r.getJson("context_json"),
    "state": r.getJson("state_json"),
    "status": r.getStr("status"),
    "result": r.getStr("result"),
    "error": r.getStr("error"),
    "stop_requested": r.getInt("stop_requested") == 1,
    "created_at": r.getFloat("created_at"),
    "updated_at": r.getFloat("updated_at")
  }

proc persistSubAgent(a: SubAgentHandle) =
  if a.isNil:
    return
  acquire(a.lock)
  let messages = copy(a.messages)
  let state = copy(a.state)
  let status = a.status
  let resultText = a.resultText
  let errorText = a.errorText
  let stopped = a.stopRequested
  release(a.lock)
  discard store.exec("UPDATE subagents SET messages_json=?,state_json=?,status=?,result=?,error=?,stop_requested=?,updated_at=? WHERE agent_id=?",
    @[%($messages), %($state), %status, %resultText, %errorText, %(if stopped: 1 else: 0), %nowF(), %a.agentId])

proc persistSubAgentEvent(a: SubAgentHandle, ev: JsonNode) =
  if a.isNil:
    return
  discard store.exec("INSERT INTO subagent_events (agent_id,sequence,event_json,created_at) SELECT ?,COALESCE(MAX(sequence),0)+1,?,? FROM subagent_events WHERE agent_id=?",
    @[%a.agentId, %($ev), %nowF(), %a.agentId])
  if not a.rootTask.isNil:
    var rootEvent = copy(ev)
    if rootEvent.kind != JObject:
      rootEvent = %*{"payload": rootEvent}
    rootEvent["type"] = %("subagent_" & ev{"type"}.getStr("event"))
    rootEvent["agent_id"] = %a.agentId
    rootEvent["parent_agent_id"] = %a.parentAgentId
    rootEvent["model"] = %modelRoleName(a.modelRole)
    a.rootTask.emit(rootEvent)

proc appendSubAgentMessage(a: SubAgentHandle, role, content: string) =
  acquire(a.lock)
  if a.messages.isNil or a.messages.kind != JArray:
    a.messages = newJArray()
  a.messages.add(%*{"role": role, "content": content})
  release(a.lock)

proc restoreSubAgent(agentId: string): SubAgentHandle =
  acquire(subAgentsLock)
  if activeSubAgents.hasKey(agentId):
    result = activeSubAgents[agentId]
    release(subAgentsLock)
    return
  release(subAgentsLock)
  let rows = store.query("SELECT * FROM subagents WHERE agent_id=?", @[%agentId])
  if rows.len == 0:
    return nil
  let r = rows[0]
  let taskId = r.getStr("task_id")
  let root = restoreTask(taskId)
  if root.isNil:
    return nil
  let modelRole = parseModelRole(r.getStr("model_role"))
  result = SubAgentHandle(
    agentId: agentId,
    taskId: taskId,
    parentAgentId: r.getStr("parent_agent_id"),
    name: r.getStr("name"),
    goal: r.getStr("goal"),
    instructions: r.getStr("instructions"),
    modelRole: modelRole,
    context: r.getJson("context_json"),
    messages: r.getJson("messages_json", newJArray()),
    state: r.getJson("state_json"),
    status: r.getStr("status"),
    resultText: r.getStr("result"),
    errorText: r.getStr("error"),
    stopRequested: r.getInt("stop_requested") == 1,
    rootTask: root
  )
  initLock(result.lock)
  result.loopActive.store(false, moRelaxed)
  if result.status notin ["succeeded", "failed", "stopped"]:
    acquire(subAgentsLock)
    activeSubAgents[agentId] = result
    release(subAgentsLock)

proc createSubAgent(h: TaskHandle, args: JsonNode): SubAgentHandle =
  let modelName = args{"model"}.getStr("").strip()
  let goal = args{"goal"}.getStr("").strip()
  if modelName.len == 0:
    raise newException(ValueError, "subagent model is required and must be chosen explicitly by the calling model")
  if goal.len == 0:
    raise newException(ValueError, "subagent goal is required")
  let role = parseModelRole(modelName)
  let id = newId("agent")
  let parentId = args{"_actor_agent_id"}.getStr("").strip()
  let name = args{"name"}.getStr(modelRoleName(role) & " subagent").strip()
  let instructions = args{"instructions"}.getStr("")
  let context = if args.hasKey("context") and args["context"].kind in {JObject, JArray}: copy(args["context"]) else: newJObject()
  var messages = newJArray()
  messages.add(%*{"role": "system", "content": subAgentSystem(role)})
  let initial = "SUBAGENT ID:\n" & id &
    "\n\nROOT TASK ID:\n" & h.taskId &
    "\n\nPARENT SUBAGENT ID:\n" & parentId &
    "\n\nDELEGATED GOAL:\n" & goal &
    "\n\nCALLER INSTRUCTIONS:\n" & instructions &
    "\n\nDELEGATED CONTEXT:\n" & canonical(context) &
    "\n\nCURRENT SUBAGENT TREE:\n" & canonical(subAgentTreeJson(h.taskId)) &
    "\n\nAVAILABLE REAL TOOLS:\n" & canonical(toolCatalog()) &
    "\n\nVALID SUBAGENT MODEL ROLE IDS:\n" & configuredSubAgentModelRoleNames().join(", ") &
    "\n\nMODEL REFERENCE SKILLS:\n" & referenceSkillCatalog()
  messages.add(%*{"role": "user", "content": initial})
  if role in {mrGemini38, mrGrok43} and h.spec.hasKey("messages") and h.spec["messages"].kind == JArray:
    for original in h.spec["messages"].elems:
      if original.kind != JObject:
        continue
      let content = original{"content"}
      if content.kind != JArray:
        continue
      var hasMedia = false
      for part in content.elems:
        if part.kind == JObject and part{"type"}.getStr("") in ["image", "image_url", "input_image", "video", "video_url", "input_video", "document", "file", "input_file"]:
          hasMedia = true
          break
      if hasMedia:
        messages.add(copy(original))
  let ts = nowF()
  let state = %*{
    "cycle": "analyze",
    "iteration": 0,
    "last_action": newJNull(),
    "last_observation": newJNull(),
    "summary": ""
  }
  discard store.exec("INSERT INTO subagents (agent_id,task_id,parent_agent_id,model_role,name,goal,instructions,context_json,messages_json,state_json,status,result,error,stop_requested,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,'queued','','',0,?,?)",
    @[%id, %h.taskId, %parentId, %modelRoleName(role), %name, %goal, %instructions, %($context), %($messages), %($state), %ts, %ts])
  result = SubAgentHandle(
    agentId: id,
    taskId: h.taskId,
    parentAgentId: parentId,
    name: name,
    goal: goal,
    instructions: instructions,
    modelRole: role,
    context: context,
    messages: messages,
    state: state,
    status: "queued",
    resultText: "",
    errorText: "",
    stopRequested: false,
    rootTask: h
  )
  initLock(result.lock)
  result.loopActive.store(false, moRelaxed)
  acquire(subAgentsLock)
  activeSubAgents[id] = result
  release(subAgentsLock)
  result.persistSubAgentEvent(%*{"type": "created", "goal": goal, "name": name})

proc subAgentActionWithActor(a: SubAgentHandle, action: JsonNode): JsonNode =
  result = copy(action)
  if result.isNil or result.kind != JObject:
    result = newJObject()
  var args = result{"args"}
  if args.isNil or args.kind != JObject:
    args = newJObject()
  else:
    args = copy(args)
  args["_actor_agent_id"] = %a.agentId
  args["_actor_model"] = %modelRoleName(a.modelRole)
  result["args"] = args

proc pruneSubAgentMessages(messages: JsonNode, keepRecent: int): JsonNode =
  result = newJArray()
  if messages.isNil or messages.kind != JArray:
    return
  if messages.elems.len > 0 and messages[0].kind == JObject and messages[0]{"role"}.getStr("") == "system":
    result.add(copy(messages[0]))
  let startAt = max(1, messages.elems.len - max(2, keepRecent))
  for i in startAt ..< messages.elems.len:
    result.add(copy(messages[i]))

proc verifySubAgentResult(a: SubAgentHandle, candidate: string, modelNode: JsonNode): Future[(bool, JsonNode)] {.async.} =
  if a.isNil or a.rootTask.isNil:
    return (false, %*{"verified": false, "reason": "missing root task"})
  let descendantsRunning = store.query("SELECT COUNT(*) AS c FROM subagents WHERE task_id=? AND parent_agent_id=? AND status NOT IN ('succeeded','failed','stopped')", @[%a.taskId, %a.agentId])
  if descendantsRunning.len > 0 and descendantsRunning[0].getInt("c", 0) > 0:
    return (false, %*{"verified": false, "reason": "child subagents are still running"})
  acquire(a.lock)
  let state = copy(a.state)
  let context = copy(a.context)
  release(a.lock)
  let payload = %*{"agent_id": a.agentId, "goal": a.goal, "instructions": a.instructions, "context": context, "state": state, "candidate_result": candidate, "model_output": copy(modelNode)}
  let resp = await cerebrasCall(%*[{"role": "system", "content": promptText("subagent_verifier")}, {"role": "user", "content": canonical(payload)}], true)
  if resp.totalTokens > 0 and not chargeTokens(a.rootTask.tenantId, a.taskId, resp.totalTokens):
    a.rootTask.haltForBudget()
    return (false, %*{"verified": false, "reason": "token budget exhausted"})
  let node = parseJsonObjectLoose(resp.content)
  if node.isNil or node{"verified"}.kind != JBool:
    return (false, %*{"verified": false, "reason": "invalid verifier output", "raw": resp.content})
  return (node{"verified"}.getBool(false), node)

proc subAgentSupervisor(a: SubAgentHandle) {.async.} =
  let startedAt = nowF()
  let maxSeconds = positiveEnvInt("SUBAGENT_MAX_SECONDS", 3600)
  let maxIterations = positiveEnvInt("SUBAGENT_MAX_ITERATIONS", 1000)
  let keepMessages = positiveEnvInt("SUBAGENT_CONTEXT_MESSAGES", 40)
  try:
    acquire(a.lock)
    if a.stopRequested or a.status == "stopping":
      a.status = "stopped"
      release(a.lock)
      a.persistSubAgent()
      a.persistSubAgentEvent(%*{"type": "stopped"})
      return
    a.status = "running"
    a.errorText = ""
    release(a.lock)
    a.persistSubAgent()
    a.persistSubAgentEvent(%*{"type": "started"})
    while true:
      acquire(a.lock)
      let shouldStop = a.stopRequested
      let iteration = a.state{"iteration"}.getInt(0)
      let messages = pruneSubAgentMessages(a.messages, keepMessages)
      release(a.lock)
      if shouldStop:
        acquire(a.lock)
        a.status = "stopped"
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "stopped"})
        break
      acquire(a.rootTask.lock)
      let rootStopping = a.rootTask.stopRequested or a.rootTask.status in ["halted", "failed", "stopped", "succeeded"]
      release(a.rootTask.lock)
      if rootStopping:
        acquire(a.lock)
        a.status = "stopped"
        a.stopRequested = true
        a.errorText = "root task is terminal or stopping"
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "stopped", "reason": "root task terminal"})
        break
      if iteration >= maxIterations or nowF() - startedAt >= float(maxSeconds):
        acquire(a.lock)
        a.status = "failed"
        a.errorText = "subagent liveness bound reached before verified completion"
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "failed", "error": "subagent liveness bound reached before verified completion"})
        break
      let started = getMonoTime()
      if a.modelRole in {mrGemini38, mrGrok43}:
        let imageContext = imageContextMessage(a.rootTask, a.modelRole, imageContextBudget(messages))
        if not imageContext.isNil:
          messages.add(imageContext)
      var resp: LlmResponse
      try:
        resp = await invokeModel(a.modelRole, messages, a.modelRole != mrGemini38, a.rootTask.tenantId, a.taskId)
      except CatchableError as e:
        acquire(a.lock)
        a.status = "failed"
        a.errorText = e.msg
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "failed", "error": e.msg})
        break
      let latency = int((getMonoTime() - started).inMilliseconds)
      a.appendSubAgentMessage("assistant", resp.content)
      let node = parseJsonObjectLoose(resp.content)
      if node.isNil:
        a.appendSubAgentMessage("user", "Your previous output was not a valid autonomous subagent action object. Return exactly one JSON object following the subagent protocol. Preserve the delegated goal and continue from the current real state.")
        acquire(a.lock)
        a.state["cycle"] = %"reflect"
        a.state["last_observation"] = %*{"status": "invalid_model_output", "raw": resp.content}
        a.state["iteration"] = %(iteration + 1)
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "invalid_output", "content": resp.content, "latency_ms": latency})
        continue
      var action = node{"action"}
      let actorChoseTool = not action.isNil and action.kind == JObject and action{"tool"}.getStr("").len > 0
      if not actorChoseTool and a.modelRole in {mrGemini38, mrGrok43} and node.hasKey("images") and node["images"].kind == JArray and node["images"].elems.len > 0:
        action = %*{"tool": "image_generate", "args": %*{"images": node["images"]}}
      if not action.isNil and action.kind == JObject and action{"tool"}.getStr("").len > 0:
        let actorAction = subAgentActionWithActor(a, action)
        acquire(a.lock)
        a.state["cycle"] = %"act"
        a.state["last_action"] = copy(action)
        release(a.lock)
        a.persistSubAgentEvent(%*{"type": "tool_start", "action": action, "latency_ms": latency})
        let toolResult = await a.rootTask.executeToolAction(actorAction, modelRoleName(a.modelRole), a.state{"step_id"}.getStr(""))
        let observation = %*{"ok": toolResult.ok, "payload": copy(toolResult.payload), "message": toolResult.message, "receipt": toolResult.receipt}
        a.appendSubAgentMessage("user", "TOOL OBSERVATION:\n" & canonical(observation) & "\nContinue the atomic agentic cycle from this exact observation. You may use any available tool, create further subagents with any configured model, or finish only after verification.")
        acquire(a.lock)
        a.state["cycle"] = %"observe"
        a.state["last_observation"] = observation
        a.state["summary"] = %node{"summary"}.getStr(toolResult.message)
        a.state["iteration"] = %(iteration + 1)
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "tool_result", "action": action, "observation": observation})
        continue
      let done = node{"done"}.getBool(node{"step_complete"}.getBool(false))
      var finalText = node{"final"}.getStr("")
      if done:
        if finalText.len == 0:
          finalText = node{"summary"}.getStr(resp.content)
        let verification = await a.verifySubAgentResult(finalText, node)
        acquire(a.lock)
        a.state["cycle"] = %"verify"
        a.state["last_verification"] = copy(verification[1])
        a.state["iteration"] = %(iteration + 1)
        release(a.lock)
        if verification[0]:
          acquire(a.lock)
          a.status = "succeeded"
          a.resultText = finalText
          a.errorText = ""
          a.state["summary"] = %node{"summary"}.getStr(finalText)
          release(a.lock)
          a.persistSubAgent()
          a.persistSubAgentEvent(%*{"type": "done", "result": finalText, "verification": verification[1], "latency_ms": latency})
          break
        a.appendSubAgentMessage("user", "VERIFICATION FAILED:\n" & canonical(verification[1]) & "\nContinue working from this evidence. Do not return done=true until the delegated goal is verified.")
        acquire(a.lock)
        a.state["cycle"] = %"reflect"
        release(a.lock)
        a.persistSubAgent()
        a.persistSubAgentEvent(%*{"type": "verification_failed", "verification": verification[1]})
        continue
      a.appendSubAgentMessage("user", "No external action was requested and the delegated goal is not complete. Continue the atomic agentic cycle. Select the next real tool or subagent action yourself, or return done=true only after the goal is actually verified.")
      acquire(a.lock)
      a.state["cycle"] = %"reflect"
      a.state["summary"] = %node{"summary"}.getStr("")
      a.state["iteration"] = %(iteration + 1)
      release(a.lock)
      a.persistSubAgent()
  except CatchableError as e:
    acquire(a.lock)
    a.status = "failed"
    a.errorText = e.msg
    release(a.lock)
    try:
      a.persistSubAgent()
      a.persistSubAgentEvent(%*{"type": "failed", "error": e.msg})
    except CatchableError:
      discard
  finally:
    a.loopActive.store(false, moRelease)
    acquire(subAgentsLock)
    if activeSubAgents.hasKey(a.agentId):
      activeSubAgents.del(a.agentId)
    release(subAgentsLock)

proc launchSubAgent(a: SubAgentHandle): bool =
  if a.isNil:
    return false
  var expected = false
  if not a.loopActive.compareExchange(expected, true, moAcquireRelease, moAcquire):
    return false
  acquire(a.lock)
  if a.status in ["succeeded", "failed", "stopped"] or a.status == "stopping" or a.stopRequested:
    if a.status == "stopping" or a.stopRequested:
      a.status = "stopped"
      a.stopRequested = true
    release(a.lock)
    a.loopActive.store(false, moRelease)
    a.persistSubAgent()
    return false
  a.status = "running"
  a.stopRequested = false
  release(a.lock)
  a.persistSubAgent()
  asyncCheck a.subAgentSupervisor()
  true

proc selectedSubAgentIds(h: TaskHandle, args: JsonNode): seq[string] =
  result = @[]
  let actorId = args{"_actor_agent_id"}.getStr("").strip()
  if args.hasKey("agent_ids") and args["agent_ids"].kind == JArray:
    for item in args["agent_ids"].elems:
      if item.kind != JString:
        continue
      let id = item.getStr("").strip()
      if id.len == 0 or id == actorId or id in result:
        continue
      let rows = store.query("SELECT agent_id FROM subagents WHERE agent_id=? AND task_id=?", @[%id, %h.taskId])
      if rows.len > 0:
        result.add(id)
    return
  let scope = args{"scope"}.getStr("direct_children").strip().toLowerAscii()
  let rows = store.query("SELECT agent_id,parent_agent_id FROM subagents WHERE task_id=? ORDER BY created_at ASC", @[%h.taskId])
  if scope == "task":
    for r in rows:
      let id = r.getStr("agent_id")
      if id.len > 0 and id != actorId:
        result.add(id)
    return
  var direct: seq[string] = @[]
  for r in rows:
    let id = r.getStr("agent_id")
    if r.getStr("parent_agent_id") == actorId and id != actorId:
      direct.add(id)
  if scope != "descendants":
    return direct
  result = direct
  var cursor = 0
  while cursor < result.len:
    let parent = result[cursor]
    for r in rows:
      let id = r.getStr("agent_id")
      if id != actorId and r.getStr("parent_agent_id") == parent and id notin result:
        result.add(id)
    inc cursor

proc spawnSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  try:
    let agent = createSubAgent(h, args)
    discard launchSubAgent(agent)
    if args{"wait"}.getBool(false):
      var waitArgs = %*{"agent_ids": [agent.agentId]}
      waitArgs["_actor_agent_id"] = %args{"_actor_agent_id"}.getStr("")
      return await waitSubAgentsTool(h, waitArgs)
    let snapshot = subAgentSnapshot(agent.agentId)
    return ToolResult(ok: true, payload: snapshot, receipt: "subagent:" & agent.agentId, message: "subagent launched")
  except CatchableError as e:
    return ToolResult(ok: false, payload: %*{"error": e.msg}, receipt: "", message: e.msg)

proc waitSubAgentsTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  let ids = selectedSubAgentIds(h, args)
  if ids.len == 0:
    return ToolResult(ok: true, payload: %*{"agents": newJArray()}, receipt: "subagents:none", message: "no matching subagents")
  let timeoutMs = max(100, args{"timeout_ms"}.getInt(positiveEnvInt("SUBAGENT_WAIT_TIMEOUT_MS", 600000)))
  let started = getMonoTime()
  while true:
    acquire(h.lock)
    let cancelled = h.stopRequested or h.status in ["halted", "failed", "stopped"]
    release(h.lock)
    if cancelled:
      return ToolResult(ok: false, payload: %*{"agents": ids}, receipt: "subagents:cancelled", message: "root task stopped while waiting")
    if int((getMonoTime() - started).inMilliseconds) >= timeoutMs:
      var snapshots = newJArray()
      for id in ids:
        let snapshot = subAgentSnapshot(id)
        if not snapshot.isNil:
          snapshots.add(snapshot)
      return ToolResult(ok: false, payload: %*{"agents": snapshots, "timeout_ms": timeoutMs}, receipt: "subagents:timeout", message: "subagent wait timeout")
    var allTerminal = true
    var snapshots = newJArray()
    for id in ids:
      let snapshot = subAgentSnapshot(id)
      if snapshot.isNil:
        snapshots.add(%*{"agent_id": id, "status": "missing"})
        continue
      snapshots.add(snapshot)
      if snapshot{"status"}.getStr("") notin ["succeeded", "failed", "stopped"]:
        allTerminal = false
    if allTerminal:
      var allSucceeded = true
      for snapshot in snapshots.elems:
        if snapshot.kind == JObject and snapshot{"status"}.getStr("") != "succeeded":
          allSucceeded = false
      return ToolResult(ok: allSucceeded, payload: %*{"agents": snapshots}, receipt: "subagents:" & sha1Hex(canonical(snapshots)), message: (if allSucceeded: "subagents completed" else: "one or more subagents did not succeed"))
    await sleepAsync(100)

proc listSubAgentsTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  let ids = selectedSubAgentIds(h, args)
  var arr = newJArray()
  for id in ids:
    let snapshot = subAgentSnapshot(id)
    if not snapshot.isNil:
      arr.add(snapshot)
  return ToolResult(ok: true, payload: %*{"agents": arr}, receipt: "subagent-list:" & sha1Hex(canonical(arr)), message: "subagent tree returned")

proc getSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  let id = args{"agent_id"}.getStr("").strip()
  if id.len == 0:
    return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "agent_id required")
  let rows = store.query("SELECT task_id FROM subagents WHERE agent_id=?", @[%id])
  if rows.len == 0 or rows[0].getStr("task_id") != h.taskId:
    return ToolResult(ok: false, payload: %*{"agent_id": id}, receipt: "", message: "subagent not found for task")
  let snapshot = subAgentSnapshot(id)
  return ToolResult(ok: true, payload: snapshot, receipt: "subagent:" & id, message: "subagent state returned")

proc messageSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  let id = args{"agent_id"}.getStr("").strip()
  let message = args{"message"}.getStr("").strip()
  if id.len == 0 or message.len == 0:
    return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "agent_id and message required")
  let agent = restoreSubAgent(id)
  if agent.isNil or agent.taskId != h.taskId:
    return ToolResult(ok: false, payload: %*{"agent_id": id}, receipt: "", message: "subagent not found for task")
  acquire(agent.lock)
  let terminal = agent.status in ["succeeded", "failed", "stopped"]
  release(agent.lock)
  if terminal:
    return ToolResult(ok: false, payload: subAgentSnapshot(id), receipt: "subagent:" & id, message: "subagent is already terminal")
  agent.appendSubAgentMessage("user", "PARENT MESSAGE:\n" & message)
  agent.persistSubAgent()
  agent.persistSubAgentEvent(%*{"type": "message", "message": message})
  discard launchSubAgent(agent)
  return ToolResult(ok: true, payload: subAgentSnapshot(id), receipt: "subagent-message:" & id, message: "message delivered")

proc stopSubAgentTool(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
  let id = args{"agent_id"}.getStr("").strip()
  if id.len == 0:
    return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "agent_id required")
  let agent = restoreSubAgent(id)
  if agent.isNil or agent.taskId != h.taskId:
    return ToolResult(ok: false, payload: %*{"agent_id": id}, receipt: "", message: "subagent not found for task")
  acquire(agent.lock)
  if agent.status notin ["succeeded", "failed", "stopped"]:
    agent.stopRequested = true
    agent.status = "stopping"
  release(agent.lock)
  agent.persistSubAgent()
  agent.persistSubAgentEvent(%*{"type": "stop_requested"})
  return ToolResult(ok: true, payload: subAgentSnapshot(id), receipt: "subagent-stop:" & id, message: "stop requested")

proc resumePendingSubAgents() =
  for r in store.query("SELECT agent_id FROM subagents WHERE status IN ('queued','running','stopping') ORDER BY created_at ASC"):
    let agent = restoreSubAgent(r.getStr("agent_id"))
    if not agent.isNil:
      acquire(agent.lock)
      if agent.status == "stopping":
        agent.stopRequested = true
      release(agent.lock)
      discard launchSubAgent(agent)

proc resumePendingTasks() =
  for r in store.query("SELECT task_id FROM tasks WHERE status IN ('queued','running') ORDER BY created_at ASC"):
    let h = restoreTask(r.getStr("task_id"))
    if h != nil:
      discard h.launchTask()

var
  skillGateLock: Lock
  skillGateBusy = false
  validationGate = ValidationGate(epsilon: 1e-9)
  metaAgent = MetaAgent(minOccurrences: 3, lookback: 12, maxCandidates: 3, gate: validationGate)

