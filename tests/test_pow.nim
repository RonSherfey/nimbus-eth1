# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, strutils, times],
  ./test_clique/gunzip,
  ../nimbus/utils/[pow, pow/pow_cache, pow/pow_dataset],
  eth/[common],
  unittest2

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["test_pow", "status"]                  # alternative repos

  specsDump = "mainspecs2k.txt.gz"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc ppMs*(elapsed: Duration): string =
  result = $elapsed.inMilliSeconds
  let ns = elapsed.inNanoSeconds mod 1_000_000
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

proc ppSecs*(elapsed: Duration): string =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000
  if ns != 0:
    # to rounded decs seconds
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

proc toKMG*[T](s: T): string =
  proc subst(s: var string; tag, new: string): bool =
    if tag.len < s.len and s[s.len - tag.len ..< s.len] == tag:
      s = s[0 ..< s.len - tag.len] & new
      return true
  result = $s
  for w in [("000", "K"),("000K","M"),("000M","G"),("000G","T"),
            ("000T","P"),("000P","E"),("000E","Z"),("000Z","Y")]:
    if not result.subst(w[0],w[1]):
      return

template showElapsed*(noisy: bool; info: string; code: untyped) =
  let start = getTime()
  code
  if noisy:
    let elpd {.inject.} = getTime() - start
    if 0 < elpd.inSeconds:
      echo "*** ", info, &": {elpd.ppSecs:>4}"
    else:
      echo "*** ", info, &": {elpd.ppMs:>4}"

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc pp*(a: BlockNonce): string =
  a.mapIt(it.toHex(2)).join.toLowerAscii

proc pp*(a: Hash256): string =
  a.data.mapIt(it.toHex(2)).join[24 .. 31].toLowerAscii


proc findFilePath(file: string): string =
  result = "?unknown?" / file
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return path

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runPowTests(noisy = true; file = specsDump;
                 nVerify = int.high; nFakeMiner = 0, nRealMiner = 0) =
  let
    filePath = file.findFilePath
    fileInfo = file.splitFile.name.split(".")[0]

    powCache = PowCacheRef.new # so we can inspect the LRU caches
    powDataset = PowDatasetRef.new(cache = powCache)
    pow = PowRef.new(powCache, powDataset)

  var
    specsList: seq[PowSpecs]

  suite &"PoW: Header test specs from {fileInfo} capture":
    block:
      test "Loading from capture":
        for (lno,line) in gunzipLines(filePath):
          let specs = line.undumpPowSpecs
          if 0 < specs.blockNumber:
            specsList.add specs
            check line == specs.dumpPowSpecs
        noisy.say "***", " block range #",
          specsList[0].blockNumber, " .. #", specsList[^1].blockNumber

    # Adjust number of tests
    let
      startVerify = max(0, specsList.len - nVerify)
      startFakeMiner = max(0, specsList.len - nFakeMiner)
      startRealMiner = max(0, specsList.len - nRealMiner)

      nDoVerify = specsList.len - startVerify
      nDoFakeMiner = specsList.len - startFakeMiner
      nDoRealMiner = specsList.len - startRealMiner

      backStep = 1u64 shl 11

    block:
      test &"Running single getPowDigest() to fill the cache":
        if nVerify <= 0:
          skip()
        else:
          noisy.showElapsed(&"first getPowDigest() instance"):
            let p = specsList[startVerify]
            check pow.getPowDigest(p).mixDigest == p.mixDigest


      test &"Running getPowDigest() on {nDoVerify} specs records":
        if nVerify <= 0:
          skip()
        else:
          noisy.showElapsed(&"all {nDoVerify} getPowDigest() instances"):
            for n in startVerify ..< specsList.len:
              let p = specsList[n]
              check pow.getPowDigest(p).mixDigest == p.mixDigest


      test &"Generate PoW mining dataset (slow proocess)":
        if nDoFakeMiner <= 0 and nRealMiner <= 0:
          skip()
        else:
          noisy.showElapsed "generate PoW dataset":
            pow.generatePowDataset(specsList[startFakeMiner].blockNumber)


      test &"Running getNonce() on {nDoFakeMiner} instances with start" &
          &" nonce {backStep} before result":
        if nDoFakeMiner <= 0:
          skip()
        else:
          noisy.showElapsed &"all {nDoFakeMiner} getNonce() instances":
            for n in startFakeMiner ..< specsList.len:
              let
                p = specsList[n]
                nonce = toBytesBE(uint64.fromBytesBE(p.nonce) - backStep)
              check pow.getNonce(
                p.blockNumber, p.miningHash, p.difficulty, nonce) == p.nonce


      test &"Running getNonce() mining function" &
          &" on {nDoRealMiner} specs records":
        if nRealMiner <= 0:
          skip()
        else:
          for n in startRealMiner ..< specsList.len:
            let p = specsList[n]
            noisy.say "***", " #", p.blockNumber, " needs ", p.nonce.pp
            noisy.showElapsed("getNonce()"):
              let nonce = pow.getNonce(p)
              noisy.say "***", " got ", nonce.pp,
                " after ", pow.nGetNonce, " attempts"
              if nonce != p.nonce:
                var q = p
                q.nonce =  nonce
                check pow.getPowDigest(q).mixDigest == p.mixDigest

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc powMain*(noisy = defined(debug)) =
  noisy.runPowTests(nVerify = 100)

when isMainModule:
  # Note:
  #   0 < nFakeMiner: allow ~20 minuntes for building lookup table
  #   0 < nRealMiner: takes days/months/years ...
  true.runPowTests(nVerify = 200, nFakeMiner = 200, nRealMiner = 5)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
