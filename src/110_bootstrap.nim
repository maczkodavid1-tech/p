proc seedDefaultSkills() =
  let seeds = @[
    ("filesystem_operations", "filesystem", "task modifies or verifies files", "Inspect actual files, perform the required mutation, then re-read or execute to establish the resulting state.", "WHEN workspace_file_change\nREQUIRE actual_file_state\nSTEP inspect\nSTEP modify\nVERIFY reread_or_execute\nRECOVER inspect_failure_and_repair"),
    ("iterative_code_repair", "coding", "generated or existing code fails", "Execute the real program, read the exact failure, modify the same files, and rerun until the assigned technical criterion is satisfied.", "WHEN code_failure\nREQUIRE real_runtime_output\nSTEP execute\nSTEP diagnose\nSTEP repair\nSTEP rerun\nVERIFY requested_behavior\nRECOVER continue_from_exact_failure"),
    ("browser_workflow", "browser", "task requires web interaction", "Reuse one browser session, inspect the current state, perform one concrete interaction, and inspect the resulting state before continuing.", "WHEN browser_task\nREQUIRE browser_session\nSTEP inspect\nSTEP interact\nSTEP observe\nVERIFY target_state\nRECOVER inspect_current_page"),
    ("image_generation", "media", "task requires image generation or image editing", "Use image_generate with an explicit adult boolean. Route explicit adult image requests through grok43 and all other image requests through gemini38. Use the returned artifact as the only evidence of successful generation.", "WHEN image_generation\nREQUIRE image_generate_tool\nSTEP classify_adult_rating\nSTEP select_grok_for_adult_or_gemini_for_general\nSTEP generate_real_image\nSTEP inspect_artifact_result\nVERIFY_artifact_exists\nRECOVER_return_exact_provider_error")
  ]
  for item in seeds:
    let existing = store.query("SELECT skill_id FROM skills WHERE tenant_id=? AND name=?", @[%defaultTenantId, %item[0]])
    if existing.len == 0:
      let ts = nowF()
      discard store.exec("INSERT INTO skills (skill_id, tenant_id, name, domain, trigger_spec, procedure_spec, skill_code, reward, active, created_at, updated_at) VALUES (?,?,?,?,?,?,?,0.0,1,?,?)",
        @[%newId("skill"), %defaultTenantId, %item[0], %item[1], %item[2], %item[3], %item[4], %ts, %ts])

proc main() =
  randomize()
  initLock(rngLock)
  initLock(tasksLock)
  initLock(sseLock)
  initLock(chatJobsLock)
  initLock(subAgentsLock)
  initLock(skillGateLock)
  transitionEngine = newStateTransitionEngine()
  globalRng = initRand(int64(epochTime() * 1_000_000.0))
  DbFile = envTrim("AGENT_DB_PATH", envTrim("AGENT_DB", "agent_runtime.db"))
  WorkspaceRoot = envTrim("AGENT_WORKSPACE", "workspace")
  knowledgeRoot = envTrim("AGENT_KNOWLEDGE", "knowledge")
  RequestyBaseUrl = stripTrailingSlash(envTrim("REQUESTY_BASE_URL", DefaultRequestyBaseUrl))
  CerebrasBaseUrl = stripTrailingSlash(envTrim("CEREBRAS_BASE_URL", DefaultCerebrasBaseUrl))
  GeminiBaseUrl = stripTrailingSlash(envTrim("GEMINI_BASE_URL", DefaultGeminiBaseUrl))
  InstaVmBaseUrl = stripTrailingSlash(envTrim("INSTAVM_BASE_URL", DefaultInstaVmBaseUrl))
  FlyMyAiBaseUrl = stripTrailingSlash(envTrim("FLYMYAI_BASE_URL", DefaultFlyMyAiBaseUrl))
  FlyMyAiSafeImageModel = envTrim("FLYMYAI_SAFE_MODEL", GptImage25SunburstEditModel)
  FlyMyAiAdultImageModel = envTrim("FLYMYAI_ADULT_MODEL", Seedream5ProImageModel)
  CerebrasGemma4Model = getEnv("CEREBRAS_GEMMA4_MODEL", "").strip()
  PromptConfigFile = envTrim("AGENT_PROMPTS_FILE", "config/prompts.yaml")
  ReferenceSkillRoot = envTrim("AGENT_REFERENCE_SKILLS", "skills")
  PublicRoot = envTrim("AGENT_PUBLIC_ROOT", ".")
  serverPort = parseInt(envTrim("PORT", "8080"))
  promptRegistry = loadPromptRegistry(PromptConfigFile)
  referenceSkills = loadReferenceSkills(ReferenceSkillRoot)
  for requiredPrompt in ["orchestrator_router", "orchestrator_system2", "completion_evaluator", "subagent_core", "subagent_orchestrator", "gpt6_astra", "glm52", "gemini38", "minimax_m3", "grok43", "image_generation", "recursive_reason", "distillation_teacher", "distillation_student", "failure_diagnosis", "meta_skill_synthesis", "knowledge_consolidation", "step_verifier", "subagent_verifier"]:
    discard promptText(requiredPrompt)
  createDir(WorkspaceRoot)
  createDir(WorkspaceRoot / "artifacts")
  if not dirExists(PublicRoot):
    raise newException(IOError, "public root not found: " & PublicRoot)
  if not fileExists(PublicRoot / "index.html"):
    raise newException(IOError, "frontend index not found: " & (PublicRoot / "index.html"))
  createDir(knowledgeRoot)
  store = openStore(DbFile)
  migrate(store)
  defaultTenantId = ensureLocalTenant()
  toolRegistry = initOrderedTable[string, ToolSpec]()
  registerTools()
  registerLegacyTools()
  registerImageTools()
  registerReasonTool()
  discard ensureDefaultTenant()
  seedDefaultSkills()
  ensureDiagnosticSuite(defaultTenantId)
  resumePendingTasks()
  resumePendingSubAgents()
  resumePendingChatJobs()
  asyncCheck knowledgeConsolidationLoop()
  let server = newAsyncHttpServer(maxBody = positiveEnvInt("HTTP_MAX_BODY_BYTES", DefaultMaxRequestBodyBytes))
  echo "Runtime listening on port ", serverPort
  waitFor server.serve(Port(serverPort), handleHttpRequest, address = "0.0.0.0")

when isMainModule:
  main()
