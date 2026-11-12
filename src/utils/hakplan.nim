## Which haks to build from which folders, and packing them with nwn_erf.
##
## The rules are the ones layonara_nwn has always used:
## - every folder (at any depth) that holds at least one file directly becomes a hak;
## - folders whose path starts with `tilesets` or `vendor`, and dot-folders, are skipped;
## - the hak name is `l64_` + the path with `/` turned into `_`, then `parts_male` → `pm`
##   and `parts_female` → `pf` (`parts/male/human` → `l64_pm_human`);
## - the tilesets go into six haks, `l64_tiles1` … `l64_tiles6`, by the globs below.

import std/[os, osproc, strutils, streams, algorithm, times]
import glob
import neverwinter/erf
import cli

const
  tilesetWildcards* = [
    "{eld**/*,p**/*,t[a-c]**/*}",
    "t[d-p]**/*",
    "t[q-z]**/*",
    "[u-z]**/*",
    "{mini**/*,load**/*,shar**/*}",
    "{mst**/*,cat**/*}"]

type
  HakSpec* = object
    name*: string           ## hak name without the extension, e.g. `l64_pm_human`
    folders*: seq[string]   ## folders packed into it, relative to the repo root
    tileset*: bool          ## one of the `l64_tilesN` haks

proc isDotPath(rel: string): bool =
  for part in rel.split({'/', '\\'}):
    if part.len > 0 and part[0] == '.':
      return true

proc isInside(path, dir: string): bool =
  ## Whether `path` is `dir` or below it (both absolute and normalised).
  path == dir or path.startsWith(dir & DirSep)

proc hasDirectFiles(dir: string): bool =
  ## Whether `dir` holds at least one regular, non-hidden file directly (what
  ## `walkGlob(dir & "/*", {Files})` found before).
  for kind, path in walkDir(dir):
    if kind == pcFile and not path.extractFilename.startsWith("."):
      return true

proc hakName*(rel: string): string =
  ## `parts/male/human` → `l64_pm_human`.
  "l64_" & rel.replace("/", "_").replace("\\", "_").replace("parts_male", "pm").replace("parts_female", "pf")

proc hakPlan*(root: string, exclude: openArray[string] = []): seq[HakSpec] =
  ## The haks layonara_nwn builds from the checkout at `root`, sorted by name
  ## (folder haks first, then `l64_tiles1` … `l64_tiles6`). `exclude` holds
  ## absolute folders that are never packed (the staging and output folders
  ## when they sit inside the checkout).
  let root = root.absolutePath.normalizedPath
  var excluded: seq[string]
  for e in exclude:
    # Only folders below the root; the default output folder is the root itself.
    let e = e.absolutePath.normalizedPath
    if e.startsWith(root & DirSep):
      excluded.add e

  proc isExcluded(abs: string): bool =
    for e in excluded:
      if abs.isInside(e): return true

  var folders: seq[HakSpec]
  for dir in walkGlob("**/*", root = root, options = {GlobOption.Directories}):
    if dir.startsWith("tilesets") or dir.startsWith("vendor") or dir.isDotPath:
      continue
    let abs = (root / dir).normalizedPath
    if abs.isExcluded or not abs.hasDirectFiles:
      continue
    folders.add HakSpec(name: hakName(dir), folders: @[dir])
  folders.sort(proc (a, b: HakSpec): int = cmp(a.name, b.name))
  result = folders

  for i, wildcard in tilesetWildcards:
    var spec = HakSpec(name: "l64_tiles" & $(i + 1), tileset: true)
    for dir in walkGlob(root & "/tilesets/" & wildcard, options = {GlobOption.Directories}):
      let rel = relativePath(dir, root)
      if rel.isDotPath or (root / rel).normalizedPath.isExcluded:
        continue
      spec.folders.add rel
    result.add spec

proc newestFileTime*(root: string, spec: HakSpec): Time =
  ## The modification time of the newest file directly in the hak's folders.
  for rel in spec.folders:
    for kind, path in walkDir(root / rel):
      if kind in {pcFile, pcLinkToFile}:
        let t = getLastModificationTime(path)
        if t > result: result = t

proc createLayoHak*(dirs: openArray[string], outFile, bin: string) =
  ## Packs the files directly in `dirs` into `outFile` with nwn_erf. The
  ## folders are passed as separate arguments, never through a shell.
  let p = startProcess(bin, args = @["-c", "-f", outFile] & @dirs,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll
  let errCode = p.waitForExit
  p.close
  if errCode != 0:
    fatal("Could not pack " & outFile & ": " & output)

  let s = openFileStream(outFile)
  try:
    discard s.readErf(outFile)
  finally:
    s.close
  success("Packed " & outFile)
