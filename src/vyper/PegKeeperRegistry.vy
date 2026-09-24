# pragma version 0.4.3
"""
@title PegKeeperRegistry
@license MIT
@notice Maintains a governance-selected discovery list without gating keeper execution.
"""


event PegKeeperAdded:
    pegKeeper: indexed(address)


event PegKeeperRemoved:
    pegKeeper: indexed(address)


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


MAX_KEEPERS: constant(uint256) = 32

owner: public(address)
pendingOwner: public(address)
ownershipTransferNonce: public(uint256)
peg_keepers: public(DynArray[address, MAX_KEEPERS])
# Stores each array index plus one so zero remains the missing sentinel.
_pegKeeperIndex: HashMap[address, uint256]


@deploy
def __init__(_initial_owner: address):
    if _initial_owner == empty(address):
        raw_revert(method_id("InvalidOwner()"))

    self.owner = _initial_owner
    log OwnershipTransferred(oldOwner=empty(address), newOwner=_initial_owner)


@external
@view
def peg_keeper_count() -> uint256:
    return len(self.peg_keepers)


@external
@view
def is_active(_keeper: address) -> bool:
    return self._pegKeeperIndex[_keeper] != 0


@external
def add_peg_keepers(_peg_keepers: DynArray[address, MAX_KEEPERS]):
    self._check_owner()
    for keeper: address in _peg_keepers:
        if keeper == empty(address) or keeper.codesize == 0:
            raw_revert(method_id("InvalidKeeper()"))
        if self._pegKeeperIndex[keeper] != 0:
            raw_revert(method_id("DuplicateKeeper()"))

        self.peg_keepers.append(keeper)
        self._pegKeeperIndex[keeper] = len(self.peg_keepers)
        log PegKeeperAdded(pegKeeper=keeper)


@external
def remove_peg_keepers(_peg_keepers: DynArray[address, MAX_KEEPERS]):
    self._check_owner()
    for keeper: address in _peg_keepers:
        stored_index: uint256 = self._pegKeeperIndex[keeper]
        if stored_index == 0:
            raw_revert(method_id("InvalidKeeper()"))

        index: uint256 = stored_index - 1
        last_index: uint256 = len(self.peg_keepers) - 1
        if index != last_index:
            moved: address = self.peg_keepers[last_index]
            self.peg_keepers[index] = moved
            self._pegKeeperIndex[moved] = index + 1

        self.peg_keepers.pop()
        self._pegKeeperIndex[keeper] = 0
        log PegKeeperRemoved(pegKeeper=keeper)


@external
def transferOwnership(_new_owner: address):
    if msg.sender != self.owner:
        raw_revert(method_id("NotOwner()"))
    if _new_owner == empty(address) or _new_owner == self.owner:
        raw_revert(method_id("InvalidOwner()"))

    self.pendingOwner = _new_owner
    self.ownershipTransferNonce += 1
    log OwnershipTransferStarted(owner=self.owner, pendingOwner=_new_owner)


@external
def acceptOwnership(_expected_nonce: uint256):
    if msg.sender != self.pendingOwner:
        raw_revert(method_id("NotPendingOwner()"))
    if _expected_nonce != self.ownershipTransferNonce:
        raw_revert(method_id("InvalidOwnershipTransferNonce()"))

    old_owner: address = self.owner
    self.owner = msg.sender
    self.pendingOwner = empty(address)
    log OwnershipTransferred(oldOwner=old_owner, newOwner=msg.sender)


@internal
@view
def _check_owner():
    if msg.sender != self.owner:
        raw_revert(method_id("NotOwner()"))
    if self.pendingOwner != empty(address):
        raw_revert(method_id("OwnershipHandoffPending()"))
