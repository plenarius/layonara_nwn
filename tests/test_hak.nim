## Tests for `layonara_nwn hak`, with and without `--compile`.
##
## They build layonara_nwn and a fake cleanmodels (tests/fake_cleanmodels.nim)
## into tests/work/bin, make a small checkout under tests/work, and run the
## real binary on it. No game and no real cleanmodels are needed. nwn_erf is
## taken from the PATH, or built from the neverwinter package when missing.

import std/[unittest, os, osproc, strutils, sequtils, tables, sets, streams,
            algorithm, compilesettings, options, json, times]
import neverwinter/[erf, resman, resref, gff]
import ../src/utils/[hakplan, compile]

const
  searchPaths = querySettingSeq(MultipleValueSetting.searchPaths)
  nimExe = getCurrentCompilerExe()

let
  here = currentSourcePath.parentDir
  repoRoot = here.parentDir
  work = here / "work"
  binDir = work / "bin"
  layoBin = binDir / "layonara_nwn".addFileExt(ExeExt)
  fakeCm = binDir / "cleanmodels".addFileExt(ExeExt)

proc nimc(src, output: string) =
  var args = @["c", "--hints:off", "--warnings:off", "-d:release", "-d:NimblePkgVersion=test",
               "--nimcache:" & work / "nimcache" / output.extractFilename]
  for p in searchPaths: args.add "--path:" & p
  args.add ["-o:" & output, src]
  let (output, code) = execCmdEx(quoteShellCommand(@[nimExe] & args))
  doAssert code == 0, "building " & src & " failed:\n" & output

proc setupBinaries() =
  createDir(binDir)
  nimc(repoRoot / "src" / "layonara_nwn.nim", layoBin)
  nimc(here / "fake_cleanmodels.nim", fakeCm)
  if findExe("nwn_erf").len == 0:
    var src = ""
    for p in searchPaths:
      if fileExists(p / "nwn_erf.nim"): src = p / "nwn_erf.nim"
    doAssert src.len > 0, "nwn_erf is not on the PATH and its source isn't in the search paths"
    nimc(src, binDir / "nwn_erf".addFileExt(ExeExt))
  putEnv("PATH", binDir & PathSep & getEnv("PATH"))

# ----------------------------------------------------------------------------
# Fixture

const
  superA = "# sup1 from a\nnewmodel sup1\nbeginmodelgeom sup1\nendmodelgeom sup1\ndonemodel sup1\n"
  superB = "# sup1 from b\nnewmodel sup1\nbeginmodelgeom sup1\nendmodelgeom sup1\ndonemodel sup1\n"
  binaryStub = "\0\0\0\0binary model stub"
  repoWok = "REPO WOK\n"

proc model(name, super: string, extra = ""): string =
  "newmodel " & name & "\n" &
    (if super.len > 0: "setsupermodel " & name & " " & super & "\n" else: "") &
    "beginmodelgeom " & name & "\n" & extra & "endmodelgeom " & name & "\ndonemodel " & name & "\n"

proc put(root, rel, content: string) =
  createDir((root / rel).parentDir)
  writeFile(root / rel, content)

proc makeFixture(root: string) =
  removeDir(root)
  createDir(root)
  root.put("doors/door01.mdl", model("door01", ""))
  root.put("doors/door01.utd", "UTD stub")
  root.put("a/sup1.mdl", superA)
  root.put("a/m_a.mdl", model("m_a", "sup1"))
  root.put("b/sup1.mdl", superB)
  root.put("b/m_b.mdl", model("m_b", "sup1"))
  root.put("c/m_c.mdl", model("m_c", "sup1"))
  root.put("c/bin01.mdl", binaryStub)
  root.put("c/m_c.mtr", "renderhint NormalAndSpecMapped\n")
  root.put("t/tile01.mdl", model("tile01", "", "node aabb tile01\nendnode\n"))
  root.put("t/tile01.wok", repoWok)
  root.put("parts/male/elf/pme0_chest001.mdl", model("pme0_chest001", ""))
  root.put("parts/female/elf/pfe0_head001.mdl", model("pfe0_head001", ""))
  root.put("tilesets/tno01/tno01_a01_01.mdl", model("tno01_a01_01", ""))
  root.put("tilesets/tno01/tno01.set", "[GENERAL]\n")
  root.put("tilesets/mst01/mst01_a01_01.mdl", model("mst01_a01_01", ""))
  root.put("vendor/x/v.mdl", model("v", ""))
  root.put(".hidden/h.mdl", model("h", ""))
  root.put("my stuff/thing.2da", "2DA V2.0\n")
  root.put("\"quoted/q.2da", "2DA V2.0\n")
  createDir(root / "empty")

proc makeGame(dir: string, real: bool) =
  removeDir(dir)
  dir.put("data/nwn_base.key", "KEY stub")
  dir.put("models/a_ba.mdl", if real: "# stock a_ba\nnewmodel a_ba\n" else: "")

type Snap = Table[string, tuple[size: int64, inode: int64, links: int, data: string]]

proc snapshot(root: string): Snap =
  for path in walkDirRec(root, relative = true, skipSpecial = true):
    if path.startsWith(".hakstage"): continue
    let info = getFileInfo(root / path, followSymlink = false)
    result[path] = (info.size, info.id.file.int64, info.linkCount.int, readFile(root / path))

proc readHak(path: string): Table[string, string] =
  let s = openFileStream(path)
  defer: s.close
  let e = s.readErf(path)
  for rr in e.contents:
    result[rr.resolve.get.toFile] = e.demand(rr).readAll

proc run(root: string, args: seq[string], env: openArray[(string, string)] = []): (string, int) =
  for (k, v) in env: putEnv(k, v)
  defer:
    for (k, _) in env: delEnv(k)
  let p = startProcess(layoBin, workingDir = root, args = args,
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll
  result = (output, p.waitForExit)
  p.close

proc compileArgs(outDir, game, order: string): seq[string] =
  @["hak", "--yes", "--compile", "--cleanmodels", fakeCm, "--game-dir", game,
    "--cache-dir", work / "cache", "--out-dir", outDir] &
    (if order.len > 0: @["--hak-order", order] else: @[])

# ----------------------------------------------------------------------------

setupBinaries()
let
  fx = work / "fixture"
  goodGame = work / "game"
  badGame = work / "game-empty"
makeGame(goodGame, true)
makeGame(badGame, false)

suite "hak plan":
  setup: makeFixture(fx)

  test "names, skipped folders and tileset groups":
    let plan = hakPlan(fx)
    check plan.mapIt(it.name) == @["l64_\"quoted", "l64_a", "l64_b", "l64_c", "l64_doors",
      "l64_my stuff", "l64_pf_elf", "l64_pm_elf", "l64_t",
      "l64_tiles1", "l64_tiles2", "l64_tiles3", "l64_tiles4", "l64_tiles5", "l64_tiles6"]
    let byName = plan.mapIt((it.name, it)).toTable
    check byName["l64_pm_elf"].folders == @["parts" / "male" / "elf"]
    check byName["l64_tiles2"].folders == @["tilesets" / "tno01"]
    check byName["l64_tiles6"].folders == @["tilesets" / "mst01"]
    check byName["l64_tiles1"].folders.len == 0

  test "excluded folders are not planned":
    fx.put("out/x.2da", "2DA V2.0\n")
    check "l64_out" in hakPlan(fx).mapIt(it.name)
    check "l64_out" notin hakPlan(fx, exclude = [fx / "out"]).mapIt(it.name)
    # The default output folder is the checkout itself; that excludes nothing.
    check hakPlan(fx, exclude = [fx, fx.parentDir]).len == hakPlan(fx).len

suite "hak order":
  test "text list, nasher json, .mod and ranks":
    let dir = work / "order"
    removeDir(dir)
    dir.put("list.txt", "# module order\nl64_b\n\nL64_A.hak\n")
    check readHakOrder(dir / "list.txt") == @["l64_b", "l64_a"]

    let j = %*{"Mod_HakList": {"type": "list", "value": [
      {"__struct_id": 8, "Mod_Hak": {"type": "cexostring", "value": "l64_c"}},
      {"__struct_id": 8, "Mod_Hak": {"type": "cexostring", "value": "l64_a"}}]}}
    writeFile(dir / "module.ifo.json", $j)
    check readHakOrder(dir / "module.ifo.json") == @["l64_c", "l64_a"]

    let root = newGffRoot("IFO ")
    var list = newGffList()
    for name in ["l64_a", "l64_b"]:
      let s = newGffStruct(8)
      s["Mod_Hak", GffCExoString] = name
      list.add s
    root["Mod_HakList", GffList] = list
    createDir(dir / "mod")
    let fs = openFileStream(dir / "mod" / "module.ifo", fmWrite)
    fs.write(root)
    fs.close
    let (output, code) = execCmdEx(quoteShellCommand(["nwn_erf", "-c", "-f", dir / "test.mod", dir / "mod"]))
    check code == 0
    if code != 0: echo output
    check readHakOrder(dir / "test.mod") == @["l64_a", "l64_b"]

    let plan = @[HakSpec(name: "l64_z"), HakSpec(name: "l64_a"), HakSpec(name: "l64_y")]
    let ranks = hakRanks(plan, @["l64_a", "l64_q"])
    check ranks["l64_a"] == 0
    check ranks["l64_y"] == 2
    check ranks["l64_z"] == 3

suite "pack without --compile":
  setup: makeFixture(fx)

  test "every hak holds the repo's files unchanged":
    let outDir = work / "out-plain"
    removeDir(outDir)
    let before = snapshot(fx)
    let (output, code) = run(fx, @["hak", "--yes", "--out-dir", outDir])
    check code == 0
    if code != 0: echo output
    for spec in hakPlan(fx):
      if spec.folders.len == 0:
        check not fileExists(outDir / spec.name & ".hak")
        continue
      let hak = readHak(outDir / spec.name & ".hak")
      var expected = initTable[string, string]()
      for rel in spec.folders:
        for kind, path in walkDir(fx / rel):
          if kind == pcFile: expected[path.extractFilename.toLowerAscii] = readFile(path)
      check hak == expected
    check snapshot(fx) == before

  test "the default output folder is the checkout":
    let (output, code) = run(fx, @["hak", "--yes"])
    check code == 0
    if code != 0: echo output
    for spec in hakPlan(fx):
      check fileExists(fx / spec.name & ".hak") == (spec.folders.len > 0)

suite "pack with --compile":
  setup: makeFixture(fx)

  test "hak order decides the supermodel; binaries and .wok pass through":
    let outDir = work / "out-compile"
    removeDir(outDir)
    writeFile(work / "order.txt", "l64_b\nl64_a\nl64_c\n")
    let before = snapshot(fx)
    let (output, code) = run(fx, compileArgs(outDir, goodGame, work / "order.txt") & @["--keep-stage"])
    check code == 0
    if code != 0: echo output

    let c = readHak(outDir / "l64_c.hak")
    check c["m_c.mdl"].startsWith("\0\0\0\0FAKE m_c.mdl\nsuper=# sup1 from b\n")
    check c["bin01.mdl"] == binaryStub
    check c["m_c.mtr"] == readFile(fx / "c" / "m_c.mtr")
    # a's models use a's own copy, and the build says so.
    check readHak(outDir / "l64_a.hak")["m_a.mdl"].contains("super=# sup1 from a\n")
    check "a" / "sup1.mdl" & " (l64_a) differs" in output
    # The repo's walkmesh, never cleanmodels'.
    let t = readHak(outDir / "l64_t.hak")
    check t["tile01.wok"] == repoWok
    check t["tile01.mdl"].startsWith("\0\0\0\0FAKE")
    check fileExists(fx / ".hakstage" / "out" / "t" / "tile01.wok")  # written, but not used
    # Tilesets and odd folder names.
    check readHak(outDir / "l64_tiles2.hak")["tno01.set"] == "[GENERAL]\n"
    check readHak(outDir / "l64_my stuff.hak").len == 1
    check readHak(outDir / "l64_\"quoted.hak").len == 1

    # Staging: binaries are links to the repo file; res/ holds the winners.
    let stage = fx / ".hakstage"
    check getFileInfo(stage / "tree" / "c" / "bin01.mdl").id == getFileInfo(fx / "c" / "bin01.mdl").id
    check readFile(stage / "res" / "models" / "sup1.mdl") == superB
    check fileExists(stage / "res" / "models" / "m_c.mdl")       # every winning model
    check readFile(stage / "res" / "models" / "door01.mdl") == readFile(fx / "doors" / "door01.mdl")
    check fileExists(stage / "res" / "resources" / "m_c.mtr")
    check "sup1\tmdl\t" & "b" / "sup1.mdl" & "\t" & "a" / "sup1.mdl" in readFile(stage / "res" / "winners.tsv")
    check "11 models compiled (0 from the cache), 1 binary models passed through, 0 failed" in output

    # Repo files: same inode, same bytes; only the kept stage links to them.
    let after = snapshot(fx)
    check toSeq(after.keys).sorted == toSeq(before.keys).sorted
    for k, v in before:
      check after[k].inode == v.inode
      check after[k].data == v.data

  test "nasher json order; stage removed and repo untouched":
    let outDir = work / "out-compile2"
    removeDir(outDir)
    let j = %*{"Mod_HakList": {"type": "list", "value": [
      {"__struct_id": 8, "Mod_Hak": {"type": "cexostring", "value": "l64_a"}},
      {"__struct_id": 8, "Mod_Hak": {"type": "cexostring", "value": "l64_b"}}]}}
    writeFile(work / "module.ifo.json", $j)
    let before = snapshot(fx)
    let (output, code) = run(fx, compileArgs(outDir, goodGame, work / "module.ifo.json"))
    check code == 0
    if code != 0: echo output
    check readHak(outDir / "l64_c.hak")["m_c.mdl"].contains("super=# sup1 from a\n")
    check not dirExists(fx / ".hakstage")
    let after = snapshot(fx)
    check after == before
    for k, v in after: check v.links == 1

  test "no hak order: alphabetical, with a warning":
    let (output, code) = run(fx, compileArgs(work / "out-noorder", goodGame, ""))
    check code == 0
    check "No --hak-order given" in output

  test "a newer cleanmodels than the pinned one only warns":
    let (output, code) = run(fx, compileArgs(work / "out-4182", goodGame, ""),
                             [("FAKE_CM_VERSION", "4.18.2")])
    check code == 0
    if code != 0: echo output
    check "not 4.18.1 as the server build uses" in output

  test "too old a cleanmodels is refused":
    for old in ["4.18.0", "4.17.5"]:
      let outDir = work / "out-old"
      removeDir(outDir)
      let (output, code) = run(fx, compileArgs(outDir, goodGame, ""), [("FAKE_CM_VERSION", old)])
      check code != 0
      check "is cleanmodels " & old & "; this build needs 4.18.1 or newer" in output
      check toSeq(walkFiles(outDir / "*.hak")).len == 0

  test "the canary stops a build against a game folder with no real models":
    let outDir = work / "out-canary"
    removeDir(outDir)
    let (output, code) = run(fx, compileArgs(outDir, badGame, ""))
    check code != 0
    check "no real models" in output
    check toSeq(walkFiles(outDir / "*.hak")).len == 0

  test "a failed model stops the build; its hak isn't written":
    let outDir = work / "out-fail"
    removeDir(outDir)
    fx.put("c/broken01.mdl", model("broken01", ""))
    let (output, code) = run(fx, compileArgs(outDir, goodGame, ""))
    check code == 1
    check "broken01.mdl: fake parse error" in output
    check fileExists(outDir / "l64_b.hak")
    check not fileExists(outDir / "l64_c.hak")
    check not fileExists(outDir / "l64_doors.hak")

  test "a compiled model over the size limit fails":
    fx.put("doors/huge.mdl", model("huge", "", repeat("# padding\n", 120_000)))
    let (output, code) = run(fx, compileArgs(work / "out-size", goodGame, "") & @["--max-file-mb", "1"])
    check code == 1
    check "over the 1 MB limit" in output

  test "big folders are compiled in chunks":
    for i in 1 .. 450:
      fx.put("many/m" & $i & ".mdl", model("m" & $i, ""))
    let log = work / "chunks.log"
    removeFile(log)
    let (output, code) = run(fx, compileArgs(work / "out-many", goodGame, ""), [("FAKE_CM_LOG", log)])
    check code == 0
    if code != 0: echo output
    let counts = readFile(log).splitLines.filterIt(it.len > 0).mapIt(parseInt(it))
    check counts.max <= 400
    # The canary, 9 small folders, and 450 models in at least two chunks.
    check counts.foldl(a + b, 0) == 1 + 11 + 450
    check counts.len >= 1 + 9 + 2
    check readHak(work / "out-many" / "l64_many.hak").len == 450

  test "a build killed half-way leaves the repo unchanged":
    let before = snapshot(fx)
    let log = work / "kill.log"
    removeFile(log)
    putEnv("FAKE_CM_LOG", log)
    putEnv("FAKE_CM_SLEEP", "2")
    let p = startProcess(layoBin, workingDir = fx,
                         args = compileArgs(work / "out-kill", goodGame, ""),
                         options = {poStdErrToStdOut})
    delEnv("FAKE_CM_LOG")
    delEnv("FAKE_CM_SLEEP")
    let start = epochTime()
    # Wait for the first compile after the canary.
    while epochTime() - start < 30:
      if fileExists(log) and readFile(log).splitLines.filterIt(it.len > 0).len >= 2: break
      sleep(100)
    p.terminate
    discard p.waitForExit
    p.close
    sleep(2500)  # let the orphaned fake finish
    let after = snapshot(fx)
    check toSeq(after.keys).sorted == toSeq(before.keys).sorted
    for k, v in before:
      check after[k].inode == v.inode
      check after[k].data == v.data
