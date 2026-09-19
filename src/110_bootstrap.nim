proc seedDefaultSkills() =
    let seeds = @[
      (
        name: "filesystem_operations",
        domain: "filesystem",
        triggerSpec: "task modifies or verifies files",
        procedureSpec: "Every execution route must contain a non-empty completion_criteria field describing the exact observable file state required for success. Inspect actual files, perform the required mutation, then re-read or execute to establish the resulting state. Complete the route only after every completion criterion has been verified.",
        skillCode: "WHEN workspace_file_change\nREQUIRE completion_criteria\nREQUIRE actual_file_state\nSTEP inspect\nSTEP modify\nVERIFY reread_or_execute\nVERIFY completion_criteria_satisfied\nRECOVER inspect_failure_and_repair"
      ),
      (
        name: "iterative_code_repair",
        domain: "coding",
        triggerSpec: "generated or existing code fails",
        procedureSpec: "Every execution route must contain a non-empty completion_criteria field describing the exact observable technical result required for success. Execute the real program, read the exact failure, modify the same files, and rerun until there are zero remaining errors and every assigned technical criterion is satisfied.",
        skillCode: "WHEN code_failure\nREQUIRE completion_criteria\nREQUIRE real_runtime_output\nSTEP execute\nSTEP diagnose\nSTEP repair\nSTEP rerun\nVERIFY zero_errors_remaining\nVERIFY requested_behavior\nVERIFY completion_criteria_satisfied\nRECOVER continue_from_exact_failure"
      ),
      (
        name: "browser_workflow",
        domain: "browser",
        triggerSpec: "task requires web interaction",
        procedureSpec: "Every execution route must contain a non-empty completion_criteria field describing the exact observable browser state required for success. Reuse one browser session, inspect the current state, perform one concrete interaction, and inspect the resulting state before continuing. Complete the route only after every completion criterion has been verified.",
        skillCode: "WHEN browser_task\nREQUIRE completion_criteria\nREQUIRE browser_session\nSTEP inspect\nSTEP interact\nSTEP observe\nVERIFY target_state\nVERIFY completion_criteria_satisfied\nRECOVER inspect_current_page"
      ),
      (
        name: "image_generation",
        domain: "media",
        triggerSpec: "task requires image generation or image editing",
        procedureSpec: "Every execution route must contain a non-empty completion_criteria field describing the exact observable artifact required for success. Use image_generate with an explicit adult boolean. Route explicit adult image requests through grok43 and all other image requests through gemini38. Use the returned artifact as the only evidence of successful generation. Complete the route only after every completion criterion has been verified.",
        skillCode: "WHEN image_generation\nREQUIRE completion_criteria\nREQUIRE image_generate_tool\nSTEP classify_adult_rating\nSTEP select_grok_for_adult_or_gemini_for_general\nSTEP generate_real_image\nSTEP inspect_artifact_result\nVERIFY artifact_exists\nVERIFY completion_criteria_satisfied\nRECOVER return_exact_provider_error"
      )
    ]
    for seed in seeds:
      let ts = nowF()
      let existing = store.query(
        "SELECT skill_id FROM skills WHERE tenant_id=? AND name=?",
        @[%defaultTenantId, %(seed.name)]
      )
      if existing.len == 0:
        discard store.exec(
          "INSERT INTO skills (skill_id, tenant_id, name, domain, trigger_spec, procedure_spec, skill_code, reward, active, created_at, updated_at) VALUES (?,?,?,?,?,?,?,0.0,1,?,?)",
          @[
            %(newId("skill")),
            %defaultTenantId,
            %(seed.name),
            %(seed.domain),
            %(seed.triggerSpec),
            %(seed.procedureSpec),
            %(seed.skillCode),
            %ts,
            %ts
          ]
        )
      else:
        discard store.exec(
          "UPDATE skills SET domain=?, trigger_spec=?, procedure_spec=?, skill_code=?, active=1, updated_at=? WHERE tenant_id=? AND name=?",
          @[
            %(seed.domain),
            %(seed.triggerSpec),
            %(seed.procedureSpec),
            %(seed.skillCode),
            %ts,
            %defaultTenantId,
            %(seed.name)
          ]
        )

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
    VmcoBaseUrl = stripTrailingSlash(envTrim("VMCO_BASE_URL", DefaultVmcoBaseUrl))
    GeminiBaseUrl = stripTrailingSlash(envTrim("GEMINI_BASE_URL", DefaultGeminiBaseUrl))
    InstaVmBaseUrl = stripTrailingSlash(envTrim("INSTAVM_BASE_URL", DefaultInstaVmBaseUrl))
    FlyMyAiBaseUrl = stripTrailingSlash(envTrim("FLYMYAI_BASE_URL", DefaultFlyMyAiBaseUrl))
    FlyMyAiSafeImageModel = envTrim("FLYMYAI_SAFE_MODEL", GptImage25SunburstEditModel)
    FlyMyAiAdultImageModel = envTrim("FLYMYAI_ADULT_MODEL", Seedream5ProImageModel)
    PromptConfigFile = envTrim("AGENT_PROMPTS_FILE", "config/prompts.yaml")
    ReferenceSkillRoot = envTrim("AGENT_REFERENCE_SKILLS", "skills")
    PublicRoot = envTrim("AGENT_PUBLIC_ROOT", ".")
    serverPort = parseInt(envTrim("PORT", "8080"))
    promptRegistry = loadPromptRegistry(PromptConfigFile)
    referenceSkills = loadReferenceSkills(ReferenceSkillRoot)
    for requiredPrompt in [
      "orchestrator_router",
      "orchestrator_system2",
      "completion_evaluator",
      "subagent_core",
      "subagent_orchestrator",
      "gpt6_astra",
      "glm52",
      "gemini38",
      "minimax_m3",
      "grok43",
      "image_generation",
      "recursive_reason",
      "distillation_teacher",
      "distillation_student",
      "failure_diagnosis",
      "meta_skill_synthesis",
      "knowledge_consolidation",
      "step_verifier",
      "subagent_verifier"
    ]:
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
    let server = newAsyncHttpServer(
      maxBody = positiveEnvInt("HTTP_MAX_BODY_BYTES", DefaultMaxRequestBodyBytes)
    )
    echo "Runtime listening on port ", serverPort
    waitFor server.serve(
      Port(serverPort),
      handleHttpRequest,
      address = "0.0.0.0"
    )

when isMainModule:
  main()