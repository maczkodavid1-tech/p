type
  PtyWebSocket = ref object
    socket: AsyncSocket
    url: string
    output: string
    errorText: string
    closed: bool
    readerStarted: bool
    frameWriting: bool

var ptyWebSockets = initTable[string, PtyWebSocket]()

proc hexBytes(value: string): string =
  if value.len mod 2 != 0:
    raise newException(ValueError, "hex value must have an even length")
  result = newStringOfCap(value.len div 2)
  var index = 0
  while index < value.len:
    result.add(char(parseHexInt(value[index ..< index + 2])))
    inc index, 2

proc appendByte(value: var string, number: int) =
  value.add(char(number and 0xff))

proc ptyReadExact(ws: PtyWebSocket, size: int): Future[string] {.async.} =
  if size < 0 or size > 16 * 1024 * 1024:
    raise newException(IOError, "invalid websocket frame size")
  result = newStringOfCap(size)
  while result.len < size:
    let chunk = await ws.socket.recv(min(8192, size - result.len))
    if chunk.len == 0:
      raise newException(IOError, "PTY websocket closed")
    result.add(chunk)

proc ptySendFrame(ws: PtyWebSocket, payload: string, opcode: int): Future[void] {.async.} =
  if opcode >= 8 and payload.len > 125:
    raise newException(ValueError, "websocket control frame exceeds 125 bytes")
  while ws.frameWriting and not ws.closed:
    await sleepAsync(5)
  if ws.closed:
    raise newException(IOError, "PTY websocket is closed")
  ws.frameWriting = true
  try:
    let mask = hexBytes(sha1Hex(newId("pty") & payload & $nowF())[0 .. 7])
    var frame = newStringOfCap(payload.len + 16)
    frame.appendByte(0x80 or (opcode and 0x0f))
    if payload.len < 126:
      frame.appendByte(0x80 or payload.len)
    elif payload.len <= 0xffff:
      frame.appendByte(0x80 or 126)
      frame.appendByte(payload.len shr 8)
      frame.appendByte(payload.len)
    else:
      frame.appendByte(0x80 or 127)
      var length = uint64(payload.len)
      for shift in countdown(56, 0, 8):
        frame.appendByte(int((length shr shift) and 0xff'u64))
    frame.add(mask)
    for index, ch in payload:
      frame.add(char(ord(ch) xor ord(mask[index mod 4])))
    await ws.socket.send(frame)
  finally:
    ws.frameWriting = false

proc ptyReadLoop(ws: PtyWebSocket) {.async.} =
  try:
    while not ws.closed:
      let header = await ptyReadExact(ws, 2)
      let first = ord(header[0])
      let second = ord(header[1])
      if (first and 0x70) != 0:
        raise newException(IOError, "PTY websocket has unsupported reserved bits")
      let opcode = first and 0x0f
      let finalFrame = (first and 0x80) != 0
      let masked = (second and 0x80) != 0
      if masked:
        raise newException(IOError, "PTY websocket server frame must not be masked")
      var length = second and 0x7f
      if length == 126:
        let extended = await ptyReadExact(ws, 2)
        length = (ord(extended[0]) shl 8) or ord(extended[1])
      elif length == 127:
        let extended = await ptyReadExact(ws, 8)
        var length64 = 0'u64
        for ch in extended:
          length64 = (length64 shl 8) or uint64(ord(ch))
        if length64 > uint64(16 * 1024 * 1024):
          raise newException(IOError, "PTY websocket frame exceeds size limit")
        length = int(length64)
      if opcode >= 8 and (not finalFrame or length > 125):
        raise newException(IOError, "invalid PTY websocket control frame")
      var payload = await ptyReadExact(ws, length)
      case opcode
      of 0, 1, 2:
        if ws.output.len + payload.len > 16 * 1024 * 1024:
          raise newException(IOError, "PTY websocket output exceeds size limit")
        ws.output.add(payload)
      of 8:
        try:
          await ptySendFrame(ws, payload, 8)
        except CatchableError:
          discard
        ws.closed = true
      of 9:
        await ptySendFrame(ws, payload, 10)
      else:
        discard
  except CatchableError as e:
    if not ws.closed:
      ws.errorText = e.msg
    ws.closed = true

proc ptyHandshake(ws: PtyWebSocket): Future[void] {.async.} =
  let parsed = parseUri(ws.url)
  if parsed.scheme.toLowerAscii() notin ["ws", "wss"] or parsed.hostname.len == 0:
    raise newException(ValueError, "invalid PTY websocket URL")
  let path = if parsed.path.len > 0: parsed.path else: "/"
  let target = if parsed.query.len > 0: path & "?" & parsed.query else: path
  let key = base64.encode(hexBytes(sha1Hex(newId("pty-handshake"))[0 .. 31]))
  let hostHeader = if parsed.port.len > 0: parsed.hostname & ":" & parsed.port else: parsed.hostname
  let request = "GET " & target & " HTTP/1.1\r\n" &
    "Host: " & hostHeader & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & key & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n" &
    "X-API-Key: " & requireEnv("INSTAVM_API_KEY") & "\r\n\r\n"
  await ws.socket.send(request)
  var response = ""
  while not response.endsWith("\r\n\r\n"):
    let chunk = await ws.socket.recv(1)
    if chunk.len == 0:
      raise newException(IOError, "PTY websocket handshake closed")
    response.add(chunk)
    if response.len > 65536:
      raise newException(IOError, "PTY websocket handshake exceeded size limit")
  let lines = response.split("\r\n")
  if lines.len == 0 or " 101 " notin lines[0]:
    raise newException(IOError, "PTY websocket handshake failed: " & (if lines.len > 0: lines[0] else: "empty response"))
  var acceptValue = ""
  for line in lines:
    let separator = line.find(':')
    if separator > 0 and line[0 ..< separator].toLowerAscii() == "sec-websocket-accept":
      acceptValue = line[separator + 1 .. ^1].strip()
  let expected = base64.encode(hexBytes(sha1Hex(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
  if acceptValue != expected:
    raise newException(IOError, "PTY websocket accept header mismatch")

proc openPtyWebSocket(taskId, url: string): Future[PtyWebSocket] {.async.} =
  if ptyWebSockets.hasKey(taskId):
    let existing = ptyWebSockets[taskId]
    if not existing.closed and existing.url == url:
      return existing
    if not existing.socket.isNil:
      existing.socket.close()
    ptyWebSockets.del(taskId)
  let parsed = parseUri(url)
  let ws = PtyWebSocket(socket: newAsyncSocket(buffered = false), url: url, output: "", errorText: "", closed: false, readerStarted: false, frameWriting: false)
  if parsed.scheme.toLowerAscii() == "wss":
    let context = newContext(verifyMode = CVerifyPeer)
    context.wrapSocket(ws.socket)
  let port = if parsed.port.len > 0: Port(parseInt(parsed.port)) else: Port(if parsed.scheme.toLowerAscii() == "wss": 443 else: 80)
  try:
    await ws.socket.connect(parsed.hostname, port)
    await ws.ptyHandshake()
    ptyWebSockets[taskId] = ws
    ws.readerStarted = true
    asyncCheck ptyReadLoop(ws)
    return ws
  except CatchableError:
    ws.socket.close()
    raise

proc closePtyWebSocket(taskId: string) =
  if not ptyWebSockets.hasKey(taskId):
    return
  let ws = ptyWebSockets[taskId]
  ws.closed = true
  if not ws.socket.isNil:
    ws.socket.close()
  ptyWebSockets.del(taskId)

proc registerTools() =
  registerTool("spawn_subagent", "Create and immediately launch a persistent autonomous child agent using any configured model, with the child model and goal explicitly chosen by the caller model. Give every child agent the complete tool registry and allow it to recursively create its own children.", %*{"model": "string", "goal": "string", "name": "string optional", "instructions": "string optional", "context": "object optional", "wait": "bool optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await spawnSubAgentTool(h, args))
  registerTool("wait_subagents", "Wait for the child agents specified by ID, or all direct children of the current actor if no IDs are supplied, to reach a terminal state. Return their actual terminal results.", %*{"agent_ids": "string[] optional", "scope": "direct_children|descendants|task optional", "timeout_ms": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await waitSubAgentsTool(h, args))
  registerTool("list_subagents", "Return the persistent subagent tree for the current task, including model, parent, goal, status and terminal result.", %*{"scope": "direct_children|descendants|task optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await listSubAgentsTool(h, args))
  registerTool("get_subagent", "Return the current persisted state and result of one subagent.", %*{"agent_id": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await getSubAgentTool(h, args))
  registerTool("message_subagent", "Send new instructions or evidence to a running subagent by appending the message to its persistent context without resetting its work.", %*{"agent_id": "string", "message": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await messageSubAgentTool(h, args))
  registerTool("stop_subagent", "Request a subagent to stop after its current awaited operation and preserve its state.", %*{"agent_id": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await stopSubAgentTool(h, args))
  registerTool("get_plan", "Return the complete current dynamic PlanSteps graph, including dependencies, statuses, completion criteria and progress. Every model and subagent may inspect the shared root plan before deciding its next action.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      acquire(h.lock)
      let plan = copy(h.sigma{"plan"})
      let checklist = copy(h.sigma{"completion_checklist"})
      let progress = h.sigma{"progress"}.getFloat(0.0)
      release(h.lock)
      let payload = %*{"plan": plan, "completion_checklist": checklist, "progress": progress}
      return ToolResult(ok: true, payload: payload, receipt: "plan:" & sha1Hex(canonical(payload)), message: "current plan returned"))
  registerTool("replace_remaining_plan", "Replace the unfinished portion of the shared dynamic PlanSteps graph with a new model-selected dependency graph. Completed steps are preserved. Every replacement step must explicitly provide id, goal, model, execution_mode and depends_on. The backend validates graph consistency but never chooses the strategy or model.", %*{"steps": "array"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let steps = args{"steps"}
      if steps.kind != JArray or steps.elems.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "steps must be a non-empty array")
      try:
        h.replaceRemainingPlan(steps)
        acquire(h.lock)
        let plan = copy(h.sigma{"plan"})
        release(h.lock)
        h.emit(%*{"type": "plan_mutated", "plan": plan})
        return ToolResult(ok: true, payload: %*{"plan": plan}, receipt: "plan:" & sha1Hex(canonical(plan)), message: "remaining plan replaced")
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"error": e.msg}, receipt: "", message: e.msg))
  registerTool("vm_python_exec", "Execute real Python code in the task's persistent InstaVM.", %*{"code": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.instavmExecute(args{"code"}.getStr(""), "python"))
  registerTool("vm_bash_exec", "Execute a real Bash command in the task's persistent InstaVM.", %*{"command": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.instavmExecute(args{"command"}.getStr(""), "bash"))
  registerTool("vm_read_file", "Read a real file from the InstaVM using the persistent task environment.", %*{"path": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      return await h.instavmExecute("python3 - <<'PY'\nfrom pathlib import Path\np=Path(" & escapeJson(path) & ")\nprint(p.read_text(errors='replace'))\nPY", "bash"))
  registerTool("vm_write_file", "Write complete text content to a real file in the InstaVM.", %*{"path": "string", "content": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      let content = args{"content"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let encoded = base64.encode(content)
      let code = "import base64, pathlib\np=pathlib.Path(" & escapeJson(path) & ")\np.parent.mkdir(parents=True,exist_ok=True)\np.write_bytes(base64.b64decode(" & escapeJson(encoded) & "))\nprint(str(p))"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_append_file", "Append complete text content to a real file in the persistent InstaVM.", %*{"path": "string", "content": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      let content = args{"content"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let encoded = base64.encode(content)
      let code = "import base64,pathlib\np=pathlib.Path(" & escapeJson(path) & ")\np.parent.mkdir(parents=True,exist_ok=True)\nwith p.open('ab') as f:f.write(base64.b64decode(" & escapeJson(encoded) & "))\nprint(str(p))"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_replace_text", "Replace exact text in a real file in the persistent InstaVM and report the replacement count.", %*{"path": "string", "old": "string", "new": "string", "count": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      let oldText = args{"old"}.getStr("")
      let newText = args{"new"}.getStr("")
      let count = args{"count"}.getInt(-1)
      if path.len == 0 or oldText.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path and old required")
      let old64 = base64.encode(oldText)
      let new64 = base64.encode(newText)
      let code = "import base64,pathlib\np=pathlib.Path(" & escapeJson(path) & ")\ns=p.read_text(errors='replace')\na=base64.b64decode(" & escapeJson(old64) & ").decode()\nb=base64.b64decode(" & escapeJson(new64) & ").decode()\nn=" & $count & "\nc=s.count(a) if n<0 else min(s.count(a),n)\ns=s.replace(a,b,n) if n>=0 else s.replace(a,b)\np.write_text(s)\nprint(c)"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_delete_file", "Delete a real file or directory from the persistent InstaVM.", %*{"path": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let code = "import pathlib,shutil\np=pathlib.Path(" & escapeJson(path) & ")\nexists=p.exists() or p.is_symlink()\n(shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()) if exists else None\nprint('deleted' if exists else 'absent')"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_search_files", "Search real files recursively in the persistent InstaVM for exact text and return matching paths and line numbers.", %*{"path": "string optional", "query": "string", "case_sensitive": "bool optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let root = args{"path"}.getStr("/app")
      let query = args{"query"}.getStr("")
      if query.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "query required")
      let q64 = base64.encode(query)
      let sensitive = if args{"case_sensitive"}.getBool(false): "True" else: "False"
      let code = "import base64,json,pathlib\nroot=pathlib.Path(" & escapeJson(root) & ")\nq=base64.b64decode(" & escapeJson(q64) & ").decode(errors='replace')\ncase=" & sensitive & "\nh=[]\nfor p in root.rglob('*'):\n if not p.is_file():continue\n try:s=p.read_text(errors='replace')\n except Exception:continue\n n=q if case else q.lower(); t=s if case else s.lower()\n if n in t:\n  for i,line in enumerate(s.splitlines(),1):\n   if n in (line if case else line.lower()):h.append({'path':str(p),'line':i,'text':line})\nprint(json.dumps({'matches':h},ensure_ascii=False))"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_check_file", "Verify real file existence and required text fragments in the persistent InstaVM.", %*{"path": "string", "contains": "string[] optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let required = if args.hasKey("contains") and args["contains"].kind == JArray: args["contains"] else: newJArray()
      let encoded = base64.encode($required)
      let code = "import base64,json,pathlib\np=pathlib.Path(" & escapeJson(path) & ")\nreq=json.loads(base64.b64decode(" & escapeJson(encoded) & ").decode())\nexists=p.exists()\ns=p.read_text(errors='replace') if exists and p.is_file() else ''\nchecks=[{'text':x,'present':x in s} for x in req]\nprint(json.dumps({'exists':exists,'checks':checks,'ok':exists and all(x['present'] for x in checks)},ensure_ascii=False))"
      let res = await h.instavmExecute(code, "python")
      if not res.ok:
        return res
      let output = res.payload{"output"}.getStr(res.payload{"stdout"}.getStr("")).strip()
      try:
        let parsed = parseJson(output)
        return ToolResult(ok: parsed{"ok"}.getBool(false), payload: parsed, receipt: "check:" & sha1Hex(path & output), message: (if parsed{"ok"}.getBool(false): "verified" else: "verification failed"))
      except CatchableError:
        return ToolResult(ok: false, payload: res.payload, receipt: res.receipt, message: "verification output was not valid JSON"))
  registerTool("vm_document_extract", "Extract complete readable content from a real document inside the persistent InstaVM, including OCR-visible PDF content and readable package parts.", %*{"path": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("")
      if path.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let code = """import io, json, pathlib, subprocess, sys, zipfile, xml.etree.ElementTree as ET, shutil
p=pathlib.Path(""" & escapeJson(path) & """)
if not p.exists():
    raise FileNotFoundError(str(p))
ext=p.suffix.lower()
def ensure(module, package):
    try:
        return __import__(module)
    except ImportError:
        subprocess.check_call([sys.executable,'-m','pip','install','-q',package])
        return __import__(module)
def paragraphs(blob):
    root=ET.fromstring(blob)
    out=[]
    for node in root.iter():
        if node.tag.endswith('}p'):
            text=''.join(node.itertext()).strip()
            if text:
                out.append(text)
    return '\n'.join(out)
def package_parts(z, names):
    out=[]
    for name in names:
        if name in z.namelist():
            text=paragraphs(z.read(name))
            if text:
                out.append('=== %s ===\n%s' % (name,text))
    return out
if ext=='.pdf':
    fitz=ensure('fitz','PyMuPDF')
    pytesseract=ensure('pytesseract','pytesseract')
    Image=ensure('PIL.Image','Pillow')
    if shutil.which('tesseract') is None:
        subprocess.check_call(['sudo','apt-get','update','-qq'])
        subprocess.check_call(['sudo','apt-get','install','-y','-qq','tesseract-ocr'])
    doc=fitz.open(str(p))
    pages=[]
    for i,page in enumerate(doc,1):
        native=page.get_text('text').strip()
        pix=page.get_pixmap(matrix=fitz.Matrix(2.0,2.0),alpha=False)
        image=Image.open(io.BytesIO(pix.tobytes('png')))
        ocr=pytesseract.image_to_string(image).strip()
        chunks=[]
        if native:
            chunks.append(native)
        if ocr and ocr not in native:
            chunks.append(ocr)
        pages.append('=== PAGE %d ===\n%s' % (i,'\n'.join(chunks)))
    text='\n\n'.join(pages)
elif ext=='.docx':
    with zipfile.ZipFile(p) as z:
        names=['word/document.xml']
        names += sorted(n for n in z.namelist() if n.startswith('word/header') and n.endswith('.xml'))
        names += sorted(n for n in z.namelist() if n.startswith('word/footer') and n.endswith('.xml'))
        names += [n for n in ['word/footnotes.xml','word/endnotes.xml','word/comments.xml'] if n in z.namelist()]
        text='\n\n'.join(package_parts(z,names))
elif ext=='.pptx':
    pptx=ensure('pptx','python-pptx')
    presentation=pptx.Presentation(str(p))
    slides=[]
    for i,slide in enumerate(presentation.slides,1):
        chunks=[]
        for shape in slide.shapes:
            if hasattr(shape,'text') and shape.text.strip():
                chunks.append(shape.text.strip())
        try:
            notes=slide.notes_slide
            for shape in notes.shapes:
                if hasattr(shape,'text') and shape.text.strip():
                    t=shape.text.strip()
                    if t not in chunks:
                        chunks.append(t)
        except Exception:
            pass
        slides.append('=== SLIDE %d ===\n%s' % (i,'\n'.join(chunks)))
    with zipfile.ZipFile(p) as z:
        note_parts=sorted(n for n in z.namelist() if n.startswith('ppt/notesSlides/notesSlide') and n.endswith('.xml'))
        notes=package_parts(z,note_parts)
    text='\n\n'.join(slides+notes)
elif ext in ('.xlsx','.xlsm','.xltx','.xltm'):
    openpyxl=ensure('openpyxl','openpyxl')
    wb=openpyxl.load_workbook(str(p),data_only=True,read_only=True)
    sheets=[]
    for ws in wb.worksheets:
        rows=[]
        for row in ws.iter_rows(values_only=True):
            rows.append('\t'.join('' if v is None else str(v) for v in row))
        sheets.append('=== SHEET %s ===\n%s' % (ws.title,'\n'.join(rows)))
    text='\n\n'.join(sheets)
elif ext=='.rtf':
    striprtf=ensure('striprtf','striprtf')
    text=striprtf.rtf_to_text(p.read_text(errors='replace'))
else:
    text=p.read_text(errors='replace')
print(json.dumps({'path':str(p),'extension':ext,'text':text},ensure_ascii=False))"""
      let res = await h.instavmExecute(code, "python")
      if not res.ok:
        return res
      let output = res.payload{"output"}.getStr(res.payload{"stdout"}.getStr("")).strip()
      try:
        let payload = parseJson(output)
        return ToolResult(ok: true, payload: payload, receipt: "document:" & sha1Hex(path & output), message: "document extracted")
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"path": path, "raw_output": output}, receipt: "", message: "document extractor returned invalid JSON: " & e.msg))
  registerTool("vm_list_files", "List real files recursively in an InstaVM directory.", %*{"path": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let path = args{"path"}.getStr("/app")
      return await h.instavmExecute("find " & shellQuote(path) & " -printf '%y %p %s\\n'", "bash"))
  registerTool("vm_upload_file", "Upload a file from the authenticated task tenant workspace into the task's InstaVM.", %*{"local_path": "string", "remote_path": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let localRel = args{"local_path"}.getStr("")
      let remotePath = args{"remote_path"}.getStr("")
      if localRel.len == 0 or remotePath.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "local_path and remote_path required")
      var localPath: string
      try:
        localPath = safeJoin(h.tenantId, localRel)
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"local_path": localRel}, receipt: "", message: e.msg)
      if not fileExists(localPath):
        return ToolResult(ok: false, payload: %*{"local_path": localRel}, receipt: "", message: "local file not found")
      let maxBytes = positiveEnvInt("VM_TRANSFER_MAX_BYTES", 67_108_864)
      let fileBytes = getFileSize(localPath)
      if fileBytes < 0 or fileBytes > maxBytes:
        return ToolResult(ok: false, payload: %*{"size": fileBytes, "max_bytes": maxBytes}, receipt: "", message: "local file exceeds transfer limit")
      let encoded = base64.encode(readFile(localPath))
      let code = "import base64, pathlib\np=pathlib.Path(" & escapeJson(remotePath) & ")\np.parent.mkdir(parents=True,exist_ok=True)\np.write_bytes(base64.b64decode(" & escapeJson(encoded) & "))\nprint(str(p))"
      return await h.instavmExecute(code, "python"))
  registerTool("vm_download_file", "Download a bounded real InstaVM file into the backend artifact directory.", %*{"remote_path": "string", "name": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let remotePath = args{"remote_path"}.getStr("")
      if remotePath.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "remote_path required")
      let maxBytes = positiveEnvInt("VM_TRANSFER_MAX_BYTES", 67_108_864)
      let checkCode = "import json,pathlib\np=pathlib.Path(" & escapeJson(remotePath) & ")\nprint(json.dumps({'exists':p.is_file(),'size':p.stat().st_size if p.is_file() else -1}))"
      let checkRes = await h.instavmExecute(checkCode, "python")
      if not checkRes.ok:
        return checkRes
      let checkOut = checkRes.payload{"output"}.getStr(checkRes.payload{"stdout"}.getStr("")).strip()
      var meta: JsonNode
      try:
        meta = parseJson(checkOut)
      except CatchableError:
        return ToolResult(ok: false, payload: checkRes.payload, receipt: "", message: "could not inspect remote file")
      let remoteSize = meta{"size"}.getInt(-1)
      if not meta{"exists"}.getBool(false) or remoteSize < 0:
        return ToolResult(ok: false, payload: meta, receipt: "", message: "remote file not found")
      if remoteSize > maxBytes:
        return ToolResult(ok: false, payload: %*{"size": remoteSize, "max_bytes": maxBytes}, receipt: "", message: "remote file exceeds transfer limit")
      let code = "import base64, pathlib\np=pathlib.Path(" & escapeJson(remotePath) & ")\nprint(base64.b64encode(p.read_bytes()).decode('ascii'))"
      let res = await h.instavmExecute(code, "python")
      if not res.ok:
        return res
      let encoded = res.payload{"output"}.getStr(res.payload{"stdout"}.getStr("")).strip()
      if encoded.len > ((maxBytes + 2) div 3) * 4 + 16:
        return ToolResult(ok: false, payload: %*{"encoded_size": encoded.len}, receipt: "", message: "encoded remote file exceeds transfer limit")
      var decoded: string
      try:
        decoded = base64.decode(encoded)
      except CatchableError as e:
        return ToolResult(ok: false, payload: res.payload, receipt: res.receipt, message: "invalid downloaded base64: " & e.msg)
      if decoded.len > maxBytes:
        return ToolResult(ok: false, payload: %*{"size": decoded.len}, receipt: "", message: "decoded remote file exceeds transfer limit")
      let requestedName = args{"name"}.getStr(extractFilename(remotePath))
      if requestedName.len == 0 or extractFilename(requestedName) != requestedName or requestedName.contains("..") or requestedName.contains('/') or requestedName.contains('\\') or requestedName.contains('\0'):
        return ToolResult(ok: false, payload: %*{"name": requestedName}, receipt: "", message: "invalid artifact name")
      let taskDir = absolutePath(WorkspaceRoot / "artifacts" / h.taskId)
      createDir(taskDir)
      let localPath = absolutePath(taskDir / requestedName)
      if not (localPath == taskDir or localPath.startsWith(taskDir & DirSep)):
        return ToolResult(ok: false, payload: %*{"name": requestedName}, receipt: "", message: "artifact path escapes task directory")
      writeFile(localPath, decoded)
      let mime = newMimetypes().getMimetype(splitFile(requestedName).ext)
      let artifactId = h.addArtifact(requestedName, localPath, "file", (if mime.len > 0: mime else: "application/octet-stream"))
      return ToolResult(ok: true, payload: %*{"artifact_id": artifactId, "path": localPath, "name": requestedName, "download_url": "/api/artifacts/" & artifactId}, receipt: "download:" & artifactId, message: "downloaded"))
  registerTool("vm_browser_create", "Create or return the persistent browser session for this task.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let bid = await h.browserSession()
      return ToolResult(ok: true, payload: %*{"browser_session_id": bid}, receipt: "browser:" & bid, message: "browser ready"))
  registerTool("vm_browser_navigate", "Navigate the persistent InstaVM browser.", %*{"url": "string", "wait_timeout": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("navigate", args))
  registerTool("vm_browser_click", "Click a selector in the persistent InstaVM browser.", %*{"selector": "string", "force": "bool optional", "timeout": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("click", args))
  registerTool("vm_browser_type", "Type text into a selector in the persistent InstaVM browser.", %*{"selector": "string", "text": "string", "delay": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("type", args))
  registerTool("vm_browser_fill", "Fill a selector in the persistent InstaVM browser.", %*{"selector": "string", "value": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("fill", args))
  registerTool("vm_browser_scroll", "Scroll the persistent InstaVM browser.", %*{"x": "int optional", "y": "int optional", "selector": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("scroll", args))
  registerTool("vm_browser_wait", "Wait for browser load or selector visibility.", %*{"state": "string", "selector": "string optional", "timeout": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("wait", args))
  registerTool("vm_browser_screenshot", "Capture a real screenshot from the persistent InstaVM browser.", %*{"full_page": "bool optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("screenshot", args))
  registerTool("vm_browser_content", "Read the current browser page content.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("content", args))
  registerTool("vm_browser_extract", "Extract elements from the current browser page.", %*{"selector": "string", "attributes": "string[] optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.browserAction("extract", args))
  registerTool("vm_desktop_state", "Read the real InstaVM desktop state.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/state", HttpGet))
  registerTool("vm_desktop_screenshot", "Capture the real InstaVM desktop screenshot.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/screenshot", HttpGet))
  registerTool("vm_desktop_click", "Click the real InstaVM desktop.", %*{"x": "int", "y": "int", "button": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/mouse/click", HttpPost, args))
  registerTool("vm_desktop_type", "Type text in the real InstaVM desktop.", %*{"text": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/keyboard/type", HttpPost, args))
  registerTool("vm_desktop_key", "Send a keyboard key action to the real InstaVM desktop.", %*{"key": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/keyboard/key", HttpPost, args))
  registerTool("vm_desktop_scroll", "Scroll the real InstaVM desktop.", %*{"x": "int optional", "y": "int optional", "delta_x": "int optional", "delta_y": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await h.desktopProxy("/mouse/scroll", HttpPost, args))
  registerTool("vm_pty_create", "Create a persistent InstaVM PTY.", %*{"cols": "int optional", "rows": "int optional", "command": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let sid = await h.createInstaVmSession()
      var body = copy(args)
      if body.kind != JObject: body = newJObject()
      body["cols"] = %(body{"cols"}.getInt(120))
      body["rows"] = %(body{"rows"}.getInt(40))
      let res = await h.instavmJson("/v1/sessions/" & encodeUrl(sid) & "/pty/sessions", HttpPost, body)
      if res.ok:
        let ptyId = res.payload{"session_id"}.getStr(res.payload{"pty_id"}.getStr(res.payload{"id"}.getStr("")))
        if ptyId.len > 0:
          h.saveRuntimeField("pty_id", ptyId)
        let wsUrl = res.payload{"ws_url"}.getStr(res.payload{"websocket_url"}.getStr(""))
        if wsUrl.len > 0:
          h.saveRuntimeField("pty_ws_url", wsUrl)
      return res)
  registerTool("vm_pty_write", "Write stdin to the persistent InstaVM PTY and return the resulting terminal output.", %*{"input": "string", "read_seconds": "float optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rt = h.runtimeNode()
      let sid = rt{"instavm_session_id"}.getStr("")
      let ptyId = rt{"pty_id"}.getStr("")
      if sid.len == 0 or ptyId.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "PTY not created")
      var wsUrl = rt{"pty_ws_url"}.getStr("")
      if wsUrl.len == 0:
        let info = await h.instavmJson("/v1/sessions/" & encodeUrl(sid) & "/pty/sessions/" & encodeUrl(ptyId), HttpGet)
        if info.ok:
          wsUrl = info.payload{"ws_url"}.getStr(info.payload{"websocket_url"}.getStr(""))
          if wsUrl.len > 0:
            h.saveRuntimeField("pty_ws_url", wsUrl)
      if wsUrl.len == 0:
        return ToolResult(ok: false, payload: %*{"session_id": sid, "pty_id": ptyId}, receipt: "", message: "PTY websocket URL is not present in the PTY session response")
      let stdinText = args{"input"}.getStr("")
      let readSeconds = max(0.05, args{"read_seconds"}.getFloat(0.35))
      var ws: PtyWebSocket
      try:
        ws = await openPtyWebSocket(h.taskId, wsUrl)
        if ws.closed:
          return ToolResult(ok: false, payload: %*{"session_id": sid, "pty_id": ptyId}, receipt: "pty:error", message: ws.errorText)
        let previousOutput = ws.output
        ws.output.setLen(0)
        if stdinText.len > 0:
          await ptySendFrame(ws, stdinText, 2)
        let deadline = epochTime() + readSeconds
        while epochTime() < deadline and not ws.closed:
          await sleepAsync(10)
        if ws.errorText.len > 0 and ws.output.len == 0:
          return ToolResult(ok: false, payload: %*{"session_id": sid, "pty_id": ptyId, "output": previousOutput}, receipt: "pty:error", message: ws.errorText)
        return ToolResult(ok: true, payload: %*{"session_id": sid, "pty_id": ptyId, "output": ws.output}, receipt: "pty:" & sha1Hex(stdinText & ws.output), message: "PTY input written")
      except CatchableError as e:
        if not ws.isNil and not ws.socket.isNil:
          ws.closed = true
          ws.socket.close()
        if ptyWebSockets.hasKey(h.taskId):
          ptyWebSockets.del(h.taskId)
        return ToolResult(ok: false, payload: %*{"session_id": sid, "pty_id": ptyId}, receipt: "pty:error", message: e.msg))
  registerTool("vm_pty_resize", "Resize the persistent InstaVM PTY.", %*{"cols": "int", "rows": "int"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rt = h.runtimeNode()
      let sid = rt{"instavm_session_id"}.getStr("")
      let ptyId = rt{"pty_id"}.getStr("")
      if sid.len == 0 or ptyId.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "PTY not created")
      return await h.instavmJson("/v1/sessions/" & encodeUrl(sid) & "/pty/sessions/" & encodeUrl(ptyId) & "/resize", HttpPost, args))
  registerTool("vm_pty_close", "Close the persistent InstaVM PTY.", %*{},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rt = h.runtimeNode()
      let sid = rt{"instavm_session_id"}.getStr("")
      let ptyId = rt{"pty_id"}.getStr("")
      if sid.len == 0 or ptyId.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "PTY not created")
      let res = await h.instavmJson("/v1/sessions/" & encodeUrl(sid) & "/pty/sessions/" & encodeUrl(ptyId), HttpDelete)
      if res.ok:
        closePtyWebSocket(h.taskId)
        h.saveRuntimeField("pty_id", "")
        h.saveRuntimeField("pty_ws_url", "")
      return res)
  registerTool("memory_search", "Search persisted operational knowledge and skills using hybrid semantic, lexical and learned-policy ranking.", %*{"query": "string", "limit": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let q = args{"query"}.getStr("").strip()
      let limit = max(1, args{"limit"}.getInt(8))
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      var skills = newJArray()
      for r in await searchSkills(tenant, q, limit):
        skills.add(%*{"skill_id": r.getStr("skill_id"), "name": r.getStr("name"), "domain": r.getStr("domain"), "trigger": r.getStr("trigger_spec"), "procedure": r.getStr("procedure_spec"), "skill_code": r.getStr("skill_code"), "reward": r.getFloat("reward")})
      var docs = newJArray()
      for r in await searchKnowledge(tenant, q, limit):
        docs.add(%*{"doc_id": r.getStr("doc_id"), "slug": r.getStr("slug"), "category": r.getStr("category"), "content": r.getStr("content")})
      let policy = learnedPolicySignals(tenant, q, limit)
      return ToolResult(ok: true, payload: %*{"skills": skills, "knowledge": docs, "policy_signals": policy}, receipt: "memory:" & sha1Hex(tenant & ":" & q), message: "retrieved"))
  registerTool("memory_write", "Persist operational knowledge in the current tenant's injective knowledge repository.", %*{"slug": "string", "category": "string optional", "body": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let slug = args{"slug"}.getStr("").strip()
      let body = args{"body"}.getStr("")
      if slug.len == 0 or body.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "slug and body required")
      let category = args{"category"}.getStr("operational")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      try:
        let docId = await commitKnowledgeDoc(tenant, slug, category, body)
        let rows = store.query("SELECT path FROM knowledge_docs WHERE doc_id=? AND tenant_id=?", @[%docId, %tenant])
        let path = if rows.len > 0: rows[0].getStr("path") else: ""
        return ToolResult(ok: true, payload: %*{"doc_id": docId, "slug": slug, "path": path}, receipt: "knowledge:" & docId, message: "persisted")
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"slug": slug}, receipt: "", message: e.msg))
proc registerLegacyTools() =
  registerTool("write_file", "Atomically write content to a backend workspace file.", %*{"path": "string", "content": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      let content = args{"content"}.getStr("")
      if rel.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      atomicWrite(full, content)
      return ToolResult(ok: true, payload: %*{"path": rel, "bytes_written": content.len, "sha1": sha1Hex(content)}, receipt: "write:" & rel & ":" & sha1Hex(content), message: "wrote " & $content.len & " bytes"))

  registerTool("read_file", "Read a backend workspace file.", %*{"path": "string", "start_line": "int optional", "end_line": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      if rel.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      if not fileExists(full):
        return ToolResult(ok: false, payload: %*{"path": rel}, receipt: "", message: "file not found")
      let lines = readLinesOf(full)
      let startLine = max(1, args{"start_line"}.getInt(1))
      let requestedEnd = args{"end_line"}.getInt(0)
      let endLine = if requestedEnd > 0: min(requestedEnd, lines.len) else: lines.len
      let startIndex = min(lines.len, startLine - 1)
      let content = if startIndex < endLine: lines[startIndex ..< endLine].join("\n") else: ""
      return ToolResult(ok: true, payload: %*{"path": rel, "content": content, "total_lines": lines.len, "bytes_read": content.len, "sha1": sha1Hex(content)}, receipt: "read:" & rel & ":" & $lines.len, message: "read " & $content.len & " bytes"))

  registerTool("append_file", "Atomically append text to a backend workspace file.", %*{"path": "string", "lines": "string[]", "content": "string optional", "unique": "bool optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      if rel.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      var incoming: seq[string] = @[]
      if args.hasKey("lines") and args["lines"].kind == JArray:
        for item in args["lines"].elems:
          incoming.add(item.getStr(""))
      elif args{"content"}.getStr("").len > 0:
        incoming = args{"content"}.getStr("").splitLines()
      if incoming.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "lines or content required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      var existing = readLinesOf(full)
      let unique = args{"unique"}.getBool(true)
      var seen = initHashSet[string]()
      if unique:
        for line in existing:
          seen.incl(line)
      var added = 0
      var skipped = 0
      for line in incoming:
        if unique and line in seen:
          inc skipped
        else:
          existing.add(line)
          seen.incl(line)
          inc added
      let finalContent = existing.join("\n") & (if existing.len > 0: "\n" else: "")
      atomicWrite(full, finalContent)
      return ToolResult(ok: true, payload: %*{"path": rel, "added_count": added, "skipped_count": skipped, "total_lines": existing.len, "sha1": sha1Hex(finalContent)}, receipt: "append:" & rel & ":" & $added, message: "appended " & $added & " lines"))

  registerTool("replace_lines", "Replace a 1-based inclusive line range in a backend workspace file.", %*{"path": "string", "start_line": "int", "end_line": "int", "lines": "string[]", "content": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      let startLine = args{"start_line"}.getInt(0)
      let endLine = args{"end_line"}.getInt(0)
      if rel.len == 0 or startLine < 1 or endLine < startLine - 1:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "invalid path or line range")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      var lines = readLinesOf(full)
      if startLine > lines.len + 1:
        return ToolResult(ok: false, payload: %*{"path": rel}, receipt: "", message: "start_line beyond EOF")
      var replacements: seq[string] = @[]
      if args.hasKey("lines") and args["lines"].kind == JArray:
        for item in args["lines"].elems:
          replacements.add(item.getStr(""))
      elif args{"content"}.getStr("").len > 0:
        replacements = args{"content"}.getStr("").splitLines()
      let first = startLine - 1
      let after = min(endLine, lines.len)
      var nextLines: seq[string] = @[]
      for i in 0 ..< first:
        nextLines.add(lines[i])
      for line in replacements:
        nextLines.add(line)
      for i in after ..< lines.len:
        nextLines.add(lines[i])
      let finalContent = nextLines.join("\n") & (if nextLines.len > 0: "\n" else: "")
      atomicWrite(full, finalContent)
      return ToolResult(ok: true, payload: %*{"path": rel, "removed_count": max(0, after - first), "inserted_count": replacements.len, "total_lines": nextLines.len, "sha1": sha1Hex(finalContent)}, receipt: "replace:" & rel & ":" & $startLine & "-" & $endLine, message: "replaced requested line range"))

  registerTool("check_lines", "Check exact line presence in a backend workspace file.", %*{"path": "string", "lines": "string[]"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      if rel.len == 0 or not args.hasKey("lines") or args["lines"].kind != JArray:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path and lines are required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      let lines = readLinesOf(full)
      var firstLine = initTable[string, int]()
      for i, line in lines:
        if not firstLine.hasKey(line):
          firstLine[line] = i + 1
      var results = newJArray()
      var missing = 0
      for probe in args["lines"].elems:
        let text = probe.getStr("")
        let present = firstLine.hasKey(text)
        if not present:
          inc missing
        results.add(%*{"line": text, "present": present, "line_number": (if present: firstLine[text] else: 0)})
      return ToolResult(ok: true, payload: %*{"path": rel, "results": results, "missing_count": missing}, receipt: "check:" & rel & ":" & $results.len, message: $(results.len - missing) & "/" & $results.len & " lines present"))

  registerTool("search_files", "Search backend workspace files recursively for a substring.", %*{"pattern": "string", "path": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let pattern = args{"pattern"}.getStr("")
      if pattern.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "pattern required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let base = safeJoin(tenant, ".")
      let root = safeJoin(tenant, args{"path"}.getStr("."))
      if not dirExists(root):
        return ToolResult(ok: false, payload: %*{"path": args{"path"}.getStr(".")}, receipt: "", message: "directory not found")
      let needle = pattern.toLowerAscii()
      var hits = newJArray()
      var scanned = 0
      for path in walkDirRec(root):
        if not fileExists(path):
          continue
        inc scanned
        try:
          let content = readFile(path)
          var lineNo = 0
          for line in content.splitLines():
            inc lineNo
            if needle in line.toLowerAscii():
              hits.add(%*{"path": relativePath(path, base).replace('\\', '/'), "line": lineNo, "text": line})
        except CatchableError:
          discard
      return ToolResult(ok: true, payload: %*{"pattern": pattern, "hits": hits, "scanned_files": scanned}, receipt: "search:" & sha1Hex(pattern & ":" & $scanned), message: "found " & $hits.len & " matches"))

  registerTool("list_dir", "List entries in a backend workspace directory.", %*{"path": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let rel = args{"path"}.getStr(".")
      let target = safeJoin(tenant, rel)
      if not dirExists(target):
        return ToolResult(ok: false, payload: %*{"path": rel}, receipt: "", message: "directory not found")
      var entries = newJArray()
      for kind, path in walkDir(target):
        let name = extractFilename(path)
        var size = 0'i64
        if kind == pcFile:
          try:
            size = getFileSize(path)
          except CatchableError:
            size = 0
        entries.add(%*{"name": name, "type": (if kind in {pcDir, pcLinkToDir}: "dir" else: "file"), "bytes": size})
      return ToolResult(ok: true, payload: %*{"path": rel, "entries": entries}, receipt: "list:" & rel, message: "listed " & $entries.len & " entries"))

  registerTool("delete_file", "Delete a backend workspace file.", %*{"path": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let rel = args{"path"}.getStr("")
      if rel.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "path required")
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      let full = safeJoin(tenant, rel)
      if not fileExists(full):
        return ToolResult(ok: false, payload: %*{"path": rel}, receipt: "", message: "file not found")
      removeFile(full)
      return ToolResult(ok: true, payload: %*{"path": rel, "deleted": true}, receipt: "delete:" & rel, message: "deleted"))

  registerTool("math_eval", "Evaluate a mathematical expression with the deterministic recursive-descent parser.", %*{"expression": "string"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let expression = args{"expression"}.getStr("")
      if expression.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "expression required")
      let evaluated = evalMathExpression(expression)
      if not evaluated[0]:
        return ToolResult(ok: false, payload: %*{"expression": expression}, receipt: "", message: evaluated[2])
      return ToolResult(ok: true, payload: %*{"expression": expression, "value": evaluated[1]}, receipt: "math:" & sha1Hex(expression), message: "= " & formatFloat(evaluated[1], ffDefault, 16)))

  registerTool("http_fetch", "Perform a real outbound HTTP request and return the response.", %*{"url": "string", "method": "string optional", "headers": "object optional", "body": "string optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let url = args{"url"}.getStr("")
      if url.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "url required")
      let parsed = validateOutboundUrl(url)
      discard parsed
      let httpMethodValue = mapHttpMethod(args{"method"}.getStr("GET"))
      let requestBody = args{"body"}.getStr("")
      var headers = newHttpHeaders()
      if args.hasKey("headers") and args["headers"].kind == JObject:
        for key, value in args["headers"].fields:
          headers[key] = value.getStr("")
      try:
        let response = await httpRequestAsync(url, httpMethodValue, requestBody, headers)
        let body = response[1]
        return ToolResult(ok: response[0] < 400, payload: %*{"url": url, "status": response[0], "headers": responseHeadersJson(response[2]), "body": body}, receipt: "http:" & sha1Hex(url & ":" & $response[0] & ":" & body), message: "status " & $response[0])
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"url": url}, receipt: "", message: e.msg))

proc registerImageTools()

proc initTools() =
  registerTools()
  registerLegacyTools()
  registerImageTools()

proc registerReasonTool() =
  registerTool("reason", "Run a recursive specialist reasoning pass and return its structured result.", %*{"goal": "string", "context": "string optional", "depth": "int optional", "max_depth": "int optional", "branches": "int optional"},
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      let goal = args{"goal"}.getStr(h.sigma{"goal"}.getStr(h.title))
      if goal.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "goal required")
      let context = args{"context"}.getStr(canonical(h.obs))
      let depth = max(0, args{"depth"}.getInt(0))
      let maxDepth = max(depth + 1, args{"max_depth"}.getInt(depth + 1))
      let branches = max(1, args{"branches"}.getInt(1))
      let tenant = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
      try:
        let resultNode = await recursiveReasonCall(tenant, h.taskId, goal, context, depth, maxDepth, branches)
        return ToolResult(ok: true, payload: resultNode, receipt: "reason:" & sha1Hex(goal & ":" & canonical(resultNode)), message: "reasoning completed")
      except CatchableError as e:
        return ToolResult(ok: false, payload: %*{"goal": goal}, receipt: "", message: e.msg))

proc registerImageTools() =
  registerTool("image_generate", "Generate real raster images through FlyMyAI and persist them as task artifacts. Safe requests are directed by gemini38 to the GPT Image model and adult requests are directed by grok43 to the Seedream model. Supply prompt or an images array containing request objects. Each generated file is persisted and returned with its image identifier, artifact identifier, path, URL, byte count and checksum.", %*{
    "prompt": "string optional",
    "adult": "bool optional",
    "policy": "safe|adult optional",
    "size": "string optional",
    "quality": "auto|low|medium|high|xhigh|max optional",
    "moderation": "auto|low optional",
    "watermark": "bool optional",
    "sequential_image_generation": "auto|disabled optional",
    "optimize_prompt_mode": "standard|fast optional",
    "name": "string optional",
    "reference_images": "string[] optional",
    "images": "array optional"
  },
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await runImageGenerationTool(h, args, false))

  registerTool("image_edit", "Edit existing images through FlyMyAI with enforced director routing. Safe edits use gemini38 and one reference image. Adult edits use grok43 and the Seedream model with up to fourteen reference slots. reference_images is required.", %*{
    "prompt": "string",
    "reference_images": "string[]",
    "policy": "safe|adult optional",
    "size": "string optional",
    "quality": "auto|low|medium|high|xhigh|max optional",
    "moderation": "auto|low optional",
    "watermark": "bool optional",
    "sequential_image_generation": "auto|disabled optional",
    "optimize_prompt_mode": "standard|fast optional",
    "name": "string optional"
  },
    proc(h: TaskHandle, args: JsonNode): Future[ToolResult] {.async.} =
      return await runImageGenerationTool(h, args, true))

