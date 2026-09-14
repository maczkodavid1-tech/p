proc raiseDb(s: Store, ctx: string) =
  raise newException(DbError, ctx & ": " & $sqlite3_errmsg(s.handle))

proc openStore(path: string): Store =
  var db: SqliteDb
  let flags = SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX
  let rc = sqlite3_open_v2(path.cstring, addr db, flags, nil)
  if rc != SQLITE_OK:
    var message = "cannot open database: " & path
    if not db.isNil:
      let err = sqlite3_errmsg(db)
      if err != nil:
        message.add(": " & $err)
      discard sqlite3_close_v2(db)
      db = nil
    raise newException(DbError, message)
  result = Store(handle: db, path: path)
  initLock(result.lock)
  if sqlite3_busy_timeout(db, DbBusyTimeoutMs.cint) != SQLITE_OK:
    let message = $sqlite3_errmsg(db)
    discard sqlite3_close_v2(db)
    result.handle = nil
    deinitLock(result.lock)
    raise newException(DbError, "cannot set SQLite busy timeout: " & message)

proc execRawUnlocked(s: Store, sql: string) =
  var err: cstring
  if sqlite3_exec(s.handle, sql.cstring, nil, nil, addr err) != SQLITE_OK:
    var msg = "sqlite error"
    if err != nil:
      msg = $err
      sqlite3_free(err)
    raise newException(DbError, msg & " :: " & sql)

proc execRaw(s: Store, sql: string) =
  acquire(s.lock)
  defer: release(s.lock)
  s.execRawUnlocked(sql)

proc bindParams(s: Store, st: SqliteStmt, params: seq[JsonNode]) =
  for i, p in params:
    let idx = (i + 1).cint
    var rc: cint
    case p.kind
    of JNull:
      rc = sqlite3_bind_null(st, idx)
    of JInt:
      rc = sqlite3_bind_int64(st, idx, p.getBiggestInt())
    of JFloat:
      rc = sqlite3_bind_double(st, idx, p.getFloat())
    of JBool:
      rc = sqlite3_bind_int64(st, idx, if p.getBool(): 1 else: 0)
    of JString:
      let v = p.getStr()
      rc = sqlite3_bind_text(st, idx, v.cstring, v.len.cint, SQLITE_TRANSIENT)
    else:
      let v = $p
      rc = sqlite3_bind_text(st, idx, v.cstring, v.len.cint, SQLITE_TRANSIENT)
    if rc != SQLITE_OK:
      s.raiseDb("bind failed at parameter " & $idx)

proc execUnlocked(s: Store, sql: string, params: seq[JsonNode] = @[]): int64 =
  var st: SqliteStmt
  if sqlite3_prepare_v2(s.handle, sql.cstring, -1.cint, addr st, nil) != SQLITE_OK:
    s.raiseDb("prepare failed")
  defer: discard sqlite3_finalize(st)
  s.bindParams(st, params)
  let rc = sqlite3_step(st)
  if rc != SQLITE_DONE and rc != SQLITE_ROW:
    s.raiseDb("execute failed")
  result = sqlite3_last_insert_rowid(s.handle)

proc exec(s: Store, sql: string, params: seq[JsonNode] = @[]): int64 =
  acquire(s.lock)
  defer: release(s.lock)
  result = s.execUnlocked(sql, params)

proc execTransaction(s: Store, ops: openArray[SqlOperation]) =
  acquire(s.lock)
  defer: release(s.lock)
  s.execRawUnlocked("BEGIN IMMEDIATE;")
  try:
    for op in ops:
      discard s.execUnlocked(op.sql, op.params)
    s.execRawUnlocked("COMMIT;")
  except CatchableError:
    try:
      s.execRawUnlocked("ROLLBACK;")
    except CatchableError:
      discard
    raise

proc query(s: Store, sql: string, params: seq[JsonNode] = @[]): seq[Row] =
  acquire(s.lock)
  defer: release(s.lock)
  var st: SqliteStmt
  if sqlite3_prepare_v2(s.handle, sql.cstring, -1.cint, addr st, nil) != SQLITE_OK:
    s.raiseDb("prepare failed")
  defer: discard sqlite3_finalize(st)
  s.bindParams(st, params)
  result = @[]
  while true:
    let rc = sqlite3_step(st)
    if rc == SQLITE_DONE:
      break
    if rc != SQLITE_ROW:
      s.raiseDb("query step failed")
    var row = initTable[string, JsonNode]()
    let count = sqlite3_column_count(st)
    for i in 0 ..< count:
      let key = $sqlite3_column_name(st, i)
      if sqlite3_column_type(st, i) == SQLITE_NULL:
        row[key] = newJNull()
      else:
        let raw = sqlite3_column_text(st, i)
        row[key] = if raw == nil: newJNull() else: newJString($raw)
    result.add(row)

proc getStr(r: Row, key: string, fallback = ""): string =
  if r.hasKey(key) and r[key].kind == JString: r[key].getStr() else: fallback

proc getInt(r: Row, key: string, fallback: int64 = 0): int64 =
  if r.hasKey(key) and r[key].kind == JString:
    try:
      return parseBiggestInt(r[key].getStr())
    except CatchableError:
      return fallback
  fallback

proc getFloat(r: Row, key: string, fallback = 0.0): float =
  if r.hasKey(key) and r[key].kind == JString:
    try:
      return parseFloat(r[key].getStr())
    except CatchableError:
      return fallback
  fallback

proc getJson(r: Row, key: string, fallback: JsonNode = nil): JsonNode =
  let raw = r.getStr(key, "")
  if raw.len == 0:
    if fallback.isNil:
      return newJObject()
    return copy(fallback)
  try:
    return parseJson(raw)
  except CatchableError as e:
    raise newException(DbError, "malformed persisted JSON in column " & key & ": " & e.msg)

proc columnExists(s: Store, tableName, columnName: string): bool =
  if tableName.len == 0 or columnName.len == 0:
    return false
  for row in s.query("PRAGMA table_info(" & tableName & ")"):
    if row.getStr("name") == columnName:
      return true
  false

proc migrate(s: Store) =
  s.execRaw("PRAGMA journal_mode=WAL;")
  s.execRaw("PRAGMA synchronous=NORMAL;")
  s.execRaw("PRAGMA foreign_keys=ON;")
  s.execRaw("PRAGMA busy_timeout=15000;")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS tenants (
  tenant_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  api_key_hash TEXT NOT NULL DEFAULT '',
  token_budget INTEGER NOT NULL DEFAULT 9223372036854775807,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  allowed_tools TEXT NOT NULL DEFAULT '[]',
  created_at REAL NOT NULL
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS browser_sessions (
  session_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at REAL NOT NULL,
  created_at REAL NOT NULL,
  FOREIGN KEY(tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);""")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_browser_sessions_token ON browser_sessions(token_hash, expires_at);")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  title TEXT NOT NULL,
  spec_json TEXT NOT NULL,
  initial_state_json TEXT NOT NULL,
  state_json TEXT NOT NULL,
  latest_obs_json TEXT NOT NULL,
  status TEXT NOT NULL,
  step_index INTEGER NOT NULL DEFAULT 0,
  max_steps INTEGER NOT NULL DEFAULT 0,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  terminal_reason TEXT NOT NULL DEFAULT '',
  verified INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  FOREIGN KEY(tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS checkpoints (
  ckpt_id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  step_index INTEGER NOT NULL,
  state_json TEXT NOT NULL,
  obs_json TEXT NOT NULL,
  action_json TEXT NOT NULL,
  patch_json TEXT NOT NULL DEFAULT '{}',
  receipt_json TEXT NOT NULL,
  digest TEXT NOT NULL,
  created_at REAL NOT NULL,
  UNIQUE(task_id, step_index),
  FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS task_events (
  task_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_json TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(task_id, sequence),
  FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS chat_jobs (
  job_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  request_json TEXT NOT NULL,
  status TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  reasoning TEXT NOT NULL DEFAULT '',
  error TEXT NOT NULL DEFAULT '',
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  model TEXT NOT NULL DEFAULT '',
  task_id TEXT NOT NULL DEFAULT '',
  usage_json TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  FOREIGN KEY(tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);""")
  if not s.columnExists("chat_jobs", "model"):
    s.execRaw("ALTER TABLE chat_jobs ADD COLUMN model TEXT NOT NULL DEFAULT '';")
  if not s.columnExists("chat_jobs", "task_id"):
    s.execRaw("ALTER TABLE chat_jobs ADD COLUMN task_id TEXT NOT NULL DEFAULT '';")
  if not s.columnExists("chat_jobs", "usage_json"):
    s.execRaw("ALTER TABLE chat_jobs ADD COLUMN usage_json TEXT NOT NULL DEFAULT '{}';")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS chat_job_events (
  job_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_json TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(job_id, sequence),
  FOREIGN KEY(job_id) REFERENCES chat_jobs(job_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS artifacts (
  artifact_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  kind TEXT NOT NULL,
  mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL,
  FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS image_generations (
  image_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  task_id TEXT NOT NULL DEFAULT '',
  agent_id TEXT NOT NULL DEFAULT '',
  step_id TEXT NOT NULL DEFAULT '',
  director_model TEXT NOT NULL DEFAULT '',
  director_enforced INTEGER NOT NULL DEFAULT 0,
  policy TEXT NOT NULL,
  upstream_model TEXT NOT NULL,
  prompt TEXT NOT NULL,
  size TEXT NOT NULL DEFAULT '',
  quality TEXT NOT NULL DEFAULT '',
  moderation TEXT NOT NULL DEFAULT '',
  watermark INTEGER NOT NULL DEFAULT 0,
  sequential_image_generation TEXT NOT NULL DEFAULT 'disabled',
  optimize_prompt_mode TEXT NOT NULL DEFAULT 'standard',
  reference_count INTEGER NOT NULL DEFAULT 0,
  image_count INTEGER NOT NULL DEFAULT 0,
  artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  paths_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL,
  error TEXT NOT NULL DEFAULT '',
  latency_ms INTEGER NOT NULL DEFAULT 0,
  inference_time REAL NOT NULL DEFAULT 0,
  token_cost INTEGER NOT NULL DEFAULT 0,
  request_json TEXT NOT NULL DEFAULT '{}',
  response_json TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  FOREIGN KEY(tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);""")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_image_generations_task ON image_generations(task_id, created_at DESC);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_image_generations_tenant ON image_generations(tenant_id, status, created_at DESC);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_image_generations_policy ON image_generations(tenant_id, policy, created_at DESC);")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS skills (
  skill_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL DEFAULT 'local',
  name TEXT NOT NULL,
  domain TEXT NOT NULL,
  trigger_spec TEXT NOT NULL,
  procedure_spec TEXT NOT NULL,
  skill_code TEXT NOT NULL DEFAULT '',
  preconditions_json TEXT NOT NULL DEFAULT '[]',
  postconditions_json TEXT NOT NULL DEFAULT '[]',
  failure_modes_json TEXT NOT NULL DEFAULT '[]',
  version INTEGER NOT NULL DEFAULT 1,
  active INTEGER NOT NULL DEFAULT 1,
  success_count INTEGER NOT NULL DEFAULT 0,
  failure_count INTEGER NOT NULL DEFAULT 0,
  reward REAL NOT NULL DEFAULT 0.0,
  embedding_json TEXT NOT NULL DEFAULT '[]',
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  UNIQUE(tenant_id, name)
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS knowledge_docs (
  doc_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL DEFAULT 'local',
  slug TEXT NOT NULL,
  category TEXT NOT NULL,
  path TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  git_commit_hash TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL DEFAULT 0,
  UNIQUE(tenant_id, slug)
);""")
  if not s.columnExists("knowledge_docs", "content"):
    s.execRaw("ALTER TABLE knowledge_docs ADD COLUMN content TEXT NOT NULL DEFAULT '';")
  if not s.columnExists("knowledge_docs", "updated_at"):
    s.execRaw("ALTER TABLE knowledge_docs ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS raw_traces (
  trace_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  step_index INTEGER NOT NULL,
  initial_state_json TEXT NOT NULL,
  skill_id TEXT NOT NULL DEFAULT '',
  action_json TEXT NOT NULL,
  obs_json TEXT NOT NULL,
  delta_json TEXT NOT NULL,
  post_state_json TEXT NOT NULL,
  success INTEGER NOT NULL,
  latency_ms INTEGER NOT NULL,
  receipt_json TEXT NOT NULL,
  immutable_hash TEXT NOT NULL UNIQUE,
  created_at REAL NOT NULL
);""")
  s.execRaw("""
CREATE TRIGGER IF NOT EXISTS raw_traces_no_update
BEFORE UPDATE ON raw_traces
BEGIN
  SELECT RAISE(ABORT, 'raw_traces is an immutable ledger');
END;""")
  s.execRaw("""
CREATE TRIGGER IF NOT EXISTS raw_traces_no_delete
BEFORE DELETE ON raw_traces
BEGIN
  SELECT RAISE(ABORT, 'raw_traces is an immutable ledger');
END;""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS cognition (
  cog_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  step_index INTEGER NOT NULL,
  vector_json TEXT NOT NULL,
  gate REAL NOT NULL,
  subgoal TEXT NOT NULL,
  strategy TEXT NOT NULL,
  route_json TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL
);""")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_cognition_task ON cognition(task_id, created_at DESC);")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS reflections (
  reflection_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  patch_json TEXT NOT NULL,
  failure_point TEXT NOT NULL,
  pivot_action TEXT NOT NULL,
  attribution TEXT NOT NULL,
  verifier_report_json TEXT NOT NULL,
  created_at REAL NOT NULL
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS policy_weights (
  tenant_id TEXT NOT NULL,
  token TEXT NOT NULL,
  weight REAL NOT NULL,
  updates INTEGER NOT NULL DEFAULT 0,
  updated_at REAL NOT NULL,
  PRIMARY KEY(tenant_id, token)
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS diagnostics (
  diagnostic_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  spec_json TEXT NOT NULL,
  expectation_json TEXT NOT NULL,
  created_at REAL NOT NULL
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS meta_agent_events (
  event_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  signature TEXT NOT NULL,
  occurrences INTEGER NOT NULL,
  candidate_json TEXT NOT NULL,
  validation_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  UNIQUE(tenant_id, signature)
);""")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_meta_events_tenant ON meta_agent_events(tenant_id, status, updated_at DESC);")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS subagents (
  agent_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  parent_agent_id TEXT NOT NULL DEFAULT '',
  model_role TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  goal TEXT NOT NULL,
  instructions TEXT NOT NULL DEFAULT '',
  context_json TEXT NOT NULL DEFAULT '{}',
  messages_json TEXT NOT NULL DEFAULT '[]',
  state_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL,
  result TEXT NOT NULL DEFAULT '',
  error TEXT NOT NULL DEFAULT '',
  stop_requested INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
);""")
  s.execRaw("""
CREATE TABLE IF NOT EXISTS subagent_events (
  agent_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_json TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(agent_id, sequence),
  FOREIGN KEY(agent_id) REFERENCES subagents(agent_id) ON DELETE CASCADE
);""")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_subagents_task ON subagents(task_id, parent_agent_id, created_at);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_subagents_status ON subagents(status, updated_at);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_subagent_events_agent ON subagent_events(agent_id, sequence);")
  try:
    s.execRaw("CREATE VIRTUAL TABLE IF NOT EXISTS skill_fts USING fts5(skill_id UNINDEXED, tenant_id UNINDEXED, name, domain, trigger_spec, procedure_spec, tokenize='porter ascii');")
    s.execRaw("DROP TRIGGER IF EXISTS skills_ai;")
    s.execRaw("DROP TRIGGER IF EXISTS skills_ad;")
    s.execRaw("DROP TRIGGER IF EXISTS skills_au;")
    s.execRaw("""
CREATE TRIGGER skills_ai AFTER INSERT ON skills BEGIN
  INSERT INTO skill_fts(skill_id, tenant_id, name, domain, trigger_spec, procedure_spec)
  VALUES (new.skill_id, new.tenant_id, new.name, new.domain, new.trigger_spec, new.procedure_spec || ' ' || new.skill_code);
END;""")
    s.execRaw("""
CREATE TRIGGER skills_ad AFTER DELETE ON skills BEGIN
  DELETE FROM skill_fts WHERE skill_id = old.skill_id;
END;""")
    s.execRaw("""
CREATE TRIGGER skills_au AFTER UPDATE ON skills BEGIN
  DELETE FROM skill_fts WHERE skill_id = old.skill_id;
  INSERT INTO skill_fts(skill_id, tenant_id, name, domain, trigger_spec, procedure_spec)
  VALUES (new.skill_id, new.tenant_id, new.name, new.domain, new.trigger_spec, new.procedure_spec || ' ' || new.skill_code);
END;""")
    s.execRaw("DELETE FROM skill_fts;")
    s.execRaw("INSERT INTO skill_fts(skill_id, tenant_id, name, domain, trigger_spec, procedure_spec) SELECT skill_id, tenant_id, name, domain, trigger_spec, procedure_spec || ' ' || skill_code FROM skills;")
    fts5Available = true
  except CatchableError:
    fts5Available = false
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_raw_traces_task ON raw_traces(task_id, step_index, created_at);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_reflections_task ON reflections(task_id, created_at DESC);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_tasks_updated ON tasks(updated_at DESC);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, sequence);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_chat_jobs_updated ON chat_jobs(updated_at DESC);")
  s.execRaw("CREATE INDEX IF NOT EXISTS idx_chat_job_events_job ON chat_job_events(job_id, sequence);")

proc ensureLocalTenant(): string =
  let rows = store.query("SELECT tenant_id FROM tenants WHERE name='local' ORDER BY created_at ASC LIMIT 1")
  if rows.len > 0:
    return rows[0].getStr("tenant_id")
  let id = "local"
  discard store.exec("INSERT OR IGNORE INTO tenants (tenant_id, name, api_key_hash, token_budget, tokens_used, allowed_tools, created_at) VALUES (?,'local','',9223372036854775807,0,'[]',?)", @[%id, %nowF()])
  id

