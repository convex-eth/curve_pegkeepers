// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract PegKeeperV3RouteMatrixForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_857_270;
    uint256 internal constant MAX_DEPLOYED = 1_000_000e18;

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;

    uint256 internal constant TARGET_FRXUSD = 0;
    uint256 internal constant TARGET_USDT = 1;
    uint256 internal constant TARGET_USDC = 2;
    uint256 internal constant TARGET_PYUSD = 3;
    uint256 internal constant TARGET_GHO = 4;

    uint256 internal constant YIELD_SFRXUSD = 0;
    uint256 internal constant YIELD_SUSDS = 1;
    uint256 internal constant YIELD_SUSDE = 2;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address internal constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    address internal constant FRXUSD_CRVUSD = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address internal constant USDT_CRVUSD = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant USDC_CRVUSD = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address internal constant PYUSD_CRVUSD = 0x625E92624Bc2D88619ACCc1788365A69767f6200;
    address internal constant GHO_CRVUSD = 0x635EF0056A597D13863B73825CcA297236578595;

    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant PAY_POOL = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address internal constant FRXUSD_SFRXUSD = 0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978;
    address internal constant FRXUSD_SUSDS = 0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7;
    address internal constant FRXUSD_SUSDE = 0x47Ab5f9D8C9C7D002a92320f23a696D348C56A7F;
    address internal constant USDT_USDE = 0x5B03CcCAb7BA3010fA5CAd23746cbf0794938e96;
    address internal constant USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    address internal constant GHO_USDE = 0x670a72e6D22b0956C0D2573288F82DCc5d6E3a61;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveSfrxUsdRouteMatrixPassesV3Validation() public {
        _validateYieldMatrix(YIELD_SFRXUSD);
    }

    function test_liveSusdsRouteMatrixPassesV3Validation() public {
        _validateYieldMatrix(YIELD_SUSDS);
    }

    function test_liveSusdeRouteMatrixPassesV3Validation() public {
        _validateYieldMatrix(YIELD_SUSDE);
    }

    function _validateYieldMatrix(uint256 yieldId) internal {
        for (uint256 targetId; targetId < 5; ++targetId) {
            IPegKeeperV3.RouteStep[] memory expansion = _expansionPath(targetId, yieldId);
            IPegKeeperV3.RouteStep[] memory contraction = _reverseWithTargetAmm(targetId, expansion);
            IPegKeeperV3 pegKeeper = _deploy(targetId, yieldId);

            vm.prank(governance);
            pegKeeper.setPaths(expansion, 100, contraction);

            assertEq(pegKeeper.expansion_path_length(), expansion.length);
            assertEq(pegKeeper.contraction_path_length(), contraction.length);
            assertEq(pegKeeper.expansion_path_step(0).tokenIn, _target(targetId));
            assertEq(pegKeeper.expansion_path_step(expansion.length - 1).tokenIn, _backing(yieldId));
            assertEq(
                pegKeeper.expansion_path_step(expansion.length - 1).tokenOut, _yieldToken(yieldId)
            );
            assertEq(pegKeeper.contraction_path_step(0).tokenOut, _backing(yieldId));
            assertEq(pegKeeper.contraction_path_step(contraction.length - 1).tokenOut, CRVUSD);
        }
    }

    function _expansionPath(uint256 targetId, uint256 yieldId)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        if (yieldId == YIELD_SUSDS) return _susdsExpansion(targetId);
        if (yieldId == YIELD_SUSDE) return _susdeExpansion(targetId);
        return _sfrxUsdExpansion(targetId);
    }

    function _susdsExpansion(uint256 targetId)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        if (targetId == TARGET_FRXUSD) {
            path = new IPegKeeperV3.RouteStep[](3);
            path[0] = _curve(FRXUSD_SUSDS, FRXUSD, SUSDS, 0, 1);
            path[1] = _vault(ERC4626_REDEEM, SUSDS, SUSDS, USDS);
            path[2] = _vault(ERC4626_DEPOSIT, SUSDS, USDS, SUSDS);
            return path;
        }

        uint256 bridgeSteps = targetId == TARGET_PYUSD ? 2 : targetId == TARGET_GHO ? 3 : 1;
        path = new IPegKeeperV3.RouteStep[](bridgeSteps + 2);
        uint256 cursor;
        if (targetId == TARGET_USDT) {
            path[cursor++] = _curve(THREE_POOL, USDT, DAI, 2, 0);
        } else if (targetId == TARGET_USDC) {
            path[cursor++] = _curve(THREE_POOL, USDC, DAI, 1, 0);
        } else if (targetId == TARGET_PYUSD) {
            path[cursor++] = _curve(PAY_POOL, PYUSD, USDC, 0, 1);
            path[cursor++] = _curve(THREE_POOL, USDC, DAI, 1, 0);
        } else {
            path[cursor++] = _curve(GHO_USDE, GHO, USDE, 0, 1);
            path[cursor++] = _curve(USDE_USDC, USDE, USDC, 0, 1);
            path[cursor++] = _curve(THREE_POOL, USDC, DAI, 1, 0);
        }
        path[cursor++] = _converter(DAI, USDS);
        path[cursor] = _vault(ERC4626_DEPOSIT, SUSDS, USDS, SUSDS);
    }

    function _susdeExpansion(uint256 targetId)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        if (targetId == TARGET_FRXUSD) {
            path = new IPegKeeperV3.RouteStep[](3);
            path[0] = _curve(FRXUSD_SUSDE, FRXUSD, SUSDE, 0, 1);
            path[1] = _vault(ERC4626_REDEEM, SUSDE, SUSDE, USDE);
            path[2] = _vault(ERC4626_DEPOSIT, SUSDE, USDE, SUSDE);
            return path;
        }

        IPegKeeperV3.RouteStep[] memory prefix = _targetToUsde(targetId);
        path = new IPegKeeperV3.RouteStep[](prefix.length + 1);
        for (uint256 i; i < prefix.length; ++i) {
            path[i] = prefix[i];
        }
        path[prefix.length] = _vault(ERC4626_DEPOSIT, SUSDE, USDE, SUSDE);
    }

    function _sfrxUsdExpansion(uint256 targetId)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        if (targetId == TARGET_FRXUSD) {
            path = new IPegKeeperV3.RouteStep[](1);
            path[0] = _curve(FRXUSD_SFRXUSD, FRXUSD, SFRXUSD, 1, 0);
            return path;
        }

        IPegKeeperV3.RouteStep[] memory prefix = _targetToUsde(targetId);
        path = new IPegKeeperV3.RouteStep[](prefix.length + 3);
        for (uint256 i; i < prefix.length; ++i) {
            path[i] = prefix[i];
        }
        path[prefix.length] = _vault(ERC4626_DEPOSIT, SUSDE, USDE, SUSDE);
        path[prefix.length + 1] = _curve(FRXUSD_SUSDE, SUSDE, FRXUSD, 1, 0);
        path[prefix.length + 2] = _curve(FRXUSD_SFRXUSD, FRXUSD, SFRXUSD, 1, 0);
    }

    function _targetToUsde(uint256 targetId)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        if (targetId == TARGET_PYUSD) {
            path = new IPegKeeperV3.RouteStep[](2);
            path[0] = _curve(PAY_POOL, PYUSD, USDC, 0, 1);
            path[1] = _curve(USDE_USDC, USDC, USDE, 1, 0);
        } else {
            path = new IPegKeeperV3.RouteStep[](1);
            if (targetId == TARGET_USDT) {
                path[0] = _curve(USDT_USDE, USDT, USDE, 0, 1);
            } else if (targetId == TARGET_USDC) {
                path[0] = _curve(USDE_USDC, USDC, USDE, 1, 0);
            } else {
                path[0] = _curve(GHO_USDE, GHO, USDE, 0, 1);
            }
        }
    }

    function _reverseWithTargetAmm(uint256 targetId, IPegKeeperV3.RouteStep[] memory expansion)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory contraction)
    {
        contraction = new IPegKeeperV3.RouteStep[](expansion.length + 1);
        for (uint256 i; i < expansion.length; ++i) {
            IPegKeeperV3.RouteStep memory forward = expansion[expansion.length - 1 - i];
            uint256 reverseKind = forward.kind;
            if (forward.kind == ERC4626_DEPOSIT) reverseKind = ERC4626_REDEEM;
            else if (forward.kind == ERC4626_REDEEM) reverseKind = ERC4626_DEPOSIT;
            contraction[i] = IPegKeeperV3.RouteStep({
                kind: reverseKind,
                venue: forward.venue,
                tokenIn: forward.tokenOut,
                tokenOut: forward.tokenIn,
                poolIndexIn: forward.poolIndexOut,
                poolIndexOut: forward.poolIndexIn,
                executionBufferBps: forward.executionBufferBps
            });
        }
        contraction[expansion.length] =
            _curve(_targetPool(targetId), _target(targetId), CRVUSD, 0, 1);
    }

    function _curve(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 indexIn,
        int128 indexOut
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: indexIn,
            poolIndexOut: indexOut,
            executionBufferBps: 5
        });
    }

    function _converter(address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: DAI_USDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _vault(uint256 kind, address venue, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _target(uint256 targetId) internal pure returns (address) {
        if (targetId == TARGET_FRXUSD) return FRXUSD;
        if (targetId == TARGET_USDT) return USDT;
        if (targetId == TARGET_USDC) return USDC;
        if (targetId == TARGET_PYUSD) return PYUSD;
        return GHO;
    }

    function _targetPool(uint256 targetId) internal pure returns (address) {
        if (targetId == TARGET_FRXUSD) return FRXUSD_CRVUSD;
        if (targetId == TARGET_USDT) return USDT_CRVUSD;
        if (targetId == TARGET_USDC) return USDC_CRVUSD;
        if (targetId == TARGET_PYUSD) return PYUSD_CRVUSD;
        return GHO_CRVUSD;
    }

    function _backing(uint256 yieldId) internal pure returns (address) {
        if (yieldId == YIELD_SFRXUSD) return FRXUSD;
        if (yieldId == YIELD_SUSDS) return USDS;
        return USDE;
    }

    function _yieldToken(uint256 yieldId) internal pure returns (address) {
        if (yieldId == YIELD_SFRXUSD) return SFRXUSD;
        if (yieldId == YIELD_SUSDS) return SUSDS;
        return SUSDE;
    }

    function _deploy(uint256 targetId, uint256 yieldId)
        internal
        returns (IPegKeeperV3 deployedPegKeeper)
    {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            FACTORY,
            _targetPool(targetId),
            _target(targetId),
            _backing(yieldId),
            _yieldToken(yieldId),
            FEE_SPLITTER,
            governance,
            emergencyAdmin,
            MAX_DEPLOYED
        );
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        deployedPegKeeper = IPegKeeperV3(deployed);
    }
}
