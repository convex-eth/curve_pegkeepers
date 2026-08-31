// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface ICurveStablecoinOracle {
    function pool() external view returns (address);
    function asset() external view returns (address);
    function reference_asset() external view returns (address);
    function inverted() external view returns (bool);
    function price() external view returns (uint256);
}

contract MockCurveOraclePool {
    address[2] internal _coins;
    uint256 public oraclePrice = 1e18;

    constructor(address coin0, address coin1) {
        _coins = [coin0, coin1];
    }

    function coins(uint256 index) external view returns (address) {
        return _coins[index];
    }

    function price_oracle(uint256 index) external view returns (uint256) {
        require(index == 0, "index");
        return oraclePrice;
    }

    function setOraclePrice(uint256 price_) external {
        oraclePrice = price_;
    }
}

contract CurveStablecoinOracleTest is Test {
    address internal coin0 = makeAddr("coin0");
    address internal coin1 = makeAddr("coin1");
    address internal stranger = makeAddr("stranger");
    MockCurveOraclePool internal curvePool;

    function setUp() public {
        curvePool = new MockCurveOraclePool(coin0, coin1);
    }

    function test_coinOnePriceUsesCurveEmaDirectly() public {
        ICurveStablecoinOracle oracle = _deploy(address(curvePool), coin1, coin0);
        curvePool.setOraclePrice(999_700_000_000_000_000);

        assertEq(oracle.pool(), address(curvePool));
        assertEq(oracle.asset(), coin1);
        assertEq(oracle.reference_asset(), coin0);
        assertFalse(oracle.inverted());
        assertEq(oracle.price(), 999_700_000_000_000_000);
    }

    function test_coinZeroPriceInvertsCurveEma() public {
        ICurveStablecoinOracle oracle = _deploy(address(curvePool), coin0, coin1);
        curvePool.setOraclePrice(2e18);

        assertTrue(oracle.inverted());
        assertEq(oracle.price(), 0.5e18);
    }

    function test_priceRevertsWhenCurveEmaIsZero() public {
        ICurveStablecoinOracle oracle = _deploy(address(curvePool), coin1, coin0);
        curvePool.setOraclePrice(0);

        vm.expectRevert();
        oracle.price();
    }

    function test_constructorRejectsZeroAndMismatchedAssets() public {
        _expectDeploymentFailure(address(0), coin1, coin0);
        _expectDeploymentFailure(address(curvePool), address(0), coin0);
        _expectDeploymentFailure(address(curvePool), coin1, address(0));
        _expectDeploymentFailure(address(curvePool), coin0, coin0);
        _expectDeploymentFailure(address(curvePool), stranger, coin0);
    }

    function _expectDeploymentFailure(address pool_, address asset_, address reference_) internal {
        bytes memory creationCode =
            vm.getCode("out/CurveStablecoinOracle.vy/CurveStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(pool_, asset_, reference_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertEq(deployed, address(0));
    }

    function _deploy(address pool_, address asset_, address reference_)
        internal
        returns (ICurveStablecoinOracle oracle)
    {
        bytes memory creationCode =
            vm.getCode("out/CurveStablecoinOracle.vy/CurveStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(pool_, asset_, reference_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "oracle deployment failed");
        oracle = ICurveStablecoinOracle(deployed);
    }
}
