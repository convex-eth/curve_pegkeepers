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


event CommitNewAdmin:
    admin: address


event ApplyNewAdmin:
    admin: address


MAX_KEEPERS: constant(uint256) = 32
ADMIN_ACTIONS_DELAY: constant(uint256) = 3 * 86400

admin: public(address)
future_admin: public(address)
new_admin_deadline: public(uint256)
peg_keepers: public(DynArray[address, MAX_KEEPERS])
# Stores each array index plus one so zero remains the missing sentinel.
_pegKeeperIndex: HashMap[address, uint256]


@deploy
def __init__(_admin: address):
    if _admin == empty(address):
        raw_revert(method_id("InvalidAdmin()"))

    self.admin = _admin
    log ApplyNewAdmin(admin=_admin)


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
    self._check_admin()
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
    self._check_admin()
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
@nonpayable
def commit_new_admin(_new_admin: address):
    """
    @notice Commit new admin of the Registry.
    @dev In order to revert, commit_new_admin(current_admin) may be called.
    @param _new_admin Address of the new admin.
    """
    assert msg.sender == self.admin
    assert _new_admin != empty(address)

    self.new_admin_deadline = block.timestamp + ADMIN_ACTIONS_DELAY
    self.future_admin = _new_admin
    log CommitNewAdmin(admin=_new_admin)


@external
@nonpayable
def apply_new_admin():
    """
    @notice Apply new admin of the Registry.
    @dev Should be executed from new admin.
    """
    new_admin: address = self.future_admin
    new_admin_deadline: uint256 = self.new_admin_deadline
    assert msg.sender == new_admin
    assert block.timestamp >= new_admin_deadline
    assert new_admin_deadline != 0

    self.admin = new_admin
    self.new_admin_deadline = 0
    log ApplyNewAdmin(admin=new_admin)


@internal
@view
def _check_admin():
    assert msg.sender == self.admin
