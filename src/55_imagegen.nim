proc restoreTask(taskId: string): TaskHandle

proc imageContentPolicyName(policy: ImageContentPolicy): string =
  case policy
  of icpSafe: "safe"
  of icpAdult: "adult"

proc parseImageContentPolicy(value: string): ImageContentPolicy =
  case value.strip().toLowerAscii()
  of "safe", "sfw", "general", "all_ages", "normal": icpSafe
  of "adult", "18", "+18", "nsfw", "explicit", "erotic": icpAdult
  else: raise newException(ValueError, "image content policy must be safe or adult, received: " & value)

proc directorModelForPolicy(policy: ImageContentPolicy): ModelRole =
  case policy
  of icpAdult: mrGrok43
  of icpSafe: mrGemini38

proc policyFromDirectorModel(role: ModelRole): ImageContentPolicy =
  case role
  of mrGrok43: icpAdult
  of mrOrchestrator, mrGpt6Astra, mrGlm52, mrGemini38, mrMiniMaxM3: icpSafe

proc imageModelForPolicy(policy: ImageContentPolicy): string =
  case policy
  of icpAdult:
    if FlyMyAiAdultImageModel.len > 0: FlyMyAiAdultImageModel else: Seedream5ProImageModel
  of icpSafe:
    if FlyMyAiSafeImageModel.len > 0: FlyMyAiSafeImageModel else: GptImage25SunburstEditModel

proc imageModelReferenceSlots(policy: ImageContentPolicy): int =
  case policy
  of icpAdult: SeedreamReferenceSlots
  of icpSafe: 1

proc flyMyAiApiKey(): string =
  requireEnv("FLYMYAI_API_KEY")

proc flyMyAiBase(): string =
  if FlyMyAiBaseUrl.len > 0: FlyMyAiBaseUrl else: DefaultFlyMyAiBaseUrl

proc flyMyAiPredictUrl(model: string): string =
  let parts = model.split('/')
  if parts.len != 2 or parts[0].strip().len == 0 or parts[1].strip().len == 0:
    raise newException(ValueError, "FlyMyAI model must be formatted as <owner>/<project>: " & model)
  flyMyAiBase() & "/api/v1/" & encodeUrl(parts[0].strip()) & "/" & encodeUrl(parts[1].strip()) & "/predict"

proc multipartBoundary(): string =
  "heaven" & newId("b").replace("_", "")

proc formatFormParam(name, value: string): string =
  var escaped = newStringOfCap(value.len + 8)
  for ch in value:
    if ch == '"':
      escaped.add("%22")
    elif ch == '\\':
      escaped.add("\\\\")
    elif ch.ord <= 0x1f and ch.ord != 0x1b:
      escaped.add("%" & toHex(ch.ord, 2).toUpperAscii())
    else:
      escaped.add(ch)
  result = name & "=\"" & escaped & "\""

proc encodeMultipartForm(fields: seq[(string, string)], files: seq[FlyMyAiFileField], boundary: string): string =
  result = newStringOfCap(8192)
  for field in fields:
    result.add("--" & boundary & "\c\L")
    result.add("Content-Disposition: form-data; " & formatFormParam("name", field[0]) & "\c\L\c\L")
    result.add(field[1])
    result.add("\c\L")
  for file in files:
    result.add("--" & boundary & "\c\L")
    result.add("Content-Disposition: form-data; " & formatFormParam("name", file.name) & "; " & formatFormParam("filename", file.filename) & "\c\L")
    result.add("Content-Type: " & file.mimeType & "\c\L\c\L")
    result.add(file.data)
    result.add("\c\L")
  result.add("--" & boundary & "--\c\L")

proc firstSseEventPayload(buffer: string): string =
  var dataLines: seq[string] = @[]
  var eventLines: seq[string] = @[]
  for rawLine in buffer.split('\n'):
    let line = if rawLine.endsWith("\r"): rawLine[0 ..< rawLine.len - 1] else: rawLine
    if line.len == 0:
      if dataLines.len > 0:
        return dataLines.join("\n").strip()
      if eventLines.len > 0:
        return eventLines.join("\n").strip()
      continue
    if line[0] == ':':
      continue
    let colon = line.find(':')
    var field = line
    var value = ""
    if colon >= 0:
      field = line[0 ..< colon]
      value = line[colon + 1 .. ^1]
      if value.startsWith(" "):
        value = value[1 .. ^1]
    case field
    of "data": dataLines.add(value)
    of "event": eventLines.add(value)
    else: discard
  if dataLines.len > 0:
    return dataLines.join("\n").strip()
  if eventLines.len > 0:
    return eventLines.join("\n").strip()
  ""

proc flyMyAiErrorText(node: JsonNode): string =
  if node.isNil:
    return "FlyMyAI returned no response body"
  for key in ["details", "error", "message", "detail", "exception", "traceback", "output_data"]:
    if not node.hasKey(key) or node[key].kind == JNull:
      continue
    let value = node[key]
    if value.kind == JString:
      let text = value.getStr("").strip()
      if text.len > 0:
        return boundUtf8Bytes(text, 4096)
    elif value.kind != JObject or value.len > 0:
      return boundUtf8Bytes(canonical(value), 4096)
  boundUtf8Bytes(canonical(node), 4096)

proc flyMyAiParseEvent(model: string, node: JsonNode, httpStatus: int): FlyMyAiPrediction =
  if node.isNil or node.kind != JObject:
    raise newException(IOError, "FlyMyAI predict event for " & model & " was not a JSON object")
  var status = node{"status"}.getInt(httpStatus)
  let hasDetails = node.hasKey("details") and node["details"].kind != JNull
  if hasDetails and status == 200:
    status = 599
  if status >= 400 or hasDetails:
    var failure = newException(FlyMyAiError, "FlyMyAI predict failed for " & model & " with status " & $status & ": " & flyMyAiErrorText(node))
    failure.status = status
    raise failure
  var outputData = newJObject()
  if node.hasKey("output_data") and node["output_data"].kind == JObject:
    outputData = copy(node["output_data"])
  elif node.hasKey("output") and node["output"].kind == JObject:
    outputData = copy(node["output"])
  elif node.hasKey("response") and node["response"].kind == JObject:
    outputData = copy(node["response"])
  result = FlyMyAiPrediction(status: status, model: model, outputData: outputData, inferenceTime: node{"inference_time"}.getFloat(0.0), raw: copy(node))

proc flyMyAiConsume(model: string, resp: AsyncResponse, maxBytes: int): Future[FlyMyAiPrediction] {.async.} =
  if resp.code.int >= 400:
    let bounded = await readBoundedBody(resp, maxBytes)
    var failure = newException(FlyMyAiError, "FlyMyAI predict failed for " & model & " with HTTP status " & $resp.code.int & ": " & boundUtf8Bytes(bounded[0], 4096))
    failure.status = resp.code.int
    raise failure
  let contentType = resp.headers.getOrDefault("Content-Type").toLowerAscii()
  if "text/event-stream" in contentType:
    var buffer = ""
    var seen = 0
    while true:
      let item = await resp.bodyStream.read()
      if not item[0]:
        break
      seen += item[1].len
      if seen > maxBytes:
        raise newException(IOError, "FlyMyAI response stream exceeded FLYMYAI_MAX_RESPONSE_BYTES")
      buffer.add(item[1])
      buffer = buffer.replace("\r\n", "\n")
      let payload = firstSseEventPayload(buffer)
      if payload.len > 0:
        return flyMyAiParseEvent(model, parseJson(payload), resp.code.int)
    let payload = firstSseEventPayload(buffer)
    if payload.len == 0:
      raise newException(IOError, "FlyMyAI response stream ended without a prediction event")
    return flyMyAiParseEvent(model, parseJson(payload), resp.code.int)
  let bounded = await readBoundedBody(resp, maxBytes)
  if bounded[1]:
    raise newException(IOError, "FlyMyAI response exceeded FLYMYAI_MAX_RESPONSE_BYTES")
  let text = bounded[0].strip()
  if text.len == 0:
    raise newException(IOError, "FlyMyAI returned an empty prediction response")
  if text.startsWith("data:") or text.startsWith("event:"):
    let payload = firstSseEventPayload(text.replace("\r\n", "\n") & "\n\n")
    if payload.len == 0:
      raise newException(IOError, "FlyMyAI returned a malformed prediction event stream")
    return flyMyAiParseEvent(model, parseJson(payload), resp.code.int)
  return flyMyAiParseEvent(model, parseJson(text), resp.code.int)

proc flyMyAiPredictOnce(model, body, contentType: string): Future[FlyMyAiPrediction] {.async.} =
  let url = flyMyAiPredictUrl(model)
  discard validateOutboundUrl(url)
  let timeoutMs = positiveEnvInt("FLYMYAI_TIMEOUT_MS", 900000)
  let maxBytes = positiveEnvInt("FLYMYAI_MAX_RESPONSE_BYTES", 134_217_728)
  var client = newAsyncHttpClient(maxRedirects = 0)
  client.timeout = timeoutMs
  client.headers = newHttpHeaders({
    "X-API-KEY": flyMyAiApiKey(),
    "Accept": "text/event-stream",
    "Content-Type": contentType
  })
  try:
    let resp = await client.request(url, httpMethod = HttpPost, body = body)
    return await flyMyAiConsume(model, resp, maxBytes)
  finally:
    client.close()

proc flyMyAiRetryable(status: int): bool =
  status == 408 or status == 409 or status == 425 or status == 429 or status >= 500

proc flyMyAiPredict(model: string, fields: seq[(string, string)], files: seq[FlyMyAiFileField]): Future[FlyMyAiPrediction] {.async.} =
  let boundary = multipartBoundary()
  let body = encodeMultipartForm(fields, files, boundary)
  let contentType = "multipart/form-data; boundary=" & boundary
  let maxRetries = max(0, positiveEnvInt("FLYMYAI_MAX_RETRIES", 2) - 1)
  var attempt = 0
  while true:
    try:
      return await flyMyAiPredictOnce(model, body, contentType)
    except FlyMyAiError as e:
      if not flyMyAiRetryable(e.status) or attempt >= maxRetries:
        raise
    except CatchableError:
      if attempt >= maxRetries:
        raise
    inc attempt
    await sleepAsync(min(8000, 500 * (1 shl min(attempt, 4))))

proc parsePixelSize(value: string): (bool, int, int) =
  let text = value.strip().toLowerAscii().replace("*", "x").replace(" ", "")
  let parts = text.split('x')
  if parts.len != 2:
    return (false, 0, 0)
  try:
    let width = parseInt(parts[0])
    let height = parseInt(parts[1])
    if width <= 0 or height <= 0:
      return (false, 0, 0)
    return (true, width, height)
  except ValueError:
    return (false, 0, 0)

proc validateAdultImageSize(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return DefaultAdultImageSize
  if text in ["1k", "1.5k", "2k"]:
    return text
  if text == "auto":
    return DefaultAdultImageSize
  let pixels = parsePixelSize(text)
  if not pixels[0]:
    raise newException(ValueError, "adult image size must be 1k, 1.5k, 2k or WIDTHxHEIGHT, received: " & value)
  let total = pixels[1] * pixels[2]
  if total < 921_600 or total > 4_624_220:
    raise newException(ValueError, "adult image size must contain between 921600 and 4624220 total pixels, received: " & value)
  let ratio = pixels[1].float / pixels[2].float
  if ratio < 1.0 / 16.0 or ratio > 16.0:
    raise newException(ValueError, "adult image aspect ratio must stay between 1:16 and 16:1, received: " & value)
  $pixels[1] & "x" & $pixels[2]

proc validateSafeImageSize(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return DefaultSafeImageSize
  if text == "auto":
    return "auto"
  let pixels = parsePixelSize(text)
  if not pixels[0]:
    raise newException(ValueError, "safe image size must be auto or WIDTHxHEIGHT, received: " & value)
  let width = pixels[1]
  let height = pixels[2]
  if width mod 16 != 0 or height mod 16 != 0:
    raise newException(ValueError, "safe image width and height must both be multiples of 16, received: " & value)
  if width > 3840 or height > 3840:
    raise newException(ValueError, "safe image edges must not exceed 3840 pixels, received: " & value)
  let longSide = max(width, height).float
  let shortSide = min(width, height).float
  if shortSide <= 0.0 or longSide / shortSide > 3.0:
    raise newException(ValueError, "safe image aspect ratio must not exceed 3:1, received: " & value)
  let total = width * height
  if total < 655_360 or total > 8_294_400:
    raise newException(ValueError, "safe image must contain between 655360 and 8294400 total pixels, received: " & value)
  $width & "x" & $height

proc validateImageSize(policy: ImageContentPolicy, value: string): string =
  case policy
  of icpAdult: validateAdultImageSize(value)
  of icpSafe: validateSafeImageSize(value)

proc validateSafeImageQuality(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return DefaultSafeImageQuality
  if text notin ["auto", "low", "medium", "high", "xhigh", "max"]:
    raise newException(ValueError, "safe image quality must be one of auto, low, medium, high, xhigh, max, received: " & value)
  text

proc validateSafeImageModeration(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return ""
  if text notin ["auto", "low"]:
    raise newException(ValueError, "safe image moderation must be auto or low, received: " & value)
  text

proc validateSequentialImageGeneration(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return DefaultSequentialImageGeneration
  if text notin ["auto", "disabled"]:
    raise newException(ValueError, "sequential_image_generation must be auto or disabled, received: " & value)
  text

proc validateOptimizePromptMode(value: string): string =
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return DefaultOptimizePromptMode
  if text notin ["standard", "fast"]:
    raise newException(ValueError, "optimize_prompt_mode must be standard or fast, received: " & value)
  text

proc imageExtensionForMime(mime: string): string =
  case mime.strip().toLowerAscii()
  of "image/png": ".png"
  of "image/jpeg", "image/jpg": ".jpg"
  of "image/webp": ".webp"
  of "image/gif": ".gif"
  of "image/bmp": ".bmp"
  of "image/tiff": ".tiff"
  of "image/heic": ".heic"
  of "image/heif": ".heif"
  of "image/svg+xml": ".svg"
  of "image/avif": ".avif"
  else: ".img"

proc imageMimeFromBytes(data: string): string =
  if data.len >= 8 and data[0].uint8 == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G':
    return "image/png"
  if data.len >= 3 and data[0].uint8 == 0xff and data[1].uint8 == 0xd8 and data[2].uint8 == 0xff:
    return "image/jpeg"
  if data.len >= 6 and data.startsWith("GIF8"):
    return "image/gif"
  if data.len >= 12 and data.startsWith("RIFF") and data[8 .. 11] == "WEBP":
    return "image/webp"
  if data.len >= 2 and data[0] == 'B' and data[1] == 'M':
    return "image/bmp"
  if data.len >= 12 and (data[4 .. 7] == "ftyp"):
    if data[8 .. 11] == "heic" or data[8 .. 11] == "heix" or data[8 .. 11] == "mif1":
      return "image/heic"
    if data[8 .. 11] == "avif" or data[8 .. 11] == "avis":
      return "image/avif"
  if data.len >= 4 and (data[0].uint8 == 0x49 and data[1].uint8 == 0x49 and data[2].uint8 == 0x2a):
    return "image/tiff"
  if data.len >= 4 and (data[0].uint8 == 0x4d and data[1].uint8 == 0x4d and data[2].uint8 == 0x00):
    return "image/tiff"
  if data.len >= 512 and data.strip().startsWith("<svg"):
    return "image/svg+xml"
  "application/octet-stream"

proc sanitizeImageFilename(name, mime: string, index: int): string =
  var cleaned = newStringOfCap(name.len + 8)
  for ch in name:
    if ch.isAlphaNumeric() or ch in {'.', '-', '_'}:
      cleaned.add(ch)
    else:
      cleaned.add('-')
  cleaned = cleaned.strip(chars = {'-', '.'})
  if cleaned.len == 0:
    cleaned = "reference-" & $(index + 1)
  if cleaned.len > 96:
    cleaned = cleaned[0 ..< 96]
  let ext = imageExtensionForMime(mime)
  let parts = splitFile(cleaned)
  if parts.ext.len == 0:
    cleaned = cleaned & ext
  elif parts.ext.toLowerAscii() != ext:
    cleaned = parts.name & ext
  cleaned

proc decodeBase64Image(value: string): string =
  var cleaned = value.replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "")
  if cleaned.len == 0:
    raise newException(ValueError, "base64 image reference is empty")
  while cleaned.len mod 4 != 0:
    cleaned.add('=')
  try:
    result = base64.decode(cleaned)
  except CatchableError as e:
    raise newException(ValueError, "invalid base64 image reference: " & e.msg)
  if result.len == 0:
    raise newException(ValueError, "base64 image reference decoded to zero bytes")

proc decodeDataUrlImage(value: string): (string, string) =
  let comma = value.find(',')
  if comma < 0:
    raise newException(ValueError, "malformed data URL image reference")
  let header = value[5 ..< comma]
  let payload = value[comma + 1 .. ^1]
  let semi = header.find(';')
  let mime = (if semi >= 0: header[0 ..< semi] else: header).strip().toLowerAscii()
  let data = decodeBase64Image(payload)
  ((if mime.len > 0: mime else: "application/octet-stream"), data)

proc referenceBaseName(source: string): string =
  var value = source.strip()
  if value.startsWith("http://") or value.startsWith("https://"):
    let parsed = parseUri(value)
    value = parsed.path
  let colon = value.find(':')
  if colon >= 0 and colon < value.len - 1:
    value = value[colon + 1 .. ^1]
  let question = value.find('?')
  if question >= 0:
    value = value[0 ..< question]
  let slash = value.rfind('/')
  if slash >= 0 and slash < value.len - 1:
    value = value[slash + 1 .. ^1]
  value

proc resolveImageReference(tenantId, taskId, source: string, index: int): Future[ImageReference] {.async.} =
  let value = source.strip()
  if value.len == 0:
    raise newException(ValueError, "image reference must not be empty")
  let maxBytes = positiveEnvInt("IMAGE_REFERENCE_MAX_BYTES", 31_457_280)
  var mime = ""
  var data = ""
  if value.startsWith("data:"):
    let decoded = decodeDataUrlImage(value)
    mime = decoded[0]
    data = decoded[1]
  elif value.startsWith("http://") or value.startsWith("https://"):
    let response = await httpRequestAsync(value, HttpGet)
    if response[0] < 200 or response[0] >= 300:
      raise newException(IOError, "image reference download failed with status " & $response[0] & ": " & value)
    if response[1].len > maxBytes:
      raise newException(ValueError, "image reference exceeds IMAGE_REFERENCE_MAX_BYTES: " & value)
    mime = response[2].getOrDefault("Content-Type").split(';')[0].strip().toLowerAscii()
    data = response[1]
  else:
    let prefix = value.find(':')
    var lookupKind = ""
    var lookupId = value
    if prefix > 0 and prefix < value.len - 1:
      lookupKind = value[0 ..< prefix].strip().toLowerAscii()
      lookupId = value[prefix + 1 .. ^1].strip()
    if lookupKind == "artifact" or (lookupKind.len == 0 and lookupId.startsWith("artifact_")):
      let rows = store.query("SELECT a.path, a.mime_type FROM artifacts a JOIN tasks t ON t.task_id=a.task_id WHERE a.artifact_id=? AND t.tenant_id=?", @[%lookupId, %tenantId])
      if rows.len == 0:
        raise newException(ValueError, "unknown image artifact reference: " & value)
      let path = absolutePath(rows[0].getStr("path"))
      if not fileExists(path):
        raise newException(IOError, "referenced artifact file is missing: " & path)
      if getFileSize(path) > maxBytes:
        raise newException(ValueError, "referenced artifact exceeds IMAGE_REFERENCE_MAX_BYTES: " & value)
      data = readFile(path)
      mime = rows[0].getStr("mime_type")
    elif lookupKind == "image" or (lookupKind.len == 0 and lookupId.startsWith("image_")):
      let rows = store.query("SELECT paths_json FROM image_generations WHERE image_id=? AND tenant_id=? AND status='succeeded'", @[%lookupId, %tenantId])
      if rows.len == 0:
        raise newException(ValueError, "unknown generated image reference: " & value)
      let paths = rows[0].getJson("paths_json", newJArray())
      if paths.kind != JArray or paths.elems.len == 0 or paths[0].kind != JObject:
        raise newException(ValueError, "generated image reference has no stored file: " & value)
      let path = absolutePath(paths[0]{"path"}.getStr(""))
      if path.len == 0 or not fileExists(path):
        raise newException(IOError, "generated image file is missing: " & path)
      if getFileSize(path) > maxBytes:
        raise newException(ValueError, "generated image exceeds IMAGE_REFERENCE_MAX_BYTES: " & value)
      data = readFile(path)
      mime = paths[0]{"mime_type"}.getStr("")
    else:
      let full = safeJoin(tenantId, value)
      if not fileExists(full):
        raise newException(IOError, "image reference file not found in tenant workspace: " & value)
      if getFileSize(full) > maxBytes:
        raise newException(ValueError, "image reference exceeds IMAGE_REFERENCE_MAX_BYTES: " & value)
      data = readFile(full)
  if data.len == 0:
    raise newException(ValueError, "image reference resolved to zero bytes: " & value)
  if data.len > maxBytes:
    raise newException(ValueError, "image reference exceeds IMAGE_REFERENCE_MAX_BYTES: " & value)
  let sniffed = imageMimeFromBytes(data)
  if mime.len == 0 or not mime.startsWith("image/"):
    mime = sniffed
  if mime == "application/octet-stream" and sniffed != "application/octet-stream":
    mime = sniffed
  result = ImageReference(source: value, filename: sanitizeImageFilename(referenceBaseName(value), mime, index), mimeType: mime, data: data, bytes: data.len)

proc resolveImageReferences(tenantId, taskId: string, node: JsonNode): Future[seq[ImageReference]] {.async.} =
  result = @[]
  if node.isNil or node.kind != JObject:
    return
  var sources: seq[string] = @[]
  for key in ["reference_images", "references", "images_in", "input_images"]:
    if node.hasKey(key) and node[key].kind == JArray:
      for item in node[key].elems:
        if item.kind == JString and item.getStr("").strip().len > 0:
          sources.add(item.getStr().strip())
        elif item.kind == JObject:
          let nested = item{"source"}.getStr(item{"path"}.getStr(item{"url"}.getStr(item{"data"}.getStr(""))))
          if nested.strip().len > 0:
            sources.add(nested.strip())
  let single = node{"image"}.getStr(node{"reference_image"}.getStr("")).strip()
  if single.len > 0:
    sources.add(single)
  var seen = initHashSet[string]()
  var index = 0
  for source in sources:
    if source in seen:
      continue
    seen.incl(source)
    result.add(await resolveImageReference(tenantId, taskId, source, index))
    inc index

proc imageOutputDirectory(taskId, tenantId: string): string =
  let bucket = if taskId.len > 0: taskId else: "direct-" & sanitizeKnowledgeName(tenantId) & "-" & sha1Hex(tenantId)[0 .. 15]
  let artifactsRoot = absolutePath(WorkspaceRoot / "artifacts")
  createDir(artifactsRoot)
  result = absolutePath(artifactsRoot / bucket)
  if not result.startsWith(artifactsRoot & DirSep):
    raise newException(ValueError, "image output directory escapes the artifact root")
  createDir(result)

proc validateImageArtifactName(name: string): string =
  let value = name.strip()
  if value.len == 0:
    return ""
  if extractFilename(value) != value or value.contains("..") or value.contains('/') or value.contains('\\') or '\0' in value:
    raise newException(ValueError, "invalid image artifact name: " & name)
  value

proc outputFormatFromMime(mime: string): string =
  case mime.toLowerAscii()
  of "image/png": "png"
  of "image/jpeg", "image/jpg": "jpeg"
  of "image/webp": "webp"
  of "image/gif": "gif"
  of "image/bmp": "bmp"
  of "image/tiff": "tiff"
  of "image/heic": "heic"
  of "image/avif": "avif"
  of "image/svg+xml": "svg"
  else: "binary"

proc decodeGeneratedImage(value: string): (string, string) =
  let text = value.strip()
  if text.len == 0:
    return ("", "")
  if text.startsWith("data:"):
    let decoded = decodeDataUrlImage(text)
    return (decoded[1], decoded[0])
  if text.startsWith("http://") or text.startsWith("https://"):
    return ("", "")
  (decodeBase64Image(text), "")

proc collectGeneratedImageValues(node: JsonNode, depth: int): seq[string] =
  result = @[]
  if node.isNil or depth > 6:
    return
  case node.kind
  of JString:
    let text = node.getStr("").strip()
    if text.len > 64:
      result.add(text)
  of JArray:
    for item in node.elems:
      for value in collectGeneratedImageValues(item, depth + 1):
        result.add(value)
  of JObject:
    for key in ["image", "images", "sample", "output", "outputs", "result", "results", "b64_json", "base64", "data", "image_url", "image_urls", "media_url", "media_urls", "url", "urls"]:
      if node.hasKey(key):
        for value in collectGeneratedImageValues(node[key], depth + 1):
          result.add(value)
  else:
    discard

proc downloadGeneratedImageUrl(url: string, maxBytes: int): Future[(string, string)] {.async.} =
  let response = await httpRequestAsync(url, HttpGet)
  if response[0] < 200 or response[0] >= 300:
    raise newException(IOError, "generated image url download failed with status " & $response[0] & ": " & url)
  if response[1].len == 0:
    raise newException(IOError, "generated image url returned zero bytes: " & url)
  if response[1].len > maxBytes:
    raise newException(IOError, "generated image url exceeds IMAGE_OUTPUT_MAX_BYTES: " & url)
  let mime = response[2].getOrDefault("Content-Type").split(';')[0].strip().toLowerAscii()
  return (response[1], mime)

proc outputDataKeyList(node: JsonNode): string =
  if node.isNil or node.kind != JObject:
    return "none"
  var keys: seq[string] = @[]
  for key, _ in node.fields:
    keys.add(key)
  if keys.len == 0:
    return "none"
  keys.join(", ")

proc extractGeneratedImages(outputData: JsonNode, maxBytes: int): Future[seq[(string, string)]] {.async.} =
  result = @[]
  let values = collectGeneratedImageValues(outputData, 0)
  if values.len == 0:
    raise newException(IOError, "FlyMyAI returned no image output; output keys: " & outputDataKeyList(outputData))
  var seen = initHashSet[string]()
  for value in values:
    let digest = sha1Hex(value)
    if digest in seen:
      continue
    seen.incl(digest)
    let decoded = decodeGeneratedImage(value)
    if decoded[0].len > 0:
      if decoded[0].len > maxBytes:
        raise newException(IOError, "generated image exceeds IMAGE_OUTPUT_MAX_BYTES")
      result.add(decoded)
      continue
    if value.startsWith("http://") or value.startsWith("https://"):
      let downloaded = await downloadGeneratedImageUrl(value, maxBytes)
      if downloaded[0].len > 0:
        result.add(downloaded)

proc imageGenerationSummary(outputData: JsonNode): JsonNode =
  result = newJObject()
  if outputData.isNil or outputData.kind != JObject:
    return
  for key, value in outputData.fields:
    case value.kind
    of JString:
      if value.getStr("").len > 512:
        result[key] = %*{"type": "string", "bytes": value.getStr("").len}
      else:
        result[key] = copy(value)
    of JArray:
      var entries = newJArray()
      for item in value.elems:
        if item.kind == JString and item.getStr("").len > 512:
          entries.add(%*{"type": "string", "bytes": item.getStr("").len})
        else:
          entries.add(copy(item))
      result[key] = entries
    else:
      result[key] = copy(value)

proc imageGenerationRecordJson(r: Row): JsonNode =
  let imageId = r.getStr("image_id")
  let paths = r.getJson("paths_json", newJArray())
  var images = newJArray()
  if paths.kind == JArray:
    for entry in paths.elems:
      if entry.kind != JObject:
        continue
      images.add(copy(entry))
  result = %*{
    "image_id": imageId,
    "tenant_id": r.getStr("tenant_id"),
    "task_id": r.getStr("task_id"),
    "agent_id": r.getStr("agent_id"),
    "step_id": r.getStr("step_id"),
    "director_model": r.getStr("director_model"),
    "director_enforced": r.getInt("director_enforced") == 1,
    "policy": r.getStr("policy"),
    "model": r.getStr("upstream_model"),
    "prompt": r.getStr("prompt"),
    "size": r.getStr("size"),
    "quality": r.getStr("quality"),
    "moderation": r.getStr("moderation"),
    "watermark": r.getInt("watermark") == 1,
    "sequential_image_generation": r.getStr("sequential_image_generation"),
    "optimize_prompt_mode": r.getStr("optimize_prompt_mode"),
    "reference_count": r.getInt("reference_count"),
    "image_count": r.getInt("image_count"),
    "artifact_ids": r.getJson("artifact_ids_json", newJArray()),
    "images": images,
    "status": r.getStr("status"),
    "error": r.getStr("error"),
    "latency_ms": r.getInt("latency_ms"),
    "inference_time": r.getFloat("inference_time"),
    "token_cost": r.getInt("token_cost"),
    "request": r.getJson("request_json", newJObject()),
    "response": r.getJson("response_json", newJObject()),
    "created_at": r.getFloat("created_at"),
    "updated_at": r.getFloat("updated_at")
  }

proc imageGenerationRecord(imageId: string): JsonNode =
  let rows = store.query("SELECT * FROM image_generations WHERE image_id=?", @[%imageId])
  if rows.len == 0:
    return nil
  imageGenerationRecordJson(rows[0])

proc imageGenerationListJson(tenantId, taskId, status: string, limit: int): JsonNode =
  var sql = "SELECT * FROM image_generations WHERE tenant_id=?"
  var params = @[%tenantId]
  if taskId.len > 0:
    sql.add(" AND task_id=?")
    params.add(%taskId)
  if status.len > 0:
    sql.add(" AND status=?")
    params.add(%status)
  sql.add(" ORDER BY created_at DESC LIMIT ?")
  params.add(%max(1, limit))
  result = newJArray()
  for r in store.query(sql, params):
    result.add(imageGenerationRecordJson(r))

proc imageGenerationCatalogJson(taskId: string, limit: int): JsonNode =
  result = newJArray()
  if taskId.len == 0:
    return
  for r in store.query("SELECT image_id,policy,upstream_model,director_model,prompt,status,image_count,paths_json,error,created_at FROM image_generations WHERE task_id=? ORDER BY created_at DESC LIMIT ?", @[%taskId, %max(1, limit)]):
    let paths = r.getJson("paths_json", newJArray())
    var images = newJArray()
    if paths.kind == JArray:
      for entry in paths.elems:
        if entry.kind == JObject:
          images.add(%*{"name": entry{"name"}.getStr(""), "mime_type": entry{"mime_type"}.getStr(""), "bytes": entry{"bytes"}.getInt(0), "artifact_id": entry{"artifact_id"}.getStr(""), "url": entry{"url"}.getStr(""), "view_url": entry{"view_url"}.getStr("")})
    result.add(%*{
      "image_id": r.getStr("image_id"),
      "policy": r.getStr("policy"),
      "model": r.getStr("upstream_model"),
      "director_model": r.getStr("director_model"),
      "prompt": r.getStr("prompt"),
      "status": r.getStr("status"),
      "image_count": r.getInt("image_count"),
      "error": r.getStr("error"),
      "created_at": r.getFloat("created_at"),
      "images": images
    })

proc insertImageGeneration(imageId, tenantId, taskId: string, request: ImageGenerationRequest, model: string, requestJson: JsonNode) =
  let ts = nowF()
  discard store.exec("INSERT INTO image_generations (image_id, tenant_id, task_id, agent_id, step_id, director_model, director_enforced, policy, upstream_model, prompt, size, quality, moderation, watermark, sequential_image_generation, optimize_prompt_mode, reference_count, image_count, artifact_ids_json, paths_json, status, error, latency_ms, inference_time, token_cost, request_json, response_json, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    @[
      %imageId,
      %tenantId,
      %taskId,
      %request.directorAgentId,
      %request.stepId,
      %request.directorModel,
      %(if request.directorEnforced: 1 else: 0),
      %imageContentPolicyName(request.policy),
      %model,
      %request.prompt,
      %request.size,
      %request.quality,
      %request.moderation,
      %(if request.watermark: 1 else: 0),
      %request.sequential,
      %request.optimizePromptMode,
      %request.references.len,
      %0,
      %($newJArray()),
      %($newJArray()),
      %"queued",
      %"",
      %0,
      %0.0,
      %0,
      %($requestJson),
      %("{}"),
      %ts,
      %ts
    ])

proc completeImageGeneration(imageId, status, errorText: string, imageCount, latencyMs, tokenCost: int, artifactIds, paths, response: JsonNode, inferenceTime: float) =
  discard store.exec("UPDATE image_generations SET status=?, error=?, image_count=?, artifact_ids_json=?, paths_json=?, response_json=?, latency_ms=?, inference_time=?, token_cost=?, updated_at=? WHERE image_id=?",
    @[%status, %errorText, %imageCount, %($artifactIds), %($paths), %($response), %latencyMs, %inferenceTime, %tokenCost, %nowF(), %imageId])

proc imageRequestPayloadJson(request: ImageGenerationRequest): JsonNode =
  var references = newJArray()
  for reference in request.references:
    references.add(%*{"source": reference.source, "filename": reference.filename, "mime_type": reference.mimeType, "bytes": reference.bytes})
  result = %*{
    "prompt": request.prompt,
    "policy": imageContentPolicyName(request.policy),
    "upstream_model": imageModelForPolicy(request.policy),
    "director_model": request.directorModel,
    "director_agent_id": request.directorAgentId,
    "step_id": request.stepId,
    "size": request.size,
    "quality": request.quality,
    "moderation": request.moderation,
    "watermark": request.watermark,
    "sequential_image_generation": request.sequential,
    "optimize_prompt_mode": request.optimizePromptMode,
    "name": request.name,
    "references": references
  }

proc directorViolation(policy: ImageContentPolicy, role: ModelRole, actorKnown: bool): string =
  if not actorKnown:
    return ""
  let enforcement = getEnv("IMAGE_DIRECTOR_ENFORCEMENT", "strict").strip().toLowerAscii()
  if enforcement != "strict":
    return ""
  let required = directorModelForPolicy(policy)
  if role == required:
    return ""
  "image generation with policy " & imageContentPolicyName(policy) & " must be directed by " & modelRoleName(required) &
    ", but this action was issued by " & modelRoleName(role) &
    ". Route the image work to " & modelRoleName(required) & " with a plan step or spawn_subagent using model " & modelRoleName(required) &
    " and let that director issue the image tool call."

proc generateImage(tenantId, taskId: string, h: TaskHandle, request: ImageGenerationRequest): Future[ImageGenerationResult] {.async.} =
  let imageId = newId("image")
  let model = imageModelForPolicy(request.policy)
  let prompt = request.prompt.strip()
  if prompt.len == 0:
    raise newException(ValueError, "image prompt is required")
  let sizeValue = validateImageSize(request.policy, request.size)
  var fields: seq[(string, string)] = @[]
  var files: seq[FlyMyAiFileField] = @[]
  var qualityValue = ""
  var moderationValue = ""
  var sequentialValue = DefaultSequentialImageGeneration
  var optimizeValue = DefaultOptimizePromptMode
  let slots = imageModelReferenceSlots(request.policy)
  if request.references.len > slots:
    raise newException(ValueError, "the " & model & " image model accepts at most " & $slots & " reference images, received " & $request.references.len)
  if request.policy == icpAdult:
    sequentialValue = validateSequentialImageGeneration(request.sequential)
    optimizeValue = validateOptimizePromptMode(request.optimizePromptMode)
    fields.add(("prompt", prompt))
    fields.add(("size", sizeValue))
    fields.add(("watermark", if request.watermark: "true" else: "false"))
    fields.add(("sequential_image_generation", sequentialValue))
    fields.add(("optimize_prompt_mode", optimizeValue))
    for slot in 0 ..< slots:
      let key = if slot == 0: "image" else: "image" & $slot
      if slot < request.references.len:
        let reference = request.references[slot]
        files.add(FlyMyAiFileField(name: key, filename: reference.filename, mimeType: reference.mimeType, data: reference.data))
      else:
        fields.add((key, ""))
  else:
    qualityValue = validateSafeImageQuality(request.quality)
    moderationValue = validateSafeImageModeration(request.moderation)
    fields.add(("prompt", prompt))
    fields.add(("moderation", moderationValue))
    fields.add(("quality", qualityValue))
    fields.add(("size", sizeValue))
    if request.references.len > 0:
      let reference = request.references[0]
      files.add(FlyMyAiFileField(name: "image", filename: reference.filename, mimeType: reference.mimeType, data: reference.data))
    else:
      fields.add(("image", ""))
  var recordRequest = imageRequestPayloadJson(request)
  recordRequest["size"] = %sizeValue
  recordRequest["quality"] = %qualityValue
  recordRequest["moderation"] = %moderationValue
  recordRequest["sequential_image_generation"] = %sequentialValue
  recordRequest["optimize_prompt_mode"] = %optimizeValue
  var fieldSummary = newJObject()
  for field in fields:
    fieldSummary[field[0]] = %field[1]
  var fileSummary = newJArray()
  for file in files:
    fileSummary.add(%*{"field": file.name, "filename": file.filename, "mime_type": file.mimeType, "bytes": file.data.len})
  recordRequest["multipart_fields"] = fieldSummary
  recordRequest["multipart_files"] = fileSummary
  insertImageGeneration(imageId, tenantId, taskId, request, model, recordRequest)
  if not h.isNil:
    h.emit(%*{"type": "image_generation_started", "image_id": imageId, "model": model, "policy": imageContentPolicyName(request.policy), "director_model": request.directorModel, "prompt": prompt, "size": sizeValue, "reference_count": request.references.len})
  let started = getMonoTime()
  var prediction: FlyMyAiPrediction
  try:
    prediction = await flyMyAiPredict(model, fields, files)
  except CatchableError as e:
    let latency = int((getMonoTime() - started).inMilliseconds)
    completeImageGeneration(imageId, "failed", e.msg, 0, latency, 0, newJArray(), newJArray(), newJObject(), 0.0)
    if not h.isNil:
      h.emit(%*{"type": "image_generation_failed", "image_id": imageId, "model": model, "error": e.msg})
    raise
  let latency = int((getMonoTime() - started).inMilliseconds)
  let maxOutputBytes = positiveEnvInt("IMAGE_OUTPUT_MAX_BYTES", 67_108_864)
  var generated: seq[(string, string)] = @[]
  try:
    generated = await extractGeneratedImages(prediction.outputData, maxOutputBytes)
  except CatchableError as e:
    completeImageGeneration(imageId, "failed", e.msg, 0, latency, 0, newJArray(), newJArray(), imageGenerationSummary(prediction.outputData), prediction.inferenceTime)
    if not h.isNil:
      h.emit(%*{"type": "image_generation_failed", "image_id": imageId, "model": model, "error": e.msg})
    raise
  if generated.len == 0:
    let message = "FlyMyAI returned an empty image payload for " & model
    completeImageGeneration(imageId, "failed", message, 0, latency, 0, newJArray(), newJArray(), imageGenerationSummary(prediction.outputData), prediction.inferenceTime)
    if not h.isNil:
      h.emit(%*{"type": "image_generation_failed", "image_id": imageId, "model": model, "error": message})
    raise newException(IOError, message)
  let directory = imageOutputDirectory(taskId, tenantId)
  let requestedName = validateImageArtifactName(request.name)
  var artifactIds = newJArray()
  var storedPaths = newJArray()
  var totalBytes = 0
  var tokenCost = 0
  let perImageCost = max(0, positiveEnvInt("IMAGE_GENERATION_TOKEN_COST", 0))
  for index, item in generated:
    let data = item[0]
    let sniffed = imageMimeFromBytes(data)
    let mime = if sniffed != "application/octet-stream": sniffed elif item[1].len > 0: item[1] else: "application/octet-stream"
    let extension = imageExtensionForMime(mime)
    var name = ""
    if requestedName.len > 0:
      let parts = splitFile(requestedName)
      name = (if generated.len == 1: parts.name else: parts.name & "-" & $(index + 1)) & (if parts.ext.len > 0: parts.ext else: extension)
    else:
      name = "image-" & imageId & "-" & $(index + 1) & extension
    name = sanitizeImageFilename(name, mime, index)
    let path = absolutePath(directory / name)
    if not path.startsWith(directory & DirSep):
      raise newException(ValueError, "generated image path escapes the task artifact directory")
    atomicWrite(path, data)
    totalBytes += data.len
    var artifactId = ""
    if not h.isNil:
      artifactId = h.addArtifact(name, path, "image", mime, %*{
        "image_id": imageId,
        "generated": true,
        "policy": imageContentPolicyName(request.policy),
        "model": model,
        "director_model": request.directorModel,
        "prompt": prompt,
        "size": sizeValue,
        "index": index,
        "bytes": data.len
      })
      artifactIds.add(%artifactId)
    let entry = %*{
      "index": index,
      "name": name,
      "path": path,
      "mime_type": mime,
      "output_format": outputFormatFromMime(mime),
      "bytes": data.len,
      "sha1": sha1Hex(data),
      "artifact_id": artifactId,
      "url": (if artifactId.len > 0: "/api/artifacts/" & artifactId else: "/api/images/" & imageId & "/" & $index),
      "view_url": (if artifactId.len > 0: "/api/artifacts/" & artifactId else: "/api/images/" & imageId & "/" & $index)
    }
    storedPaths.add(entry)
    inc tokenCost, perImageCost
  if tokenCost > 0 and not chargeTokens(tenantId, taskId, tokenCost):
    completeImageGeneration(imageId, "failed", "token budget exhausted", generated.len, latency, tokenCost, artifactIds, storedPaths, imageGenerationSummary(prediction.outputData), prediction.inferenceTime)
    raise newException(IOError, "token budget exhausted")
  completeImageGeneration(imageId, "succeeded", "", generated.len, latency, tokenCost, artifactIds, storedPaths, imageGenerationSummary(prediction.outputData), prediction.inferenceTime)
  let payload = %*{
    "ok": true,
    "image_id": imageId,
    "policy": imageContentPolicyName(request.policy),
    "model": model,
    "director_model": request.directorModel,
    "prompt": prompt,
    "size": sizeValue,
    "quality": qualityValue,
    "moderation": moderationValue,
    "watermark": request.watermark,
    "sequential_image_generation": sequentialValue,
    "optimize_prompt_mode": optimizeValue,
    "reference_count": request.references.len,
    "image_count": generated.len,
    "total_bytes": totalBytes,
    "token_cost": tokenCost,
    "latency_ms": latency,
    "inference_time": prediction.inferenceTime,
    "artifact_ids": artifactIds,
    "images": storedPaths,
    "task_id": taskId,
    "output": imageGenerationSummary(prediction.outputData)
  }
  if not h.isNil:
    h.emit(%*{"type": "image_generated", "image_id": imageId, "model": model, "policy": imageContentPolicyName(request.policy), "director_model": request.directorModel, "images": storedPaths, "latency_ms": latency, "inference_time": prediction.inferenceTime})
  return ImageGenerationResult(ok: true, imageId: imageId, model: model, policy: request.policy, directorModel: request.directorModel, payload: payload, receipt: "image:" & imageId, message: "generated " & $generated.len & " image with " & model, latencyMs: latency)

proc generateImageForRequest(h: TaskHandle, tenantId, taskId: string, request: ImageGenerationRequest): Future[ImageGenerationResult] {.async.} =
  try:
    return await generateImage(tenantId, taskId, h, request)
  except CatchableError as e:
    let model = imageModelForPolicy(request.policy)
    return ImageGenerationResult(ok: false, imageId: "", model: model, policy: request.policy, directorModel: request.directorModel,
      payload: %*{"ok": false, "error": e.msg, "policy": imageContentPolicyName(request.policy), "model": model, "prompt": request.prompt, "size": request.size, "reference_count": request.references.len},
      receipt: "", message: e.msg, latencyMs: 0)

proc imagePromptFromNode(node: JsonNode): string =
  node{"prompt"}.getStr(node{"text"}.getStr(node{"description"}.getStr(node{"instruction"}.getStr("")))).strip()

proc imageRequestFromNode(tenantId, taskId: string, node: JsonNode, fallbackPolicy: ImageContentPolicy, requireReferences: bool): Future[ImageGenerationRequest] {.async.} =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "image request must be a JSON object")
  let prompt = imagePromptFromNode(node)
  if prompt.len == 0:
    raise newException(ValueError, "image prompt is required")
  var policy = fallbackPolicy
  let policyText = node{"policy"}.getStr(node{"content_policy"}.getStr(node{"audience"}.getStr(""))).strip()
  if policyText.len > 0:
    policy = parseImageContentPolicy(policyText)
  elif node.hasKey("adult") and node["adult"].kind == JBool:
    policy = if node["adult"].getBool(): icpAdult else: icpSafe
  elif node.hasKey("adult_content") and node["adult_content"].kind == JBool:
    policy = if node["adult_content"].getBool(): icpAdult else: icpSafe
  let references = await resolveImageReferences(tenantId, taskId, node)
  if requireReferences and references.len == 0:
    raise newException(ValueError, "image editing requires at least one reference image")
  result = ImageGenerationRequest(
    prompt: prompt,
    policy: policy,
    size: node{"size"}.getStr(""),
    quality: node{"quality"}.getStr(""),
    moderation: node{"moderation"}.getStr(""),
    watermark: node{"watermark"}.getBool(false),
    sequential: node{"sequential_image_generation"}.getStr(""),
    optimizePromptMode: node{"optimize_prompt_mode"}.getStr(""),
    name: node{"name"}.getStr(""),
    references: references,
    directorModel: "",
    directorAgentId: "",
    stepId: "",
    directorEnforced: false
  )

proc runImageGenerationTool(h: TaskHandle, args: JsonNode, requireReferences: bool): Future[ToolResult] {.async.} =
  let tenantId = if h.tenantId.len > 0: h.tenantId else: defaultTenantId
  let actorName = args{"_actor_model"}.getStr("").strip()
  var actorRole = mrGemini38
  var actorKnown = false
  if actorName.len > 0:
    try:
      actorRole = parseModelRole(actorName)
      actorKnown = true
    except CatchableError:
      actorKnown = false
  let fallbackPolicy = policyFromDirectorModel(actorRole)
  var requests: seq[ImageGenerationRequest] = @[]
  try:
    if args.hasKey("images") and args["images"].kind == JArray:
      let maxBatch = positiveEnvInt("IMAGE_MAX_BATCH", 4)
      if args["images"].elems.len == 0:
        return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "images must contain at least one image request object")
      if args["images"].elems.len > maxBatch:
        return ToolResult(ok: false, payload: %*{"requested": args["images"].elems.len, "max_batch": maxBatch}, receipt: "", message: "images batch exceeds IMAGE_MAX_BATCH")
      for entry in args["images"].elems:
        if entry.kind != JObject:
          return ToolResult(ok: false, payload: newJObject(), receipt: "", message: "every images entry must be an object")
        requests.add(await imageRequestFromNode(tenantId, h.taskId, entry, fallbackPolicy, requireReferences))
    else:
      requests.add(await imageRequestFromNode(tenantId, h.taskId, args, fallbackPolicy, requireReferences))
  except CatchableError as e:
    return ToolResult(ok: false, payload: %*{"error": e.msg}, receipt: "", message: e.msg)
  var violation = ""
  for index in 0 ..< requests.len:
    requests[index].directorModel = modelRoleName(actorRole)
    requests[index].directorAgentId = args{"_actor_agent_id"}.getStr("")
    requests[index].stepId = args{"_actor_step_id"}.getStr("")
    requests[index].directorEnforced = actorKnown
    if violation.len == 0:
      violation = directorViolation(requests[index].policy, actorRole, actorKnown)
  if violation.len > 0:
    return ToolResult(ok: false,
      payload: %*{"policy": imageContentPolicyName(requests[0].policy), "director_model": modelRoleName(actorRole), "required_director_model": modelRoleName(directorModelForPolicy(requests[0].policy))},
      receipt: "", message: violation)
  var results = newJArray()
  var imageIds = newJArray()
  var allOk = true
  var firstMessage = ""
  var firstError = ""
  var totalLatency = 0
  for request in requests:
    let outcome = await generateImageForRequest(h, tenantId, h.taskId, request)
    results.add(outcome.payload)
    totalLatency += outcome.latencyMs
    if outcome.ok:
      imageIds.add(%outcome.imageId)
      if firstMessage.len == 0:
        firstMessage = outcome.message
    else:
      allOk = false
      if firstError.len == 0:
        firstError = outcome.message
  if imageIds.elems.len == 0:
    return ToolResult(ok: false, payload: %*{"ok": false, "results": results, "latency_ms": totalLatency}, receipt: "", message: (if firstError.len > 0: firstError else: "image generation produced no image"))
  let message = if allOk: firstMessage else: firstError
  return ToolResult(ok: allOk, payload: %*{"ok": allOk, "image_ids": imageIds, "count": results.elems.len, "results": results, "latency_ms": totalLatency}, receipt: "image:" & imageIds.elems.mapIt(it.getStr("")).join(","), message: message)

proc runDirectImageGeneration(tenantId: string, body: JsonNode): Future[JsonNode] {.async.} =
  if body.isNil or body.kind != JObject:
    raise newException(ValueError, "image generation body must be a JSON object")
  let policyText = body{"policy"}.getStr(body{"content_policy"}.getStr("")).strip()
  let directorText = body{"director_model"}.getStr("").strip()
  var policy: ImageContentPolicy
  if policyText.len > 0:
    policy = parseImageContentPolicy(policyText)
  elif directorText.len > 0:
    policy = policyFromDirectorModel(parseModelRole(directorText))
  else:
    raise newException(ValueError, "policy must be safe or adult")
  let directorRole = if directorText.len > 0: parseModelRole(directorText) else: directorModelForPolicy(policy)
  let taskId = body{"task_id"}.getStr("").strip()
  var handle: TaskHandle = nil
  if taskId.len > 0:
    handle = restoreTask(taskId)
    if handle.isNil or handle.tenantId != tenantId:
      raise newException(ValueError, "task_id does not belong to this tenant")
  var request = await imageRequestFromNode(tenantId, taskId, body, policy, false)
  request.directorModel = modelRoleName(directorRole)
  request.directorEnforced = false
  let outcome = await generateImageForRequest(handle, tenantId, taskId, request)
  if not outcome.ok:
    raise newException(IOError, outcome.message)
  let record = imageGenerationRecord(outcome.imageId)
  if record.isNil:
    raise newException(IOError, "image generation record disappeared")
  record

proc imageContextBudget(messages: JsonNode): int =
  let maxBytes = positiveEnvInt("AGENT_MAX_PROMPT_BYTES", 2 * 1024 * 1024)
  let hardCap = positiveEnvInt("IMAGE_CONTEXT_MAX_BYTES", 600_000)
  let remaining = maxBytes - canonical(messages).len - 32_768
  max(0, min(hardCap, remaining))

proc imageContextMessage(h: TaskHandle, role: ModelRole, budgetBytes: int): JsonNode =
  if h.isNil or role notin {mrGemini38, mrGrok43} or budgetBytes <= 0:
    return nil
  let maxImages = positiveEnvInt("IMAGE_CONTEXT_MAX_IMAGES", 2)
  let perImageCap = positiveEnvInt("IMAGE_CONTEXT_MAX_IMAGE_BYTES", 262_144)
  if maxImages <= 0 or perImageCap <= 0:
    return nil
  let rows = store.query("SELECT image_id, paths_json FROM image_generations WHERE task_id=? AND status='succeeded' ORDER BY created_at DESC LIMIT ?", @[%h.taskId, %maxImages])
  if rows.len == 0:
    return nil
  var parts = newJArray()
  var used = 0
  var attached = 0
  for row in rows:
    let imageId = row.getStr("image_id")
    let paths = row.getJson("paths_json", newJArray())
    if paths.kind != JArray or paths.elems.len == 0 or paths[0].kind != JObject:
      continue
    let entry = paths[0]
    let path = absolutePath(entry{"path"}.getStr(""))
    let bytes = entry{"bytes"}.getInt(0).int
    if path.len == 0 or not fileExists(path):
      continue
    if bytes <= 0 or bytes > perImageCap or used + bytes > budgetBytes:
      parts.add(%*{"type": "text", "text": "GENERATED IMAGE " & imageId & " (" & $bytes & " bytes) is stored at " & entry{"view_url"}.getStr("") & " and is too large to attach inline; load it with vm_upload_file or reference it as image:" & imageId})
      continue
    let data = readFile(path)
    let mime = if entry{"mime_type"}.getStr("").len > 0: entry{"mime_type"}.getStr("") else: imageMimeFromBytes(data)
    used += data.len
    inc attached
    parts.add(%*{"type": "text", "text": "GENERATED IMAGE " & imageId & " (" & mime & ", " & $data.len & " bytes) attached for pixel-level inspection:"})
    parts.add(%*{"type": "image_url", "mime_type": mime, "image_url": {"url": "data:" & mime & ";base64," & base64.encode(data)}})
  if parts.len == 0:
    return nil
  if attached > 0:
    parts.add(%*{"type": "text", "text": "Inspect these generated images against the requested prompt and report concrete visual defects before returning step_complete=true. Request a corrected generation through the image tools when a defect is visible."})
  else:
    parts.add(%*{"type": "text", "text": "The generated images listed above are stored as task artifacts; load them with the file or VM tools when pixel-level inspection is required, and reference them as image:<image_id> in the next generation call."})
  result = %*{"role": "user", "content": parts}
