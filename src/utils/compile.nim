## `hak --compile`: pack the haks with every ASCII `.mdl` compiled to binary by
## cleanmodels, without ever writing into the checkout.
##
## Layout of the staging folder (default `<repo>/.hakstage`, which must sit on
## the same volume as the checkout so hard links work):
##
##   canary/            a tiny model compiled first to prove the game folder has real models
##   res/models/        every model, the copy from the highest-priority hak (cleanmodels
##                      looks supermodels and skeletons up here)
##   res/resources/     materials (.mtr) and capart.2da, likewise
##   res/winners.tsv    which copy of each name won, and which it shadowed
##   tree/<folder>/     hard links to the repo's files, with each ASCII .mdl
##                      replaced by its compiled copy; nwn_erf packs from here
##   out/<folder>/      cleanmodels' output (its .wok files are never used)
##
## Repo files are only ever read or hard-linked. A staged file is replaced by
## unlinking it first and linking the new one, never by writing through a link.

import std/[os, osproc, strutils, strformat, streams, json, tables, sets,
            algorithm, sequtils, options]
import neverwinter/[erf, gff, gffjson, resman, resref]
import cli, hakplan

const
  MinCleanmodels* = "4.18.1"
    ## Oldest cleanmodels accepted: the first that indexes each search folder
    ## once per process, so res/models can hold every winning .mdl (older ones
    ## list a big folder again on every lookup).
  PinnedCleanmodels* = "4.18.3"
    ## The version the builder image uses; any other version only warns.
  CleanmodelsReleases* = "https://github.com/plenarius/cleanmodels/releases"
  ChunkMaxFiles = 400
  ChunkMaxChars = 24_000
  StageMarker = ".layonara_nwn-stage"
  CanaryModel = """newmodel canary
setsupermodel canary a_ba
classification character
beginmodelgeom canary
node dummy canary
  parent NULL
endnode
endmodelgeom canary
donemodel canary
"""

type
  Version* = tuple[major, minor, patch: int]

  CompileOptions* = object
    root*: string           ## the checkout (absolute)
    stage*: string          ## staging folder (absolute)
    cleanmodels*: string    ## cleanmodels executable
    version*: Version
    gameDir*: string        ## "" = cleanmodels' default
    cacheDir*: string       ## "" = no cache
    workers*: int
    maxFileBytes*: int64
    keepStage*: bool

  Failure* = tuple[file, message: string]

  CompileStats* = object
    compiled*: int          ## ASCII models compiled (including cache hits)
    cached*: int            ## of those, taken from the cache
    passedThrough*: int     ## binary models packed unchanged
    warnings*: CountTable[string]

  Candidate = object
    path: string            ## relative to the root
    hak: string
    rank: int

# ----------------------------------------------------------------------------
# cleanmodels: finding it and its version

proc parseVersion*(s: string): Option[Version] =
  ## Reads `X.Y.Z` (optionally after a `v`) at the start of `s`.
  var s = s.strip
  if s.startsWith("v"): s = s[1..^1]
  let parts = s.split({'.', ' ', '-', '+'})
  if parts.len < 3: return
  try:
    result = some((parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2])))
  except ValueError:
    discard

proc `$`*(v: Version): string = &"{v.major}.{v.minor}.{v.patch}"

proc findCleanmodels*(flag: string): string =
  ## `--cleanmodels`, then `$CLEANMODELS`, then `cleanmodels` on the PATH.
  for (source, value) in [("--cleanmodels", flag), ("CLEANMODELS", getEnv("CLEANMODELS"))]:
    if value.len > 0:
      if fileExists(value): return value.absolutePath
      let found = findExe(value)
      if found.len > 0: return found
      fatal(&"cleanmodels not found at {value} (from {source})")
  result = findExe("cleanmodels")
  if result.len == 0:
    fatal("cleanmodels not found. Install it from " & CleanmodelsReleases &
          " (cleanmodels-<os>-<arch>.zip) and put it on the PATH, set CLEANMODELS, or pass --cleanmodels PATH.")

proc cleanmodelsVersion*(bin: string): Version =
  ## Runs `cleanmodels --version` (`cleanmodels v4.18.3 (revision …)`), refuses
  ## anything older than MinCleanmodels and warns when it isn't the pinned one.
  var output: string
  var code: int
  try:
    let p = startProcess(bin, args = ["--version"], options = {poStdErrToStdOut})
    output = p.outputStream.readAll
    code = p.waitForExit
    p.close
  except OSError as e:
    fatal(&"Could not run {bin}: {e.msg}")
  let words = output.splitWhitespace
  let v = if code == 0 and words.len >= 2 and words[0] == "cleanmodels": parseVersion(words[1])
          else: none(Version)
  if v.isNone:
    fatal(&"Could not read the version of {bin} (`--version` printed: {output.strip})")
  result = v.get
  if result < parseVersion(MinCleanmodels).get:
    fatal(&"{bin} is cleanmodels {result}; this build needs {MinCleanmodels} or newer: {CleanmodelsReleases}")
  if result != parseVersion(PinnedCleanmodels).get:
    warning(&"{bin} is cleanmodels {result}, not {PinnedCleanmodels} as the server build uses; " &
            "compiled models may differ from the published haks.")

# ----------------------------------------------------------------------------
# Hak order

proc hakListFromIfoJson(j: JsonNode, source: string): seq[string] =
  let list = j{"Mod_HakList", "value"}
  if list.isNil or list.kind != JArray:
    raise newException(ValueError, source & " has no Mod_HakList")
  for entry in list:
    let name = entry{"Mod_Hak", "value"}
    if not name.isNil and name.kind == JString and name.getStr.len > 0:
      result.add name.getStr.toLowerAscii

proc normaliseHakName(s: string): string =
  result = s.strip.toLowerAscii
  if result.endsWith(".hak"): result.setLen(result.len - 4)

proc readHakOrder*(path: string): seq[string] =
  ## The module's hak list, highest priority first. `path` is a `.mod`, a
  ## `module.ifo` (GFF), a nasher `module.ifo.json`, or a text file with one
  ## hak name a line (blank lines and `#` comments ignored).
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".mod":
    let s = openFileStream(path)
    defer: s.close
    let mo = s.readErf(path)
    let ifo = mo[newResolvedResRef("module.ifo")]
    if ifo.isNone:
      raise newException(ValueError, path & " has no module.ifo")
    let gffRoot = readGffRoot(newStringStream(ifo.get.readAll), false)
    result = hakListFromIfoJson(gffRoot.toJson, path)
  of ".ifo":
    let s = openFileStream(path)
    defer: s.close
    result = hakListFromIfoJson(readGffRoot(s, false).toJson, path)
  of ".json":
    result = hakListFromIfoJson(parseFile(path), path)
  else:
    for line in lines(path):
      let name = line.strip
      if name.len == 0 or name.startsWith("#"): continue
      result.add normaliseHakName(name)

proc hakRanks*(plan: seq[HakSpec], order: seq[string]): Table[string, int] =
  ## Rank of every planned hak (0 = highest priority): its position in
  ## `order`, then the haks `order` doesn't list, alphabetically.
  var unlisted: seq[string]
  for i, name in order:
    if name notin result: result[name] = i
  for spec in plan:
    if spec.name notin result: unlisted.add spec.name
  unlisted.sort
  for i, name in unlisted:
    result[name] = order.len + i

# ----------------------------------------------------------------------------
# Model inspection

proc isBinaryMdl*(path: string): bool =
  ## Binary models start with four zero bytes.
  var f: File
  if not f.open(path): return false
  defer: f.close
  var head: array[4, uint8]
  result = f.readBytes(head, 0, 4) == 4 and head == [0'u8, 0, 0, 0]

proc isMdl(name: string): bool = name.toLowerAscii.endsWith(".mdl")

proc skeletonOf(fileName: string): string =
  ## Skinned body parts (`pmh0_chest001`, `pfe2_head010`) use the skeleton named
  ## by their first four characters.
  let n = fileName.toLowerAscii
  if n.len > 5 and n[0] == 'p' and n[1] in {'m', 'f'} and n[2] in {'a'..'z'} and
     n[3] in {'0'..'9'} and n[4] == '_':
    result = n[0..3]

proc supersOf*(path: string): HashSet[string] =
  ## Supermodel and skeleton names `path` can look up (lower case).
  var f: File
  if not f.open(path): return
  defer: f.close
  var head: array[4, uint8]
  if f.readBytes(head, 0, 4) == 4 and head == [0'u8, 0, 0, 0]:
    # Binary: the supermodel name is 64 bytes at offset 180.
    var buf: array[64, char]
    f.setFilePos(180)
    let n = f.readChars(buf)
    var name = ""
    for i in 0 ..< n:
      if buf[i] == '\0': break
      name.add buf[i]
    name = name.strip.toLowerAscii
    if name.len > 0 and name != "null": result.incl name
  else:
    f.setFilePos(0)
    var line: string
    var count = 0
    while count < 5000 and f.readLine(line):
      inc count
      let words = line.splitWhitespace
      if words.len == 0: continue
      let key = words[0].toLowerAscii
      if key == "beginmodelgeom": break
      if key == "setsupermodel" and words.len >= 3:
        let name = words[2].toLowerAscii
        if name != "null": result.incl name
  let skel = skeletonOf(path.extractFilename)
  if skel.len > 0: result.incl skel

proc renderHint(path: string): string =
  ## The `renderhint` of a material, lower case ("" when it has none). It is
  ## the only thing a compile reads from a material.
  for line in lines(path):
    let words = line.splitWhitespace
    if words.len >= 2 and words[0].toLowerAscii == "renderhint":
      return words[1].toLowerAscii

# ----------------------------------------------------------------------------
# Staging helpers

var copyWarned = false

proc removeEntry(path: string) =
  ## Unlinks `path` (a file or a link) if it exists; never follows it.
  if symlinkExists(path) or fileExists(path):
    removeFile(path)

proc linkOrCopy*(src, dst: string) =
  ## Hard-links `src` at `dst`, or copies it when the volume can't link. Any
  ## existing `dst` is unlinked first, so nothing is written through a link.
  removeEntry(dst)
  if not symlinkExists(src):
    try:
      createHardlink(src, dst)
      return
    except OSError as e:
      if not copyWarned:
        warning(&"Can't hard-link into {dst.parentDir} ({e.msg.strip}); copying instead. " &
                "Put --stage-dir on the same volume as the checkout to avoid the copies.")
        copyWarned = true
      removeEntry(dst)
  copyFile(src, dst)

proc prepareStage*(stage, root: string) =
  ## Creates the staging folder, or checks that an existing one is ours.
  let stageN = stage.normalizedPath
  let rootN = root.normalizedPath
  if rootN == stageN or rootN.startsWith(stageN & DirSep):
    fatal(&"The staging folder {stage} can't be the checkout or a folder above it.")
  if dirExists(stage):
    var empty = true
    for _ in walkDir(stage):
      empty = false
      break
    if not empty and not fileExists(stage / StageMarker):
      fatal(&"{stage} exists and isn't a layonara_nwn staging folder; refusing to use it.")
  createDir(stage)
  writeFile(stage / StageMarker, "Staging folder of layonara_nwn hak --compile; safe to delete.\n")

proc clearStageDir*(dir: string) =
  ## Removes a staging subfolder. removeDir unlinks links, it never follows them.
  if dirExists(dir): removeDir(dir)

# ----------------------------------------------------------------------------
# Running cleanmodels

proc warningKind(message: string): string =
  let m = message.toLowerAscii
  if "supermodel" in m: "supermodel"
  elif "skeleton" in m: "skeleton"
  elif "capart" in m: "capart.2da"
  elif "material" in m or ".mtr" in m: "material"
  else: "other"

proc baseArgs(opts: CompileOptions): seq[string] =
  result = @["compile", "--json-lines", "--overwrite", "--color", "never"]
  if opts.gameDir.len > 0: result.add ["--game-dir", opts.gameDir]

proc runCleanmodels(bin: string, args: seq[string], inputs: seq[string],
                    stats: var CompileStats, failures: var seq[Failure],
                    okInputs: var HashSet[string], warningsOut: var seq[Failure]) =
  ## Runs one cleanmodels batch and reads its `--json-lines` events.
  var other: seq[string]
  var failed = initHashSet[string]()
  let p = startProcess(bin, args = args, options = {poStdErrToStdOut})
  for line in p.lines:
    if not line.startsWith("{"):
      if line.strip.len > 0: other.add line
      continue
    var ev: JsonNode
    try: ev = parseJson(line)
    except JsonParsingError:
      other.add line
      continue
    # The event's "file" is the base name; "index" (1-based, absent when there
    # is one input) and result.file give the input as passed.
    var file = ev{"result", "file"}.getStr
    if file.len == 0:
      let idx = ev{"index"}.getInt(0)
      if idx >= 1 and idx <= inputs.len: file = inputs[idx - 1]
      elif inputs.len == 1: file = inputs[0]
      else:
        file = ev{"file"}.getStr
        for input in inputs:
          if input.extractFilename == file:
            file = input
            break
    case ev{"type"}.getStr
    of "error":
      failures.add (file, ev{"message"}.getStr("error"))
      failed.incl file
    of "done":
      let r = ev{"result"}
      if r.isNil:
        continue
      if r{"error"} != nil and r{"error"}.getStr.len > 0:
        failures.add (file, r{"error"}.getStr)
        failed.incl file
        continue
      inc stats.compiled
      if r{"cached"}.getBool(false): inc stats.cached
      for w in r{"warnings"}.getElems:
        let msg = w{"message"}.getStr
        stats.warnings.inc warningKind(msg)
        warningsOut.add (file, msg)
      for w in r{"parse_warnings"}.getElems:
        stats.warnings.inc "parse"
        warningsOut.add (file, w.getStr)
      okInputs.incl file
    else: discard
  let code = p.waitForExit
  p.close
  for input in inputs:
    if input notin okInputs and input notin failed:
      let tail = other[max(0, other.len - 5) .. ^1].join("\n")
      failures.add (input, &"no result from cleanmodels (exit status {code}){(if tail.len > 0: \": \" & tail else: \"\")}")
      failed.incl input
  if code != 0 and failed.len == 0:
    failures.add (inputs.join(", "), &"cleanmodels exited with status {code}: {other.join(\"\\n\")}")

proc chunks(files: seq[string]): seq[seq[string]] =
  ## Splits the inputs so each command line stays well under Windows' 32,767
  ## characters and Linux' ARG_MAX.
  var cur: seq[string]
  var chars = 0
  for f in files:
    if cur.len > 0 and (cur.len >= ChunkMaxFiles or chars + f.len + 3 > ChunkMaxChars):
      result.add cur
      cur = @[]
      chars = 0
    cur.add f
    chars += f.len + 3
  if cur.len > 0: result.add cur

proc canary*(opts: CompileOptions) =
  ## Compiles a model whose supermodel (`a_ba`) only the game has. A missing
  ## or empty game folder makes cleanmodels warn instead of fail, so stop here.
  let dir = opts.stage / "canary"
  clearStageDir(dir)
  createDir(dir / "out")
  let model = dir / "canary.mdl"
  writeFile(model, CanaryModel)
  var stats: CompileStats
  var failures: seq[Failure]
  var ok = initHashSet[string]()
  var warnings: seq[Failure]
  runCleanmodels(opts.cleanmodels, baseArgs(opts) & @[model, dir / "out" & "/"], @[model],
                 stats, failures, ok, warnings)
  let where = if opts.gameDir.len > 0: opts.gameDir else: "cleanmodels' default game folder ($NWN_ROOT, Steam, GOG)"
  for f in failures:
    fatal(&"The canary compile failed: {f.message}")
  for w in warnings:
    if "supermodel" in w.message.toLowerAscii:
      fatal(&"The game folder has no real models ({where}): the canary's stock supermodel a_ba " &
            &"could not be read: {w.message}\nPass --game-dir with a full NWN:EE install.")
  clearStageDir(dir)

proc compileFolder*(opts: CompileOptions, inputs: seq[string], outDir: string,
                    stats: var CompileStats, failures: var seq[Failure]): HashSet[string] =
  ## Compiles `inputs` (absolute repo paths, all in one folder) into `outDir`.
  ## Returns the inputs that compiled.
  createDir(outDir)
  var args = baseArgs(opts) & @["--workers", $opts.workers,
    "--supermodel-dir", opts.stage / "res" / "models",
    "--resource-dir", opts.stage / "res" / "resources"]
  if opts.cacheDir.len > 0: args.add ["--cache-dir", opts.cacheDir]
  var warnings: seq[Failure]
  for chunk in chunks(inputs):
    runCleanmodels(opts.cleanmodels, args & chunk & @[outDir & "/"], chunk,
                   stats, failures, result, warnings)
  for w in warnings:
    info("Warning:", &"{w.file.extractFilename}: {w.message}")

# ----------------------------------------------------------------------------
# Resource folders

proc buildResFolders*(opts: CompileOptions, plan: seq[HakSpec], ranks: Table[string, int]) =
  ## Links the copy of each model, material and capart.2da from the
  ## highest-priority hak into res/, writes res/winners.tsv, and warns when
  ## a model would pick up a different, losing copy from its own folder.
  let res = opts.stage / "res"
  clearStageDir(res)
  createDir(res / "models")
  createDir(res / "resources")

  var cands = initTable[(string, string), seq[Candidate]]()
  var asciiByFolder = initTable[string, seq[string]]()  # folder rel -> ASCII model paths (rel)
  for spec in plan:
    for rel in spec.folders:
      for kind, path in walkDir(opts.root / rel, relative = true):
        if kind notin {pcFile, pcLinkToFile}: continue
        let lower = path.toLowerAscii
        let (_, base, ext) = lower.splitFile
        let key =
          if ext == ".mdl": (base, "mdl")
          elif ext == ".mtr": (base, "mtr")
          elif lower == "capart.2da": (base, "2da")
          else: ("", "")
        if key[0].len == 0: continue
        let relPath = rel / path
        cands.mgetOrPut(key, @[]).add Candidate(path: relPath, hak: spec.name, rank: ranks[spec.name])
        if key[1] == "mdl" and not isBinaryMdl(opts.root / relPath):
          asciiByFolder.mgetOrPut(rel, @[]).add relPath

  for key, list in cands.mpairs:
    list.sort(proc (a, b: Candidate): int =
      result = cmp(a.rank, b.rank)
      if result == 0: result = cmp(a.path, b.path))

  var tsv = open(res / "winners.tsv", fmWrite)
  defer: tsv.close
  tsv.writeLine("name\text\tchosen\tshadowed")
  var nModels, nResources = 0
  var folderSupers = initTable[string, HashSet[string]]()
  var keys = toSeq(cands.keys)
  keys.sort
  for key in keys:
    let list = cands[key]
    let (name, ext) = key
    let winner = list[0]
    let dest = if ext == "mdl": res / "models" / name & ".mdl"
               elif ext == "mtr": res / "resources" / name & ".mtr"
               else: res / "resources" / "capart.2da"
    linkOrCopy(opts.root / winner.path, dest)
    if ext == "mdl": inc nModels else: inc nResources
    tsv.writeLine(&"{name}\t{ext}\t{winner.path}\t" & list[1..^1].mapIt(it.path).join(";"))

    # A losing copy that differs, in a folder that gets compiled, and that a
    # model there would look up: cleanmodels searches the own folder first.
    for loser in list[1..^1]:
      let folder = loser.path.parentDir
      if folder == winner.path.parentDir or folder notin asciiByFolder: continue
      let differs =
        if ext == "mtr": renderHint(opts.root / loser.path) != renderHint(opts.root / winner.path)
        else: getFileSize(opts.root / loser.path) != getFileSize(opts.root / winner.path) or
              readFile(opts.root / loser.path) != readFile(opts.root / winner.path)
      if not differs: continue
      var used = true
      if ext == "mdl":
        if folder notin folderSupers:
          var s: HashSet[string]
          for p in asciiByFolder[folder]: s.incl supersOf(opts.root / p)
          folderSupers[folder] = s
        used = name in folderSupers[folder]
      if used:
        warning(&"{loser.path} ({loser.hak}) differs from {winner.path} ({winner.hak}), which wins in " &
                &"the hak order, but models in {folder} will use their own copy when they compile.")
  display("Resources:", &"{nModels} models, {nResources} materials and capart.2da linked into {res}")

# ----------------------------------------------------------------------------
# Staging and compiling one hak

proc stageHak*(opts: CompileOptions, spec: HakSpec, stats: var CompileStats,
               failures: var seq[Failure]): seq[string] =
  ## Stages the hak's folders under tree/, compiling the ASCII models into
  ## out/ and linking the results in. Returns the staged folders to pack, in
  ## the order of `spec.folders`. Check `failures` before packing.
  let failuresBefore = failures.len
  for rel in spec.folders:
    let src = opts.root / rel
    let dst = opts.stage / "tree" / rel
    let outDir = opts.stage / "out" / rel
    createDir(dst)
    result.add dst
    var ascii: seq[string]
    for kind, path in walkDir(src):
      if kind notin {pcFile, pcLinkToFile}: continue
      let name = path.extractFilename
      if name.isMdl and tryNewResolvedResRef(name).isSome and not isBinaryMdl(path):
        ascii.add path
        continue
      if name.isMdl and isBinaryMdl(path): inc stats.passedThrough
      linkOrCopy(path, dst / name)
    if ascii.len == 0: continue
    ascii.sort
    display("Compiling", &"{ascii.len} models in {rel}")
    let compiledBefore = stats.compiled
    let cachedBefore = stats.cached
    let ok = compileFolder(opts, ascii, outDir, stats, failures)
    for input in ascii:
      if input notin ok: continue
      let name = input.extractFilename
      let compiled = outDir / name
      if not fileExists(compiled):
        failures.add (input, "cleanmodels reported success but wrote no " & compiled)
        continue
      let size = getFileSize(compiled)
      if size > opts.maxFileBytes:
        failures.add (input, &"compiled model is {size.float / 1048576.0:.1f} MB, over the " &
                             &"{opts.maxFileBytes div 1048576} MB limit")
        continue
      linkOrCopy(compiled, dst / name)
    info("Compiled:", &"{rel}: {stats.compiled - compiledBefore} models, " &
         &"{stats.cached - cachedBefore} from the cache")
  if failures.len > failuresBefore:
    result = @[]

proc summary*(stats: CompileStats, failures: int): string =
  var warns: seq[string]
  var kinds = toSeq(stats.warnings.keys)
  kinds.sort
  for k in kinds: warns.add &"{k} {stats.warnings[k]}"
  result = &"{stats.compiled} models compiled ({stats.cached} from the cache), " &
           &"{stats.passedThrough} binary models passed through, {failures} failed; warnings: " &
           (if warns.len > 0: warns.join(", ") else: "none")
