import std/[asyncdispatch, asynchttpserver, asyncnet, json, strutils, strformat,
  os, times, tables, sets, sequtils, math, algorithm, random, options,
  locks, hashes, base64, uri, deques, monotimes, sha1, mimetypes,
  httpclient, streams, parseutils, osproc, asyncstreams, net, nativesockets,
  atomics]

const
  SqliteLib = when defined(windows): "sqlite3_64.dll" elif defined(macosx): "libsqlite3.dylib" else: "libsqlite3.so(|.0)"
  DefaultRequestyBaseUrl = "https://router.requesty.ai/v1"
  DefaultCerebrasBaseUrl = "https://api.cerebras.ai/v1"
  DefaultGeminiBaseUrl = "https://generativelanguage.googleapis.com/v1"
  DefaultInstaVmBaseUrl = "https://api.instavm.io"
  DefaultFlyMyAiBaseUrl = "https://api.flymy.ai"
  Gpt6AstraModel = "openai/gpt-6-astra:flex"
  Glm52Model = "zai/glm-5.2"
  Gemini38Model = "gemini-3.8-flash"
  MiniMaxM3Model = "minimaxi/minimax-m3"
  Grok43Model = "grok-4.3"
  Seedream5ProImageModel = "flymyai/bytedance-seedream-5_0_pro"
  GptImage25SunburstEditModel = "flymyai/gpt-image-2-5-sunburst_edit"
  SeedreamReferenceSlots = 14
  DefaultAdultImageSize = "2k"
  DefaultSafeImageSize = "1024x1024"
  DefaultSafeImageQuality = "medium"
  DefaultSequentialImageGeneration = "disabled"
  DefaultOptimizePromptMode = "standard"
  System1HzInterval = 50
  System2HzInterval = 1000
  DbBusyTimeoutMs = 15000
  EmbeddingDim = 128
  RrfK = 60.0
  VmLifetimeSeconds = 2_592_000
  VmDefaultMemoryMb = 4096
  VmDefaultVcpuCount = 4
  DefaultMaxRequestBodyBytes = 67_108_864

var
  DbFile {.threadvar.}: string
  WorkspaceRoot {.threadvar.}: string
  knowledgeRoot {.threadvar.}: string
  RequestyBaseUrl {.threadvar.}: string
  CerebrasBaseUrl {.threadvar.}: string
  GeminiBaseUrl {.threadvar.}: string
  InstaVmBaseUrl {.threadvar.}: string
  FlyMyAiBaseUrl {.threadvar.}: string
  FlyMyAiAdultImageModel {.threadvar.}: string
  FlyMyAiSafeImageModel {.threadvar.}: string
  CerebrasGemma4Model {.threadvar.}: string
  PromptConfigFile {.threadvar.}: string
  ReferenceSkillRoot {.threadvar.}: string
  PublicRoot {.threadvar.}: string
  defaultTenantId {.threadvar.}: string
  serverPort: int

proc envTrim(name, fallback: string): string =
  let v = getEnv(name, "").strip()
  if v.len > 0: v else: fallback

proc stripTrailingSlash(s: string): string =
  result = s.strip()
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc nowF(): float = epochTime()

proc canonical(node: JsonNode): string =
  if node.isNil:
    return "null"
  case node.kind
  of JObject:
    var keys: seq[string] = @[]
    for k, _ in node.fields:
      keys.add(k)
    keys.sort()
    var parts: seq[string] = @[]
    for k in keys:
      parts.add(escapeJson(k) & ":" & canonical(node.fields[k]))
    result = "{" & parts.join(",") & "}"
  of JArray:
    var parts: seq[string] = @[]
    for it in node.elems:
      parts.add(canonical(it))
    result = "[" & parts.join(",") & "]"
  of JString:
    result = escapeJson(node.getStr())
  of JInt:
    result = $node.getBiggestInt()
  of JFloat:
    result = formatFloat(node.getFloat(), ffDefault, 16)
  of JBool:
    result = if node.getBool(): "true" else: "false"
  of JNull:
    result = "null"

proc sha1Hex(s: string): string =
  result = ($secureHash(s)).toLowerAscii()

var
  rngLock: Lock
  globalRng: Rand

proc newId(prefix: string): string =
  acquire(rngLock)
  defer: release(rngLock)
  const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
  var buf = newStringOfCap(24)
  for _ in 0 ..< 20:
    buf.add(alphabet[globalRng.rand(alphabet.high)])
  result = prefix & "_" & buf

type
  SqliteDb = ptr object
  SqliteStmt = ptr object

{.push importc, cdecl, dynlib: SqliteLib.}
proc sqlite3_open_v2(filename: cstring, ppDb: ptr SqliteDb, flags: cint, zVfs: cstring): cint
proc sqlite3_close_v2(db: SqliteDb): cint
proc sqlite3_exec(db: SqliteDb, sql: cstring, callback: pointer, arg: pointer, errmsg: ptr cstring): cint
proc sqlite3_prepare_v2(db: SqliteDb, zSql: cstring, nByte: cint, ppStmt: ptr SqliteStmt, pzTail: ptr cstring): cint
proc sqlite3_step(pStmt: SqliteStmt): cint
proc sqlite3_finalize(pStmt: SqliteStmt): cint
proc sqlite3_reset(pStmt: SqliteStmt): cint
proc sqlite3_bind_text(pStmt: SqliteStmt, idx: cint, value: cstring, n: cint, destructor: pointer): cint
proc sqlite3_bind_int64(pStmt: SqliteStmt, idx: cint, value: int64): cint
proc sqlite3_bind_double(pStmt: SqliteStmt, idx: cint, value: float64): cint
proc sqlite3_bind_null(pStmt: SqliteStmt, idx: cint): cint
proc sqlite3_column_count(pStmt: SqliteStmt): cint
proc sqlite3_column_text(pStmt: SqliteStmt, iCol: cint): cstring
proc sqlite3_column_int64(pStmt: SqliteStmt, iCol: cint): int64
proc sqlite3_column_double(pStmt: SqliteStmt, iCol: cint): float64
proc sqlite3_column_type(pStmt: SqliteStmt, iCol: cint): cint
proc sqlite3_column_name(pStmt: SqliteStmt, iCol: cint): cstring
proc sqlite3_errmsg(db: SqliteDb): cstring
proc sqlite3_free(p: pointer)
proc sqlite3_busy_timeout(db: SqliteDb, ms: cint): cint
proc sqlite3_last_insert_rowid(db: SqliteDb): int64
proc sqlite3_changes(db: SqliteDb): cint
{.pop.}

const
  SQLITE_OK = 0.cint
  SQLITE_ROW = 100.cint
  SQLITE_DONE = 101.cint
  SQLITE_NULL = 5.cint
  SQLITE_OPEN_READWRITE = 0x00000002.cint
  SQLITE_OPEN_CREATE = 0x00000004.cint
  SQLITE_OPEN_FULLMUTEX = 0x00010000.cint

let SQLITE_TRANSIENT = cast[pointer](-1)

type
  DbError = object of CatchableError
  Row = Table[string, JsonNode]
  Store = ref object
    handle: SqliteDb
    lock: Lock
    path: string
  SqlOperation = object
    sql: string
    params: seq[JsonNode]

var
  store {.threadvar.}: Store
  fts5Available {.threadvar.}: bool

