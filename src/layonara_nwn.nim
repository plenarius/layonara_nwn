import osproc, logging, strformat, os, glob, times, strutils, times, docopt, tables
import neverwinter/[resman, resref, erf]
import utils/[cli,shared,options]

from sequtils import toSeq
const
  Options = {poUsePath, poStdErrToStdOut}
  tileset_wildcards = ["{eld**/*,p**/*,t[a-c]**/*}","t[d-p]**/*","t[q-z]**/*","[u-z]**/*","{mini**/*,load**/*,shar**/*}"]

proc getNewestFile(dir: string): string =
  for file in walkFiles(dir / "*"):
    try:
      if fileNewer(file, result):
        result = file
    except OSError:
      # This is the first file we've checked
      result = file

proc getNewestFileFromGlob(dirs: string): string =
  for file in walkGlob(dirs):
    try:
      if fileNewer(file, result):
        result = file
    except OSError:
      # This is the first file we've checked
      result = file

proc createLayoHak*(dir_string, outFile, bin: string) =
  let
    cmd = join([bin, "-c -f", outFile, dir_string], " ")
    (output, errCode) = execCmdEx(cmd, Options)

  if errCode != 0:
    fatal(fmt"Could not pack {outFile}: {output}")

  when defined(posix):
    let r = resman.newResMan(100)
    r.add(openFileStream(outFile).readErf())
    let r_count = r.count()
    assert(r_count <= 16000, fmt"Hak {outFile} has more than 16k resources. (Resource Count: {r_count}).")
    success("Packed " & outFile)


when isMainModule:
  var
    opts = getOptions()
    pkg = new(PackageRef)


  let doc = """
layonara_nwn: a build tool for various Layonara NWN resources

Usage:
  layonara_nwn hak [options]

Options:
  --yes         Automatically answer yes to the overwrite prompt
  --no          Automatically answer no to the overwrite prompt
  --default     Automatically accept the default answer to the overwrite prompt

Global Options:
  -h --help     Display help for layonara_nwn or one of its commands.
  -v --version  Display version information.
"""

  let args = docopt(doc, version = "layonara_nwn 0.1")

  if args["hak"]:
    let bin = findExe("nwn_erf")

    # First we recursively loop getting all the directories only
    const optsNoFiles = {GlobOption.Directories}
    const optsOnlyFiles = {GlobOption.Files}
    for dir in walkGlob("**/*", options = optsNoFiles):
      var noFiles = true
      for f in walkGlob(dir & "/*", options = optsOnlyFiles):
        noFiles = false
        break
      if dir.startsWith(".git") or dir.startsWith("tilesets") or noFiles:
        continue
      let
        hak_file_name = dir.replace("/", "_").replace("\\", "_").replace("parts_male", "pm").replace("parts_female", "pf")
        file = fmt"lay_{hak_file_name}.hak"

      if existsFile(file):
        let fileTime = getNewestFile(dir).getLastModificationTime
        let modTime = getLastModificationTime(file)
        if (fileTime < modTime):
          let timeDiff = getTimeDiff(fileTime, modTime)
          let defaultAnswer = if timeDiff > 0: Yes else: No
          hint(getTimeDiffHint("The file to be packed", timeDiff))
          if not askIf(fmt"{file} already exists. Overwrite?", defaultAnswer):
            continue

      display(fmt"Packing files into {file}")
      let dir_string = getCurrentDir() & "/" & dir
      createLayoHak(dir_string, file, bin)

    var tileset = 1
    for tileset_wildcard in tileset_wildcards:
      let dirs = getCurrentDir() & "/tilesets/" & tileset_wildcard
      let file = fmt"lay_tiles{tileset}.hak"
      tileset += 1
      if existsFile(file):
        let fileTime = getNewestFileFromGlob(dirs).getLastModificationTime
        let modTime = getLastModificationTime(file)
        if (fileTime < modTime):
          let timeDiff = getTimeDiff(fileTime, modTime)
          let defaultAnswer = if timeDiff > 0: Yes else: No
          hint(getTimeDiffHint("The file to be packed", timeDiff))
          if not askIf(fmt"{file} already exists. Overwrite?", defaultAnswer):
            continue

      display(fmt"Packing files into {file}.")
      let dir_string = toSeq(walkGlob(dirs, options = optsNoFiles)).join(" ")
      createLayoHak(dir_string, file, bin)
