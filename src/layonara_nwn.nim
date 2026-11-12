import std/[os, strformat, strutils, times, tables]
import docopt
import utils/[cli, shared, options, hakplan, compile]

const NimblePkgVersion {.strdefine.} = "dev"

const doc = """
layonara_nwn: a build tool for various Layonara NWN resources

Usage:
  layonara_nwn hak [options]

Options:
  --yes                Automatically answer yes to the overwrite prompt
  --no                 Automatically answer no to the overwrite prompt
  --default            Automatically accept the default answer to the overwrite prompt
  --out-dir DIR        Write the .hak files into DIR [default: .]

Compiling models:
  --compile            Compile every ASCII .mdl to binary with cleanmodels before
                       packing. The checkout is never written to.
  --cleanmodels PATH   cleanmodels executable (default: $CLEANMODELS, then the PATH)
  --game-dir DIR       NWN:EE install folder, the one holding data/nwn_base.key
                       (default: cleanmodels' own: $NWN_ROOT, then Steam and GOG)
  --cache-dir DIR      cleanmodels cache folder (default: layonara_nwn/cleanmodels
                       in the user cache folder)
  --hak-order FILE     The module's hak order: a .mod, a module.ifo.json or a text
                       file with one hak name a line (default: alphabetical)
  --stage-dir DIR      Staging folder; must be on the same volume as the checkout
                       [default: .hakstage]
  --workers N          cleanmodels workers [default: 2]
  --max-file-mb N      Fail when a compiled model is bigger than N MB [default: 20]
  --keep-stage         Keep the staging folder after a successful build

Global Options:
  --verbose     Also list every cleanmodels warning
  -h --help     Display help for layonara_nwn or one of its commands.
  -v --version  Display version information.
"""

proc skipExisting(root, outFile: string, spec: HakSpec): bool =
  ## The overwrite prompt: compares the newest file in the hak's repo folders
  ## with the existing hak.
  if not fileExists(outFile): return false
  let fileTime = newestFileTime(root, spec)
  let modTime = getLastModificationTime(outFile)
  if fileTime < modTime:
    let timeDiff = getTimeDiff(fileTime, modTime)
    let defaultAnswer = if timeDiff > 0: Yes else: No
    hint(getTimeDiffHint("The file to be packed", timeDiff))
    if not askIf(fmt"{outFile.extractFilename} already exists. Overwrite?", defaultAnswer):
      return true

proc shown(file, root: string): string =
  ## A path for messages: relative inside the checkout, absolute outside it.
  if file.startsWith(root & DirSep): file.relativePath(root) else: file

proc intArg(args: Table[string, Value], key: string): int =
  try:
    result = parseInt($args[key])
  except ValueError:
    fatal(&"{key} needs a number, not {args[key]}")

when isMainModule:
  discard getOptions()  # sets --yes / --no / --default
  let args = docopt(doc, version = "layonara_nwn " & NimblePkgVersion)

  if args["hak"]:
    let bin = findExe("nwn_erf")
    if bin.len == 0:
      fatal("nwn_erf not found on the PATH (it comes with neverwinter.nim)")
    let
      root = getCurrentDir()
      outDir = absolutePath($args["--out-dir"]).normalizedPath
      compileMode = args["--compile"].toBool
      stage = absolutePath($args["--stage-dir"]).normalizedPath
    createDir(outDir)
    let plan = hakPlan(root, exclude = [stage, outDir])

    if not compileMode:
      if args["--hak-order"]:
        warning("--hak-order only matters with --compile; ignored.")
      for spec in plan:
        if spec.folders.len == 0:
          warning(&"No tileset folders match {spec.name}; skipped.")
          continue
        let file = outDir / spec.name & ".hak"
        if skipExisting(root, file, spec): continue
        display(fmt"Packing files into {shown(file, root)}")
        var dirs: seq[string]
        for rel in spec.folders: dirs.add root / rel
        createLayoHak(dirs, shown(file, root), bin)
      quit(QuitSuccess)

    # --compile
    let cm = findCleanmodels(if args["--cleanmodels"]: $args["--cleanmodels"] else: "")
    var opts = CompileOptions(
      root: root,
      stage: stage,
      cleanmodels: cm,
      version: cleanmodelsVersion(cm),
      gameDir: if args["--game-dir"]: absolutePath($args["--game-dir"]) else: "",
      cacheDir: if args["--cache-dir"]: absolutePath($args["--cache-dir"])
                else: getCacheDir() / "layonara_nwn" / "cleanmodels",
      workers: max(1, intArg(args, "--workers")),
      maxFileBytes: intArg(args, "--max-file-mb").int64 * 1024 * 1024,
      keepStage: args["--keep-stage"].toBool)
    display("cleanmodels", &"{cm} (v{opts.version})")

    var order: seq[string]
    if args["--hak-order"]:
      try:
        order = readHakOrder($args["--hak-order"])
      except CatchableError as e:
        fatal(&"Could not read the hak order from {args[\"--hak-order\"]}: {e.msg}")
      display("Hak order", &"{order.len} haks from {args[\"--hak-order\"]}")
    else:
      warning("No --hak-order given: duplicate supermodels and materials are resolved in " &
              "alphabetical hak order, which may differ from the module's. " &
              "Pass --hak-order ../nwn-module/module.ifo.json.")
    let ranks = hakRanks(plan, order)

    prepareStage(stage, root)
    canary(opts)
    buildResFolders(opts, plan, ranks)
    clearStageDir(stage / "tree")
    clearStageDir(stage / "out")

    var stats: CompileStats
    var failures: seq[Failure]
    var failedHak = ""
    for spec in plan:
      if spec.folders.len == 0:
        warning(&"No tileset folders match {spec.name}; skipped.")
        continue
      let file = outDir / spec.name & ".hak"
      if skipExisting(root, file, spec): continue
      let dirs = stageHak(opts, spec, stats, failures)
      if failures.len > 0:
        failedHak = spec.name
        break
      display(fmt"Packing files into {shown(file, root)}")
      createLayoHak(dirs, shown(file, root), bin)
      if not opts.keepStage:
        clearStageDir(stage / "tree")
        clearStageDir(stage / "out")

    if failures.len > 0:
      for f in failures:
        error(&"{f.file}: {f.message}")
      error(&"{failures.len} models failed to compile; {failedHak}.hak was not written " &
            &"and the haks after it were not built. Staging kept in {stage}.")
      display("Summary:", summary(stats, failures.len))
      quit(QuitFailure)

    display("Summary:", summary(stats, 0))
    if opts.keepStage:
      display("Staging", &"kept in {stage} (res/winners.tsv lists which copy of each name won)")
    else:
      clearStageDir(stage)
