# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal accounts DB:
## =================
##
## Flow chart for healing algorithm
## --------------------------------
## ::
##      START with {state-root}
##        |
##        |   +--------------------------------+
##        |   |                                |
##        v   v                                |
##      <inspect-trie>                         |
##        |                                    |
##        |   +--------------------------+     |
##        |   |   +--------------------+ |     |
##        |   |   |                    | |     |
##        v   v   v                    | |     |
##      {missing-nodes}                | |     |
##        |                            | |     |
##        v                            | |     |
##      <get-trie-nodes-via-snap/1> ---+ |     |
##        |                              |     |
##        v                              |     |
##      <merge-nodes-into-database> -----+     |
##        |                 |                  |
##        v                 v                  |
##      {leaf-nodes}      {check-nodes} -------+
##        |
##        v                                 \
##      <update-accounts-batch>             |
##        |                                 |  similar actions for single leaf
##        v                                  \ nodes that otherwise would be
##      {storage-roots}                      / done for account hash ranges in
##        |                                 |  the function storeAccounts()
##        v                                 |
##      <update-storage-processor-batch>    /
##
## Legend:
## * `<..>`: some action, process, etc.
## * `{missing-nodes}`: list implemented as `env.fetchAccounts.missingNodes`
## * `(state-root}`: implicit argument for `getAccountNodeKey()` when
##   the argument list is empty
## * `{leaf-nodes}`: list is optimised out
## * `{check-nodes}`: list implemented as `env.fetchAccounts.checkNodes`
## * `{storage-roots}`: list implemented as `env.fetchStorage`
##
## Discussion of flow chart
## ------------------------
## * Input nodes for `<inspect-trie>` are checked for dangling child node
##   links which in turn are collected as output.
##
## * Nodes of the `{missing-nodes}` list are fetched from the network and
##   merged into the persistent accounts trie database.
##   + Successfully merged non-leaf nodes are collected in the `{check-nodes}`
##     list which is fed back into the `<inspect-trie>` process.
##   + Successfully merged leaf nodes are processed as single entry accounts
##     node ranges.
##
## * If there is a problem with a node travelling from the source list
##   `{missing-nodes}` towards either target list `{leaf-nodes}` or
##   `{check-nodes}`, this problem node will fed back to the `{missing-nodes}`
##   source list.
##
## * In order to avoid double processing, the `{missing-nodes}` list is
##   regularly checked for whether nodes are still missing or some other
##   process has done the magic work of merging some of then into the
##   trie database.
##
## Competing with other trie algorithms
## ------------------------------------
## * Healing runs (semi-)parallel to processing *GetAccountRange* network
##   messages from the `snap/1` protocol (see `storeAccounts()`). Considering
##   network bandwidth, the *GetAccountRange* message processing is way more
##   efficient in comparison with the healing algorithm as there are no
##   intermediate trie nodes involved.
##
## * The healing algorithm visits all nodes of a complete trie unless it is
##   stopped in between.
##
## * If a trie node is missing, it can be fetched directly by the healing
##   algorithm or one can wait for another process to do the job. Waiting for
##   other processes to do the job also applies to problem nodes (and vice
##   versa.)
##
## * Network bandwidth can be saved if nodes are fetched by the more efficient
##   *GetAccountRange* message processing (if that is available.) This suggests
##   that fetching missing trie nodes by the healing algorithm should kick in
##   very late when the trie database is nearly complete.
##
## * Healing applies to a hexary trie database associated with the currently
##   latest *state root*, where tha latter may change occasionally. This
##   suggests to start the healing algorithm very late at a time when most of
##   the accounts have been updated by any *state root*, already. There is a
##   good chance that the healing algorithm detects and activates account data
##   from previous *state roots* that have not changed.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[interval_set, keyed_queue],
   ../../../utils/prettify,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_trie_nodes],
  ./db/[hexary_desc, hexary_error, snapdb_accounts]

{.push raises: [Defect].}

logScope:
  topics = "snap-heal"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

proc healingCtx(buddy: SnapBuddyRef): string =
  let
    ctx = buddy.ctx
    env = buddy.data.pivotEnv
  "[" &
    "nAccounts=" & $env.nAccounts & "," &
    ("covered=" & env.fetchAccounts.unprocessed.emptyFactor.toPC(0) & "/" &
        ctx.data.coveredAccounts.fullFactor.toPC(0)) & "," &
    "nCheckNodes=" & $env.fetchAccounts.checkNodes.len & "," &
    "nMissingNodes=" & $env.fetchAccounts.missingNodes.len & "]"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateMissingNodesList(buddy: SnapBuddyRef) =
  ## Check whether previously missing nodes from the `missingNodes` list
  ## have been magically added to the database since it was checked last
  ## time. These nodes will me moved to `checkNodes` for further processing.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
  var
    nodes: seq[Blob]

  when extraTraceMessages:
    trace "Start accounts healing", peer, ctx=buddy.healingCtx()

  for accKey in env.fetchAccounts.missingNodes:
    let rc = ctx.data.snapDb.getAccountNodeKey(peer, stateRoot, accKey)
    if rc.isOk:
      # Check nodes for dangling links
      env.fetchAccounts.checkNodes.add accKey
    else:
      # Node is still missing
      nodes.add acckey

  env.fetchAccounts.missingNodes = nodes


proc appendMoreDanglingNodesToMissingNodesList(buddy: SnapBuddyRef): bool =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is
  ## fed back to the vey same list `checkNodes`
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

    rc = ctx.data.snapDb.inspectAccountsTrie(
      peer, stateRoot, env.fetchAccounts.checkNodes)

  if rc.isErr:
    when extraTraceMessages:
      error "Accounts healing failed => stop", peer,
        ctx=buddy.healingCtx(), error=rc.error
    # Attempt to switch peers, there is not much else we can do here
    buddy.ctrl.zombie = true
    return

  # Global/env batch list to be replaced by by `rc.value.leaves` return value
  env.fetchAccounts.checkNodes.setLen(0)
  env.fetchAccounts.missingNodes =
    env.fetchAccounts.missingNodes & rc.value.dangling

  true


proc getMissingNodesFromNetwork(
    buddy: SnapBuddyRef;
      ): Future[seq[Blob]]
      {.async.} =
  ##  Extract from `missingNodes` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

    nMissingNodes = env.fetchAccounts.missingNodes.len
    inxLeft = max(0, nMissingNodes - maxTrieNodeFetch)

  # There is no point in processing too many nodes at the same time. So leave
  # the rest on the `missingNodes` queue to be handled later.
  let fetchNodes = env.fetchAccounts.missingNodes[inxLeft ..< nMissingNodes]
  env.fetchAccounts.missingNodes.setLen(inxLeft)

  # Fetch nodes from the network. Note that the remainder of the `missingNodes`
  # list might be used by another process that runs semi-parallel.
  let rc = await buddy.getTrieNodes(stateRoot, fetchNodes.mapIt(@[it]))
  if rc.isOk:
    # Register unfetched missing nodes for the next pass
    env.fetchAccounts.missingNodes =
      env.fetchAccounts.missingNodes & rc.value.leftOver.mapIt(it[0])
    return rc.value.nodes

  # Restore missing nodes list now so that a task switch in the error checker
  # allows other processes to access the full `missingNodes` list.
  env.fetchAccounts.missingNodes = env.fetchAccounts.missingNodes & fetchNodes

  let error = rc.error
  if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
    discard
    when extraTraceMessages:
      trace "Error fetching account nodes for healing => stop", peer,
        ctx=buddy.healingCtx(), error
  else:
    discard
    when extraTraceMessages:
      trace "Error fetching account nodes for healing", peer,
        ctx=buddy.healingCtx(), error

  return @[]


proc kvAccountLeaf(
    buddy: SnapBuddyRef;
    partialPath: Blob;
    node: Blob;
      ): (bool,NodeKey,Account)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Read leaf node from persistent database (if any)
  let
    peer = buddy.peer
    env = buddy.data.pivotEnv

    nodeRlp = rlpFromBytes node
    (_,prefix) = hexPrefixDecode partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    let data = nodeRlp.listElem(1).toBytes
    return (true, nibbles.getBytes.convertTo(NodeKey), rlp.decode(data,Account))

  when extraTraceMessages:
    trace "Isolated node path for healing => ignored", peer,
      ctx=buddy.healingCtx()


proc registerAccountLeaf(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    acc: Account) =
  ## Process single account node as would be done with an interval by
  ## the `storeAccounts()` functoon
  let
    peer = buddy.peer
    env = buddy.data.pivotEnv
    pt = accKey.to(NodeTag)

  # Find range set (from list) containing `pt`
  var ivSet: NodeTagRangeSet
  block foundCoveringRange:
    for w in env.fetchAccounts.unprocessed:
      if 0 < w.covered(pt,pt):
        ivSet = w
        break foundCoveringRange
    return # already processed, forget this account leaf

  # Register this isolated leaf node that was added
  env.nAccounts.inc
  discard ivSet.reduce(pt,pt)
  discard buddy.ctx.data.coveredAccounts.merge(pt,pt)

  # Update storage slots batch
  if acc.storageRoot != emptyRlpHash:
    env.fetchStorage.merge AccountSlotsHeader(
      accHash:     Hash256(data: accKey.ByteArray32),
      storageRoot: acc.storageRoot)

  when extraTraceMessages:
    trace "Isolated node for healing", peer, ctx=buddy.healingCtx(), accKey=pt

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healAccountsDb*(buddy: SnapBuddyRef) {.async.} =
  ## Fetching and merging missing account trie database nodes.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv

  # Only start healing if there is some completion level, already.
  #
  # We check against the global coverage factor, i.e. a measure for how
  # much of the total of all accounts have been processed. Even if the trie
  # database for the current pivot state root is sparsely filled, there
  # is a good chance that it can inherit some unchanged sub-trie from an
  # earlier pivor state root download. The healing process then works like
  # sort of glue.
  #
  if env.nAccounts == 0 or
     ctx.data.coveredAccounts.fullFactor < healAccountsTrigger:
    when extraTraceMessages:
      trace "Accounts healing postponed", peer, ctx=buddy.healingCtx()
    return

  # Update for changes since last visit
  buddy.updateMissingNodesList()

  # If `checkNodes` is empty, healing is at the very start or was
  # postponed in which case `missingNodes` is non-empty.
  if env.fetchAccounts.checkNodes.len != 0 or
     env.fetchAccounts.missingNodes.len == 0:
    if not buddy.appendMoreDanglingNodesToMissingNodesList():
      return

  # Check whether the trie is complete.
  if env.fetchAccounts.missingNodes.len == 0:
    trace "Accounts healing complete", peer, ctx=buddy.healingCtx()
    return # nothing to do

  # Get next batch of nodes that need to be merged it into the database
  let nodesData = await buddy.getMissingNodesFromNetwork()
  if nodesData.len == 0:
    return

  # Store nodes to disk
  let report = ctx.data.snapDb.importRawAccountNodes(peer, nodesData)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error "Accounts healing, error updating persistent database", peer,
      ctx=buddy.healingCtx(), nNodes=nodesData.len, error=report[^1].error
    env.fetchAccounts.missingNodes = env.fetchAccounts.missingNodes & nodesData
    return

  when extraTraceMessages:
    trace "Accounts healing, nodes merged into database", peer,
      ctx=buddy.healingCtx(), nNodes=nodesData.len

  # Filter out error and leaf nodes
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let
        inx = w.slot.unsafeGet
        nodePath = nodesData[inx]

      if w.error != NothingSerious or w.kind.isNone:
        # error, try downloading again
        env.fetchAccounts.missingNodes.add nodePath

      elif w.kind.unsafeGet != Leaf:
        # re-check this node
        env.fetchAccounts.checkNodes.add nodePath

      else:
        # Node has been stored, double check
        let (isLeaf, key, acc) = buddy.kvAccountLeaf(nodePath, nodesData[inx])
        if isLeaf:
          # Update `uprocessed` registry, collect storage roots (if any)
          buddy.registerAccountLeaf(key, acc)
        else:
          env.fetchAccounts.checkNodes.add nodePath

  when extraTraceMessages:
    trace "Accounts healing job done", peer, ctx=buddy.healingCtx()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
