// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ICurveVoting {
    function newVote(
        bytes calldata script,
        string calldata metadata,
        bool castVote,
        bool executesIfDecided
    ) external returns (uint256 voteId);

    function votePct(uint256 voteId, uint256 yeaPct, uint256 nayPct, bool executesIfDecided)
        external;

    function executeVote(uint256 voteId) external;
    function execute(address target, uint256 ethValue, bytes calldata data) external;

    function getVote(uint256 voteId)
        external
        view
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 yea,
            uint256 nay,
            uint256 votingPower,
            bytes memory script
        );

    function canVote(uint256 voteId, address voter) external view returns (bool);
}
