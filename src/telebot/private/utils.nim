import macros, httpclient, asyncdispatch, json, strutils, types, options, logging, strtabs, random
from streams import Stream, readAll
from parseutils import parseUntil

randomize()

const
  API_URL = "$#/bot$#/$#"
  #FILE_PATH = "file/bot$#/$#"

template procName*: string =
  when not declaredInScope(internalProcName):
    var internalProcName {.exportc, inject.}: cstring
    {.emit: "`internalProcName` = __func__;".}
    var realProcName {.inject.}: string
    discard parseUntil($internalProcName, realProcName, "Iter_")
  realProcName

template hasCommand*(update: Update, username: string): bool =
  var
    result = false
    hasMessage = false
  when not declaredInScope(command):
    var
      command {.inject.} = ""
      params {.inject.} = ""
      message {.inject.}: Message
  if update.message.isSome:
    hasMessage = true
    message = update.message.get()
  elif update.editedMessage.isSome:
    hasMessage = true
    message = update.editedMessage.get()
  else:
    result = false

  if hasMessage and message.entities.isSome:
    let
      entities = message.entities.get()
      messageText = message.text.get()
    if entities[0].kind == "bot_command" and entities[0].offset == 0:
      let
        offset = entities[0].offset
        length = entities[0].length
      command = messageText[(offset + 1)..<(offset + length)].strip()
      params = messageText[(offset + length)..^1].strip()
      result = true
      if '@' in command:
        var parts = command.split('@')
        command = parts[0]
        if (parts.len == 2 and parts[1].toLowerAscii != username):
          result = false
  result

proc isSet*(value: auto): bool {.inline.} =
  when value is string:
    result = value.len > 0
  elif value is int:
    result = value != 0
  elif value is bool:
    result = value
  elif value is object:
    result = true
  elif value is float:
    result = value != 0
  elif value is enum:
      result = true
  else:
    result = not value.isNil

template d*(args: varargs[string, `$`]) =
  debug(args)

proc formatName*(s: string): string =
  if s == "kind":
    return "type"
  if s == "fromUser":
    return "from"

  # optimize: dont alloc new string if not needed
  var hasUpperChar = false
  for i in 0..<s.len:
    if s[i] in {'A'..'Z'}:
      hasUpperChar = true
      break

  if hasUpperChar:
    result = newStringOfCap(s.len + 5)
    for c in s:
      if c in {'A'..'Z'}:
        result.add("_")
        result.add(c.toLowerAscii)
      else:
        result.add(c)
  else:
    return s

proc put*[T](s: var seq[T], n: JsonNode) {.inline.}

proc unmarshal*(n: JsonNode, T: typedesc): T =
  when T is TelegramObject:
    for name, value in result.fieldPairs:
      when not value.hasCustomPragma(telebotInternalUse):
        let jsonKey = formatName(name)
        when value.type is Option:
          if n.hasKey(jsonKey):
            toOption(value, n[jsonKey])
        else:
          value = unmarshal(n[jsonKey], value.type)
  elif result is ref:
    if n.kind != JNull:
      new(result)
      result[] = unmarshal(n, result[].type)
  elif result is array or result is seq:
    when result is seq:
      newSeq(result, n.len)
    for i in 0..<n.len:
      result[i] = unmarshal(n[i], result[0].type)
  elif result is SomeInteger:
    result = cast[result.type](n.getInt)
  elif result is SomeFloat:
    result = n.getFloat
  elif result is string:
    result = n.getStr
  elif result is bool:
    result = n.getBool
  elif result is char:
    result = n.getStr()[0]
  elif result is enum:
    let value = n.getStr
    for e in low(result.type)..high(result.type):
      if $e == value:
        result = e


proc marshal*[T](t: T, s: var string) =
  when t is Option:
    if t.isSome:
      marshal(t.get, s)
  elif t is object:
    s.add "{"
    for name, value in t.fieldPairs:
      when not value.hasCustomPragma(telebotInternalUse):
        let jsonKey = formatName(name)
        when value is Option:
          if value.isSome:
            s.add("\"" & jsonKey & "\":")
            marshal(value, s)
            s.add(',')
        else:
          s.add("\"" & jsonKey & "\":")
          marshal(value, s)
          s.add(',')
    s.removeSuffix(',')
    s.add "}"
  elif t is ref:
    marshal(t[], s)
  elif t is seq or t is openarray:
    s.add "["
    for item in t:
      marshal(item, s)
      s.add(',')
    s.removeSuffix(',')
    s.add "]"
  else:
    if t.isSet:
      when t is string:
        s.add(escapeJson(t))
      else:
        s.add($t)
    else:
      when t is bool:
        s.add("false")
      else:
        s.add("null")

proc put*[T](s: var seq[T], n: JsonNode) {.inline.} =
  s.add(unmarshal(n, T))

proc toOption*[T](o: var Option[T], n: JsonNode) {.inline.} =
  o = some(unmarshal(n, T))

proc makeRequest*(b: Telebot, `method`: string, data: MultipartData = nil): Future[JsonNode] {.async.} =
  let endpoint = API_URL % [b.serverUrl, b.token, `method`]
  d("Making request to ", endpoint)
  let client = newAsyncHttpClient(userAgent="telebot.nim/1.1.0 Nim/" & NimVersion, proxy=b.proxy)
  defer: client.close()
  let r = await client.post(endpoint, multipart=data)
  if r.code == Http200 or r.code == Http400:
    let body = await r.body
    var obj: JsonNode
    try:
      obj = parseJson(body)
    except:
      raise newException(ValueError, "Parse JSON error: " & getCurrentExceptionMsg() & "\n" & body)

    if obj.hasKey("ok") and obj["ok"].getBool:
      result = obj["result"]
      d("Result: ", $result)
    else:
      raise newException(IOError, obj["description"].getStr)
  else:
    raise newException(IOError, r.status)

proc getMessage*(n: JsonNode): Message {.inline.} =
  result = unmarshal(n, Message)

proc addData*(p: var MultipartData, name: string, content: auto, fileCheck = false) {.inline.} =
  when content is string:
    if fileCheck and content.startsWith("file://"):
      p.addFiles({name: content[7..content.len-1]})
    else:
      p.add(name, content)
  else:
    p.add(name, $content)

proc addData*(p: var MultipartData, name: string, content: Stream, fileName = "", contentType = "") {.inline.} =
  p.add(name, content.readAll(), fileName, contentType)

proc uploadInputMedia*(p: var MultipartData, m: InputMedia) =
  var name = "file_upload_" & $rand(high(int))
  if m.media.startsWith("file://"):
    p.addFiles({name: m.media[7..<m.media.len]})
    m.media = "attach://" & name

  if m.thumb.isSome:
    let thumb = m.thumb.get()
    if thumb.startsWith("file://"):
      name = "file_upload_" & $rand(high(int))
      p.addFiles({name: thumb[7..<thumb.len]})
      m.thumb = some("attach://" & name)

macro genInputMedia*(mediaType: untyped): untyped =
  let
    media = "InputMedia" & $mediaType
    kind = toLowerAscii($mediaType)
    objName = newIdentNode(media)
    funcName = newIdentNode("new" & media)

  result = quote do:
    proc `funcName`*(media: string; caption=""; parseMode=""): `objName` =
      var inputMedia = new(`objName`)
      inputMedia.kind = `kind`
      inputMedia.media = media
      if caption.len > 0:
        inputMedia.caption = some(caption)
      if parseMode.len > 0:
        inputMedia.parseMode = some(parseMode)
      return inputMedia
