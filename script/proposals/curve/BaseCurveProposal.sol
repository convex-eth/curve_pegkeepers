// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {ICurveEDAOAdminProxy} from "../../../src/interfaces/ICurveEDAOAdminProxy.sol";
import {ICurveVoting} from "../../../src/interfaces/ICurveVoting.sol";

abstract contract BaseCurveProposal is Script {
    address public constant CURVE_OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address public constant CURVE_OWNERSHIP_VOTING = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address public constant CURVE_CRVUSD_CONTROLLER_FACTORY =
        0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address public constant CURVE_CRVUSD_EDAO_ADMIN_PROXY =
        0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;

    ICurveVoting public constant ownershipVoting = ICurveVoting(CURVE_OWNERSHIP_VOTING);

    struct Action {
        address target;
        bytes data;
    }

    function proposeOwnershipVote(bytes memory script, string memory metadata)
        public
        returns (uint256 proposalId)
    {
        proposalId = ownershipVoting.newVote(script, metadata, false, false);
    }

    function buildProposalScript() public view virtual returns (bytes memory script);

    function buildScript(address agent, Action[] memory actions)
        internal
        pure
        returns (bytes memory script)
    {
        script = abi.encodePacked(uint32(1));
        for (uint256 i; i < actions.length; ++i) {
            bytes memory actionData = abi.encodeWithSelector(
                ICurveVoting.execute.selector, actions[i].target, 0, actions[i].data
            );
            script = abi.encodePacked(script, agent, uint32(actionData.length), actionData);
        }
    }

    function _executeViaCrvUsdEDAOProxy(address target, bytes memory data)
        internal
        view
        returns (Action memory)
    {
        require(
            IControllerFactory(target).admin() == CURVE_CRVUSD_EDAO_ADMIN_PROXY,
            "controller factory admin mismatch"
        );
        return Action({
            target: CURVE_CRVUSD_EDAO_ADMIN_PROXY,
            data: abi.encodeWithSelector(ICurveEDAOAdminProxy.execute.selector, target, data)
        });
    }
}
