// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IFrxUsdMinter} from "../src/interfaces/IFrxUsdMinter.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

interface IForkToken {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IFrxUsdCustodianView {
    function frxUSDMinted() external view returns (uint256);
}

contract FrxUsdMintForkFactory {
    address public immutable stablecoin;
    address public immutable controllerFactory;
    address public admin;
    address public emergency_admin;
    address public fee_receiver;
    mapping(address => uint256) public debt_ceiling;

    constructor(
        address stablecoin_,
        address admin_,
        address emergencyAdmin_,
        address feeReceiver_
    ) {
        stablecoin = stablecoin_;
        controllerFactory = address(this);
        admin = admin_;
        emergency_admin = emergencyAdmin_;
        fee_receiver = feeReceiver_;
    }

    function setDebtCeiling(address account, uint256 amount) external {
        debt_ceiling[account] = amount;
    }
}

contract FrxUsdMintForkTargetPool {
    uint256 internal constant PPM = 1_000_000;

    address public immutable target;
    address public immutable crvUsd;
    uint256 public immutable pricePpm;

    constructor(address target_, address crvUsd_, uint256 pricePpm_) {
        target = target_;
        crvUsd = crvUsd_;
        pricePpm = pricePpm_;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return target;
        require(index == 1, "coin index");
        return crvUsd;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return dx * pricePpm / (PPM * 1e12);
        require(i == 0 && j == 1, "indices");
        return dx * PPM * 1e12 / pricePpm;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut)
    {
        require(i == 1 && j == 0, "direction");
        amountOut = dx * pricePpm / (PPM * 1e12);
        require(amountOut >= minDy, "slippage");
        require(IForkToken(crvUsd).transferFrom(msg.sender, address(this), dx), "crvUSD transfer");
        require(IForkToken(target).transfer(msg.sender, amountOut), "target transfer");
    }
}

contract PegKeeperV3FrxUsdMintForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_857_270;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant FRXUSD_MINT = 4;
    uint256 internal constant MAX_DEPLOYED = 1_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;

    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;
    address internal constant FRXUSD_CUSTODIAN = 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;
    address internal constant FRXUSD_SFRXUSD = 0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978;
    address internal constant FRXUSD_CRVUSD = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");

    FrxUsdMintForkFactory internal factory;
    FrxUsdMintForkTargetPool internal targetPool;
    IPegKeeperV3 internal pegKeeper;

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        factory = new FrxUsdMintForkFactory(CRVUSD, governance, emergencyAdmin, feeReceiver);
        targetPool = new FrxUsdMintForkTargetPool(USDC, CRVUSD, 1_001_000);
        deal(USDC, address(targetPool), 200_000e6);
        pegKeeper = _deploy();
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
        deal(CRVUSD, address(pegKeeper), EXPANSION_AMOUNT);
        _installPaths();
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 1_500_000, 300_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function test_liveFrxUsdCustodianMintExecutesInsideExpansionRoute() public {
        uint256 custodianUsdcBefore = IForkToken(USDC).balanceOf(FRXUSD_CUSTODIAN);
        uint256 mintedBefore = IFrxUsdCustodianView(FRXUSD_CUSTODIAN).frxUSDMinted();
        uint256 keeperFrxUsdBefore = IForkToken(FRXUSD).balanceOf(keeper);
        assertEq(IFrxUsdMinter(FRXUSD_CUSTODIAN).asset(), USDC);
        assertEq(IFrxUsdMinter(FRXUSD_CUSTODIAN).frxUSD(), FRXUSD);
        assertEq(IFrxUsdMinter(FRXUSD_CUSTODIAN).previewDeposit(100_100e6), 100_100e18);

        (,,, uint256 expectedKeeperReward, uint256 expectedYieldToken, bool expectedToDeploy) =
            pegKeeper.previewExpansion(EXPANSION_AMOUNT);
        assertTrue(expectedToDeploy);
        assertGt(expectedKeeperReward, 20e18);
        assertGt(expectedYieldToken, 0);

        vm.prank(keeper);
        (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,
            uint256 keeperReward,
            bool deployedToYield
        ) = pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(crvUsdSold, EXPANSION_AMOUNT);
        assertEq(backingRetained, 0);
        assertEq(yieldTokenReceived, expectedYieldToken);
        assertEq(keeperReward, expectedKeeperReward);
        assertTrue(deployedToYield);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldTokenReceived);
        assertEq(IForkToken(SFRXUSD).balanceOf(address(pegKeeper)), yieldTokenReceived);
        assertEq(IForkToken(FRXUSD).balanceOf(keeper) - keeperFrxUsdBefore, keeperReward);
        assertEq(IForkToken(USDC).balanceOf(FRXUSD_CUSTODIAN) - custodianUsdcBefore, 100_100e6);
        assertEq(IFrxUsdCustodianView(FRXUSD_CUSTODIAN).frxUSDMinted() - mintedBefore, 100_100e18);
        assertEq(IForkToken(USDC).allowance(address(pegKeeper), FRXUSD_CUSTODIAN), 0);
        assertEq(IForkToken(FRXUSD).allowance(address(pegKeeper), FRXUSD_SFRXUSD), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _installPaths() internal {
        IPegKeeperV3.RouteStep[] memory expansion = new IPegKeeperV3.RouteStep[](2);
        expansion[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_MINT,
            venue: FRXUSD_CUSTODIAN,
            tokenIn: USDC,
            tokenOut: FRXUSD,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        expansion[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: FRXUSD_SFRXUSD,
            tokenIn: FRXUSD,
            tokenOut: SFRXUSD,
            poolIndexIn: 1,
            poolIndexOut: 0,
            executionBufferBps: 5
        });

        IPegKeeperV3.RouteStep[] memory contraction = new IPegKeeperV3.RouteStep[](2);
        contraction[0] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: FRXUSD_SFRXUSD,
            tokenIn: SFRXUSD,
            tokenOut: FRXUSD,
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
        contraction[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: FRXUSD_CRVUSD,
            tokenIn: FRXUSD,
            tokenOut: CRVUSD,
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });

        vm.prank(governance);
        pegKeeper.setPaths(expansion, 25, contraction);
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory), address(targetPool), USDC, FRXUSD, SFRXUSD, MAX_DEPLOYED, 1
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
