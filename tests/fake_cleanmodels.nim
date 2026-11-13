## A stand-in for cleanmodels, so the tests need no game and no real compiler.
##
## `--version` prints `cleanmodels v$FAKE_CM_VERSION` (default 4.18.3, the pinned version).
## `compile [flags] <input>... <outdir>/` streams `--json-lines` events like
## cleanmodels does and writes, for each input, `<outdir>/<name>`:
##
##   4 zero bytes, "FAKE <name>\n", "super=<first line of the supermodel used>\n",
##   then the input's bytes
##
## The supermodel is looked up like cleanmodels does: the input's own folder,
## then each --supermodel-dir, each --resource-dir, then `<game-dir>/models`
## (a 0-byte file there counts as unreadable, like the 0-byte stock models).
## An input whose name starts with `broken` gets an `error` event. An input
## holding `node aabb` also gets a `<outdir>/<base>.wok` saying FAKE WOK.
## Each run appends a line to $FAKE_CM_LOG (`<number of inputs>`) if set, and
## sleeps $FAKE_CM_SLEEP seconds per input if set.

import std/[os, strutils, json, strformat]

proc findSuper(name: string, dirs: seq[string]): (string, bool) =
  ## (path, readable)
  for d in dirs:
    for kind, path in walkDir(d):
      if kind in {pcFile, pcLinkToFile} and path.extractFilename.toLowerAscii == name & ".mdl":
        return (path, getFileSize(path) > 0)
  return ("", false)

proc main() =
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--version":
    echo "cleanmodels v" & getEnv("FAKE_CM_VERSION", "4.18.3") & " (revision fake)"
    quit 0
  if args.len == 0 or args[0] != "compile":
    quit("fake cleanmodels: unsupported arguments: " & args.join(" "), 2)

  var supers, resources, positional: seq[string]
  var gameDir = ""
  var i = 1
  while i < args.len:
    let a = args[i]
    case a
    of "--json-lines", "--overwrite": discard
    of "--workers", "--cache-dir", "--color":
      inc i
    of "--game-dir":
      inc i
      gameDir = args[i]
    of "--supermodel-dir":
      inc i
      supers.add args[i]
    of "--resource-dir":
      inc i
      resources.add args[i]
    else:
      if a.startsWith("-"): quit("fake cleanmodels: unknown flag " & a, 2)
      positional.add a
    inc i
  if positional.len < 2: quit("fake cleanmodels: need inputs and an output folder", 2)
  let outDir = positional[^1]
  let inputs = positional[0 ..< ^1]
  if not outDir.endsWith("/") and not dirExists(outDir):
    quit("fake cleanmodels: output must be a folder", 2)
  let log = getEnv("FAKE_CM_LOG")
  if log.len > 0:
    let f = open(log, fmAppend)
    f.writeLine($inputs.len)
    f.close
  let sleepSecs = parseFloat(getEnv("FAKE_CM_SLEEP", "0"))

  var errors = 0
  for idx, input in inputs:
    let name = input.extractFilename
    let n = idx + 1
    echo $(%*{"type": "start", "file": name, "index": n, "total": inputs.len})
    if sleepSecs > 0: sleep(int(sleepSecs * 1000))
    if name.toLowerAscii.startsWith("broken"):
      inc errors
      echo $(%*{"type": "error", "file": name, "index": n, "total": inputs.len,
                "message": "fake parse error"})
      continue
    let data = readFile(input)
    var superName = ""
    for line in data.splitLines:
      let w = line.splitWhitespace
      if w.len >= 3 and w[0].toLowerAscii == "setsupermodel":
        superName = w[2].toLowerAscii
    var warnings = newJArray()
    var superLine = ""
    if superName.len > 0 and superName != "null":
      var dirs = @[input.parentDir] & supers & resources
      if gameDir.len > 0: dirs.add gameDir / "models"
      let (path, readable) = findSuper(superName, dirs)
      if readable:
        superLine = readFile(path).splitLines[0]
      else:
        warnings.add %*{"kind": 4, "offset": 0,
          "message": &"supermodel \"{superName}\" could not be read; node numbers assume no supermodel"}
    writeFile(outDir / name, "\0\0\0\0" & "FAKE " & name & "\nsuper=" & superLine & "\n" & data)
    if "node aabb" in data:
      writeFile(outDir / name.changeFileExt("wok"), "FAKE WOK\n")
    var res = %*{"file": input, "actions": [&"compiled to binary: {outDir / name}"]}
    if warnings.len > 0: res["warnings"] = warnings
    var ev = %*{"type": "done", "file": name, "result": res}
    if inputs.len > 1:
      ev["index"] = %n
      ev["total"] = %inputs.len
    echo $ev
  if inputs.len > 1:
    echo $(%*{"type": "summary", "total": inputs.len,
              "message": &"Processed {inputs.len} files, 0 warnings, {errors} errors"})
  quit(if errors > 0: 1 else: 0)

main()
