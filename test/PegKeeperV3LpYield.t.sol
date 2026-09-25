// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface ILpPegKeeperV3 {
    function version() external view returns (uint256 major, uint256 minor, uint256 patch);
    function backing_asset() external view returns (address);
    function paired_token() external view returns (address);
    function pool() external view returns (address);
    function pool_uses_dynamic_arrays() external view returns (bool);
    function pool_crvusd_index() external view returns (uint256);
    function pool_paired_token_index() external view returns (uint256);
    function lp_balance() external view returns (uint256);
    function trusted_backing_value() external view returns (uint256);
    function debt() external view returns (uint256);
    function entry_min_profit_ppm() external view returns (uint256);
    function normal_exit_min_profit_ppm() external view returns (uint256);
    function keeper_profit_share_bps() external view returns (uint256);
    function action_imbalance_bps() external view returns (uint256);
    function action_delay() external view returns (uint256);
    function expansion_paused() external view returns (bool);
    function all_execution_paused() external view returns (bool);
    function last_intervention_at() external view returns (uint256);
    function available_expansion() external view returns (uint256);
    function available_contraction() external view returns (uint256);
    function estimate_caller_profit() external view returns (uint256);
    function calc_profit() external view returns (uint256);
    function update() external returns (uint256 callerRewardValue);
    function update(address beneficiary) external returns (uint256 callerRewardValue);
    function can_expand_without_policy() external view returns (bool);
    function set_amm_execution_buffer(uint256 executionBufferBps) external;
    function backing_oracle() external view returns (address);
    function policy() external view returns (address);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);

    function min_backing_oracle_price() external view returns (uint256);
    function set_backing_oracle_policy(address yieldOracle, uint256 minYieldPrice) external;
    function set_policy(uint256 entryMinProfitPpm, uint256 normalExitMinProfitPpm, uint256 maxDebt)
        external;
    function set_keeper_profit_share_bps(uint256 keeperProfitShareBps) external;

    function set_intervention_policy(uint256 actionImbalanceBps, uint256 actionDelay) external;
    function future_admin() external view returns (address);
    function new_admin_deadline() external view returns (uint256);
    function commit_new_admin(address newAdmin) external;
    function apply_new_admin() external;
    function set_emergency_admin(address admin) external;

    function set_policy_contract(address newPolicy) external;
    function set_direction_paused(uint256 direction, bool paused) external;
    function expand_supply()
        external
        returns (uint256 crvUsdDeployed, uint256 lpTokensReceived, uint256 keeperReward);

    function preview_expansion()
        external
        view
        returns (
            uint256 crvUsdDeployed,
            uint256 grossProfit,
            uint256 keeperReward,
            uint256 lpTokensOut
        );

    function sweep_donated_paired_token(uint256 maxYieldTokenAmount)
        external
        returns (
            uint256 yieldTokenSwept,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,
            uint256 keeperReward
        );
    function preview_contraction()
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward);

    function contract_supply()
        external
        returns (uint256 lpTokensBurned, uint256 crvUsdReceived, uint256 keeperReward);

    function withdraw_profit() external returns (uint256 crvUsdTransferred);
    function withdraw_profit(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
    function borrow_crvusd(uint256 amount, address receiver) external;
    function reduce_debt(uint256 amount) external;
}

contract LpYieldToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function burn(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract LpYieldOracle {
    uint256 public price = 1e18;

    function setPrice(uint256 value) external {
        price = value;
    }
}

contract LpYieldOversizedOracle {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1000000000000000000)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

contract LpYieldControllerAndPolicy {
    address public immutable stablecoin;
    address public immutable controllerFactory;
    address public admin;
    address public emergency_admin;
    address public fee_receiver;
    address public aggregateCrvUsdOracle;
    address public policy;
    bool public policyExpansionAllowed = true;
    bool public policyContractionAllowed = true;
    mapping(address => uint256) public debt_ceiling;

    constructor(
        address stablecoin_,
        address admin_,
        address emergencyAdmin_,
        address feeReceiver_,
        address aggregateCrvUsdOracle_
    ) {
        stablecoin = stablecoin_;
        controllerFactory = address(this);
        admin = admin_;
        emergency_admin = emergencyAdmin_;
        fee_receiver = feeReceiver_;
        aggregateCrvUsdOracle = aggregateCrvUsdOracle_;
        policy = address(this);
    }

    function setDebtCeiling(address keeper, uint256 amount) external {
        debt_ceiling[keeper] = amount;
    }

    function increaseDebtCeiling(address keeper, uint256 amount) external {
        debt_ceiling[keeper] += amount;
        LpYieldToken(stablecoin).mint(keeper, amount);
    }

    function setFeeReceiver(address receiver) external {
        fee_receiver = receiver;
    }

    function setAggregateCrvUsdOracle(address oracle) external {
        aggregateCrvUsdOracle = oracle;
    }

    function setPolicyExpansionAllowed(bool allowed) external {
        policyExpansionAllowed = allowed;
    }

    function setPolicyContractionAllowed(bool allowed) external {
        policyContractionAllowed = allowed;
    }

    function can_expand() external view returns (bool) {
        return policyExpansionAllowed && LpYieldOracle(aggregateCrvUsdOracle).price() >= 1e18;
    }

    function can_contract() external view returns (bool) {
        return policyContractionAllowed && LpYieldOracle(aggregateCrvUsdOracle).price() <= 1e18;
    }

    function expansion_regime() external view returns (bool) {
        return LpYieldOracle(aggregateCrvUsdOracle).price() >= 1e18;
    }
}

contract LpYieldVault is LpYieldToken {
    address public immutable asset;
    uint256 public assetsPerShare = 1e18;

    constructor(address asset_) LpYieldToken(18) {
        asset = asset_;
    }

    function setAssetsPerShare(uint256 value) external {
        assetsPerShare = value;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerShare / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * 1e18 / assetsPerShare;
    }
}

contract LpYieldAmm is LpYieldToken {
    address[2] internal _coins;
    uint256 public virtualPrice = 1e18;
    uint256 public lpMintBps = 10_000;
    uint256 public withdrawBps = 10_100;
    uint256 public actualWithdrawBps = 10_100;
    uint256 public actualCrvUsdBps = 10_000;
    uint256 public withdrawBonus;
    uint256 public spendBps = 10_000;
    uint256 public addLiquidityCalls;
    uint256 public dynamicAddLiquidityCalls;
    uint256 public fixedAddLiquidityCalls;
    uint256 public dynamicRemoveLiquidityCalls;
    uint256 public fixedRemoveLiquidityCalls;
    uint256 public removeLiquidityCalls;
    bool public rejectDynamicLiquidityCalls;
    bool public rejectFixedLiquidityCalls;
    uint256[2] public lastAmounts;
    bool public useBalanceOverride;
    uint256[2] internal _balanceOverride;

    constructor(address coin0, address coin1) LpYieldToken(18) {
        _coins = [coin0, coin1];
    }

    function coins(uint256 index) external view returns (address) {
        return _coins[index];
    }

    function balances(uint256 index) external view returns (uint256) {
        if (useBalanceOverride) return _balanceOverride[index];
        return LpYieldToken(_coins[index]).balanceOf(address(this));
    }

    function setBalances(uint256 coin0Balance, uint256 coin1Balance) external {
        useBalanceOverride = true;
        _balanceOverride = [coin0Balance, coin1Balance];
    }

    function clearBalancesOverride() external {
        useBalanceOverride = false;
    }

    function get_virtual_price() external view returns (uint256) {
        return virtualPrice;
    }

    function setVirtualPrice(uint256 value) external {
        virtualPrice = value;
    }

    function setLpMintBps(uint256 value) external {
        lpMintBps = value;
    }

    function setSpendBps(uint256 value) external {
        spendBps = value;
    }

    function setRejectedLiquidityModes(bool rejectDynamic, bool rejectFixed) external {
        rejectDynamicLiquidityCalls = rejectDynamic;
        rejectFixedLiquidityCalls = rejectFixed;
    }

    function setActualWithdrawBps(uint256 value) external {
        actualWithdrawBps = value;
    }

    function setActualCrvUsdBps(uint256 value) external {
        actualCrvUsdBps = value;
    }

    function setWithdrawBps(uint256 value) external {
        withdrawBps = value;
        actualWithdrawBps = value;
    }

    function setWithdrawBonus(uint256 value) external {
        withdrawBonus = value;
    }

    function calc_token_amount(uint256[] calldata amounts, bool isDeposit)
        external
        view
        returns (uint256)
    {
        require(!rejectDynamicLiquidityCalls, "dynamic liquidity rejected");
        if (isDeposit) return (amounts[0] + amounts[1]) * lpMintBps / 10_000;
        return _quotedBurn(amounts[0] + amounts[1]);
    }

    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount)
        external
        returns (uint256 minted)
    {
        require(!rejectDynamicLiquidityCalls, "dynamic liquidity rejected");
        dynamicAddLiquidityCalls++;
        uint256[2] memory fixedAmounts = [amounts[0], amounts[1]];
        return _addLiquidity(fixedAmounts, minMintAmount);
    }

    function calc_token_amount(uint256[2] calldata amounts, bool isDeposit)
        external
        view
        returns (uint256)
    {
        require(!rejectFixedLiquidityCalls, "fixed liquidity rejected");
        if (isDeposit) return (amounts[0] + amounts[1]) * lpMintBps / 10_000;
        return _quotedBurn(amounts[0] + amounts[1]);
    }

    function add_liquidity(uint256[2] calldata amounts, uint256 minMintAmount)
        external
        returns (uint256 minted)
    {
        require(!rejectFixedLiquidityCalls, "fixed liquidity rejected");
        fixedAddLiquidityCalls++;
        return _addLiquidity(amounts, minMintAmount);
    }

    function _addLiquidity(uint256[2] memory amounts, uint256 minMintAmount)
        internal
        returns (uint256 minted)
    {
        addLiquidityCalls++;
        lastAmounts = [amounts[0], amounts[1]];
        for (uint256 i; i < 2; ++i) {
            if (amounts[i] > 0) {
                require(
                    LpYieldToken(_coins[i])
                        .transferFrom(msg.sender, address(this), amounts[i] * spendBps / 10_000),
                    "transfer in"
                );
            }
        }
        minted = (amounts[0] + amounts[1]) * lpMintBps / 10_000;
        require(minted >= minMintAmount, "mint slippage");
        balanceOf[msg.sender] += minted;
    }

    function calc_withdraw_one_coin(uint256 lpTokens, int128 index)
        external
        view
        returns (uint256)
    {
        require(index == 0, "crvUSD only");
        return lpTokens * withdrawBps / 10_000 + withdrawBonus;
    }

    function remove_liquidity_one_coin(uint256 lpTokens, int128 index, uint256 minAmount)
        external
        returns (uint256 amountOut)
    {
        require(index == 0, "crvUSD only");
        removeLiquidityCalls++;
        amountOut = lpTokens * actualWithdrawBps / 10_000 + withdrawBonus;
        require(amountOut >= minAmount, "withdraw slippage");
        balanceOf[msg.sender] -= lpTokens;
        LpYieldToken(_coins[0]).mint(msg.sender, amountOut);
    }

    function remove_liquidity_imbalance(uint256[] calldata amounts, uint256 maxBurn)
        external
        returns (uint256 burned)
    {
        require(!rejectDynamicLiquidityCalls, "dynamic liquidity rejected");
        dynamicRemoveLiquidityCalls++;
        uint256[2] memory fixedAmounts = [amounts[0], amounts[1]];
        return _removeLiquidityImbalance(fixedAmounts, maxBurn);
    }

    function remove_liquidity_imbalance(uint256[2] calldata amounts, uint256 maxBurn)
        external
        returns (uint256 burned)
    {
        require(!rejectFixedLiquidityCalls, "fixed liquidity rejected");
        fixedRemoveLiquidityCalls++;
        return _removeLiquidityImbalance(amounts, maxBurn);
    }

    function _quotedBurn(uint256 amountOut) internal view returns (uint256) {
        uint256 principal = amountOut > withdrawBonus ? amountOut - withdrawBonus : 0;
        uint256 actualBurn = (principal * 10_000 + withdrawBps - 1) / withdrawBps;
        return actualBurn > 0 ? actualBurn - 1 : 0;
    }

    function _removeLiquidityImbalance(uint256[2] memory amounts, uint256 maxBurn)
        internal
        returns (uint256 burned)
    {
        require(amounts[1] == 0, "crvUSD only");
        removeLiquidityCalls++;
        uint256 principal = amounts[0] > withdrawBonus ? amounts[0] - withdrawBonus : 0;
        burned = (principal * 10_000 + actualWithdrawBps - 1) / actualWithdrawBps;
        require(burned <= maxBurn, "withdraw slippage");
        balanceOf[msg.sender] -= burned;
        LpYieldToken(_coins[0]).mint(msg.sender, amounts[0] * actualCrvUsdBps / 10_000);
    }
}

contract PegKeeperV3LpYieldTest is Test {
    uint256 internal constant MAX_DEBT = 25_000_000e18;
    uint256 internal constant ADMIN_ACTIONS_DELAY = 3 days;

    event CommitNewAdmin(address admin);
    event ApplyNewAdmin(address admin);
    event SetEmergencyAdmin(address admin);

    event ProfitWithdrawn(
        address indexed caller,
        address indexed receiver,
        uint256 crvUsdTransferred,
        uint256 debtAfter
    );

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    LpYieldToken internal crvUsd;
    LpYieldToken internal yieldToken;
    LpYieldControllerAndPolicy internal controllerAndPolicy;
    LpYieldAmm internal yieldAmm;
    LpYieldOracle internal yieldOracle;
    LpYieldOracle internal aggregateCrvUsdOracle;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        yieldToken = new LpYieldToken(18);
        aggregateCrvUsdOracle = new LpYieldOracle();
        controllerAndPolicy = new LpYieldControllerAndPolicy(
            address(crvUsd), governance, emergencyAdmin, feeReceiver, address(aggregateCrvUsdOracle)
        );
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        yieldOracle = new LpYieldOracle();
    }

    function test_constructorPinsDirectAmmAndLpAccountingEndpoints() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        assertEq(keeper.backing_asset(), address(yieldToken));
        assertEq(keeper.paired_token(), address(yieldToken));
        assertEq(keeper.pool(), address(yieldAmm));
        assertTrue(keeper.pool_uses_dynamic_arrays());
        assertEq(keeper.pool_crvusd_index(), 0);
        assertEq(keeper.pool_paired_token_index(), 1);
        assertEq(keeper.lp_balance(), 0);
        assertEq(keeper.trusted_backing_value(), 0);
    }

    function test_keeperIsStandaloneAndHasNoFactorySelector() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        assertGt(address(keeper).code.length, 45);
        assertEq(keeper.policy(), address(controllerAndPolicy));

        (bool factoryGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("factory()"));
        assertFalse(factoryGetterExists);
        (bool initializedGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("initialized()"));
        assertFalse(initializedGetterExists);
    }

    function test_curveAdminTransferRequiresDelayAndFutureAdminAcceptance() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));
        address nextAdmin = makeAddr("next admin");
        address nextEmergencyAdmin = makeAddr("next emergency admin");
        address nextFeeReceiver = makeAddr("next fee receiver");
        LpYieldControllerAndPolicy nextPolicy = new LpYieldControllerAndPolicy(
            address(crvUsd),
            nextAdmin,
            nextEmergencyAdmin,
            nextFeeReceiver,
            address(aggregateCrvUsdOracle)
        );

        vm.prank(makeAddr("not admin"));
        vm.expectRevert();
        keeper.commit_new_admin(nextAdmin);

        uint256 committedAt = block.timestamp;
        vm.expectEmit(false, false, false, true, address(keeper));
        emit CommitNewAdmin(nextAdmin);
        vm.prank(governance);
        keeper.commit_new_admin(nextAdmin);
        assertEq(keeper.future_admin(), nextAdmin);
        assertEq(keeper.new_admin_deadline(), committedAt + ADMIN_ACTIONS_DELAY);

        vm.prank(governance);
        keeper.set_policy_contract(address(nextPolicy));
        assertEq(keeper.policy(), address(nextPolicy));

        vm.prank(nextAdmin);
        vm.expectRevert();
        keeper.apply_new_admin();

        vm.warp(keeper.new_admin_deadline());
        vm.prank(makeAddr("wrong admin"));
        vm.expectRevert();
        keeper.apply_new_admin();
        vm.expectEmit(false, false, false, true, address(keeper));
        emit ApplyNewAdmin(nextAdmin);
        vm.prank(nextAdmin);
        keeper.apply_new_admin();

        assertEq(keeper.admin(), nextAdmin);
        assertEq(keeper.future_admin(), nextAdmin);
        assertEq(keeper.new_admin_deadline(), 0);
        assertEq(nextPolicy.fee_receiver(), nextFeeReceiver);

        vm.expectEmit(false, false, false, true, address(keeper));
        emit SetEmergencyAdmin(nextEmergencyAdmin);
        vm.prank(nextAdmin);
        keeper.set_emergency_admin(nextEmergencyAdmin);
        assertEq(keeper.emergency_admin(), nextEmergencyAdmin);
    }

    function test_curveAdminCommitCanBeOverwrittenAndLegacySetterIsAbsent() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));
        address firstAdmin = makeAddr("first admin");
        address correctedAdmin = makeAddr("corrected admin");

        vm.prank(governance);
        keeper.commit_new_admin(firstAdmin);
        uint256 firstDeadline = keeper.new_admin_deadline();
        vm.warp(block.timestamp + 1 days);
        vm.prank(governance);
        keeper.commit_new_admin(correctedAdmin);

        assertEq(keeper.future_admin(), correctedAdmin);
        assertGt(keeper.new_admin_deadline(), firstDeadline);

        vm.prank(governance);
        vm.expectRevert();
        keeper.commit_new_admin(address(0));

        vm.prank(governance);
        (bool legacySetterExists,) =
            address(keeper).call(abi.encodeWithSignature("set_admin(address)", correctedAdmin));
        assertFalse(legacySetterExists);
    }

    function test_curveEmergencyAdminSetterAllowsRevocation() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        vm.expectEmit(false, false, false, true, address(keeper));
        emit SetEmergencyAdmin(address(0));
        vm.prank(governance);
        keeper.set_emergency_admin(address(0));

        assertEq(keeper.emergency_admin(), address(0));
    }

    function test_versionIsNumericThreeZeroZeroTuple() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (uint256 major, uint256 minor, uint256 patch_) = keeper.version();

        assertEq(major, 3);
        assertEq(minor, 0);
        assertEq(patch_, 0);
    }

    function test_expandUsesDynamicArrayLiquidityMode() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        keeper.expand_supply();

        assertEq(yieldAmm.dynamicAddLiquidityCalls(), 1);
        assertEq(yieldAmm.fixedAddLiquidityCalls(), 0);
    }

    function test_expandUsesFixedArrayLiquidityMode() public {
        ILpPegKeeperV3 keeper = _deployKeeperCustomWithMode(
            address(yieldToken), address(yieldToken), address(yieldAmm), false
        );
        vm.startPrank(governance);
        keeper.set_amm_execution_buffer(0);
        keeper.set_intervention_policy(2_000, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();
        yieldAmm.setBalances(0, 100_000_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        keeper.expand_supply();

        assertFalse(keeper.pool_uses_dynamic_arrays());
        assertEq(yieldAmm.dynamicAddLiquidityCalls(), 0);
        assertEq(yieldAmm.fixedAddLiquidityCalls(), 1);
    }

    function test_expansionUsesSoleCanonicalCrvUsdCap() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 2_000_000e18);

        uint256 available = keeper.available_expansion();
        assertEq(available, 2_000_000e18);
        (uint256 previewedAmount,,,) = keeper.preview_expansion();
        assertEq(previewedAmount, available);

        (uint256 deployed,,) = keeper.expand_supply();
        assertEq(deployed, available);
        assertEq(keeper.debt(), available);
    }

    function test_expansionUsesTwentyPercentOfCurrentImbalance() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setBalances(0, 5_000_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 5_000_000e18);

        assertEq(keeper.available_expansion(), 1_000_000e18);
        (uint256 previewedAmount,,,) = keeper.preview_expansion();
        assertEq(previewedAmount, 1_000_000e18);
        (uint256 deployed,,) = keeper.expand_supply();
        assertEq(deployed, 1_000_000e18);
    }

    function test_largeExpansionUsesCanonicalImbalanceWithoutIndependentRateLimit() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), MAX_DEBT);

        assertEq(keeper.available_expansion(), 20_000_000e18);
        (uint256 previewedAmount,,,) = keeper.preview_expansion();
        assertEq(previewedAmount, 20_000_000e18);

        (uint256 deployed,,) = keeper.expand_supply();
        assertEq(deployed, 20_000_000e18);
        assertEq(keeper.debt(), 20_000_000e18);
    }

    function test_velocityConfigurationAndObservabilitySelectorsAreAbsent() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        bytes4[5] memory selectors = [
            bytes4(keccak256("max_expansion_burst_bps()")),
            bytes4(keccak256("expansion_refill_period()")),
            bytes4(keccak256("expansion_pressure()")),
            bytes4(keccak256("last_expansion_pressure_update()")),
            bytes4(keccak256("available_expansion_velocity()"))
        ];

        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(keeper).staticcall(abi.encodePacked(selectors[i]));
            assertFalse(success);
        }

        vm.prank(governance);
        (bool setterSuccess,) = address(keeper)
            .call(abi.encodeWithSignature("set_velocity_policy(uint256,uint256)", 1, 1));
        assertFalse(setterSuccess);
    }

    function test_legacyCallerSelectedExpansionSelectorIsAbsent() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        (bool success,) =
            address(keeper).call(abi.encodeWithSignature("expand_supply(uint256)", 10_000e18));
        assertFalse(success);
        (success,) = address(keeper)
            .staticcall(abi.encodeWithSignature("preview_expansion(uint256)", 10_000e18));
        assertFalse(success);
    }

    function test_updateAndEstimateCallerProfitUseMaximumExpansion() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 2_000_000e18);

        uint256 estimatedRewardValue = keeper.estimate_caller_profit();
        assertGt(estimatedRewardValue, 0);
        uint256 rewardValue = keeper.update();

        assertEq(rewardValue, estimatedRewardValue);
        assertEq(keeper.debt(), 2_000_000e18);
    }

    function test_updateReturnsZeroWhenAnotherKeeperConsumedTheDelay() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(2_000, 12);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 2_000_000e18);

        keeper.expand_supply();
        uint256 debtBefore = keeper.debt();

        assertEq(keeper.estimate_caller_profit(), 0);
        assertEq(keeper.update(), 0);
        assertEq(keeper.debt(), debtBefore);
    }

    function test_v2CompatibilityProfitSelectorsUseCrvUsdValue() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.mint(address(keeper), 100e18);

        assertEq(keeper.calc_profit(), keeper.trusted_backing_value());
        assertEq(keeper.estimate_caller_profit(), 0);
    }

    function test_updateBeneficiaryReceivesExpansionLpReward() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 2_000_000e18);
        address caller = makeAddr("expansion update caller");
        address beneficiary = makeAddr("expansion reward beneficiary");

        uint256 expectedRewardValue = keeper.estimate_caller_profit();
        vm.prank(caller);
        uint256 rewardValue = keeper.update(beneficiary);

        uint256 rewardLp = yieldAmm.balanceOf(beneficiary);
        assertGt(rewardLp, 0);
        assertEq(yieldAmm.balanceOf(caller), 0);
        assertEq(crvUsd.balanceOf(beneficiary), 0);
        assertEq(rewardValue, expectedRewardValue);
        assertEq(rewardValue, rewardLp * yieldAmm.virtualPrice() / 1e18);
    }

    function test_updateBeneficiaryReceivesContractionCrvUsdReward() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(10_000e18, 0);
        address caller = makeAddr("contraction update caller");
        address beneficiary = makeAddr("contraction reward beneficiary");

        uint256 expectedRewardValue = keeper.estimate_caller_profit();
        vm.prank(caller);
        uint256 rewardValue = keeper.update(beneficiary);

        assertGt(rewardValue, 0);
        assertEq(crvUsd.balanceOf(beneficiary), rewardValue);
        assertEq(crvUsd.balanceOf(caller), 0);
        assertEq(yieldAmm.balanceOf(beneficiary), 0);
        assertEq(rewardValue, expectedRewardValue);
    }

    function test_updateRejectsZeroBeneficiary() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.expectRevert();
        keeper.update(address(0));
    }

    function test_dynamicModeDoesNotFallbackToFixedArrayLiquidity() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setRejectedLiquidityModes(true, false);
        yieldAmm.setBalances(0, 100_000_000e18);
        crvUsd.mint(address(keeper), 10_000e18);

        vm.expectRevert("dynamic liquidity rejected");
        keeper.preview_expansion();
    }

    function test_fixedModeDoesNotFallbackToDynamicArrayLiquidity() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeperWithMode(false);
        yieldAmm.setRejectedLiquidityModes(false, true);
        yieldAmm.setBalances(0, 100_000_000e18);
        crvUsd.mint(address(keeper), 10_000e18);

        vm.expectRevert("fixed liquidity rejected");
        keeper.preview_expansion();
    }

    function test_interventionPolicyDefaultsAndAdminCanSetZeroDelay() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        assertEq(keeper.action_imbalance_bps(), 2_000);
        assertEq(keeper.action_delay(), 12);
        assertEq(keeper.last_intervention_at(), 0);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        keeper.set_intervention_policy(5_000, 0);

        vm.prank(governance);
        keeper.set_intervention_policy(5_000, 0);
        assertEq(keeper.action_imbalance_bps(), 5_000);
        assertEq(keeper.action_delay(), 0);

        vm.startPrank(governance);
        vm.expectRevert();
        keeper.set_intervention_policy(0, 0);
        vm.expectRevert();
        keeper.set_intervention_policy(10_001, 0);
        vm.stopPrank();
    }

    function test_actionImbalanceBpsReplacesMisleadingDelayBpsGetter() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (bool actionImbalanceBpsExists, bytes memory encodedBps) =
            address(keeper).staticcall(abi.encodeWithSignature("action_imbalance_bps()"));
        assertTrue(actionImbalanceBpsExists);
        assertEq(abi.decode(encodedBps, (uint256)), 2_000);

        (bool oldDelayBpsGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("action_delay_bps()"));
        assertFalse(oldDelayBpsGetterExists);
        (bool legacyGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("max_intervention_share_bps()"));
        assertFalse(legacyGetterExists);
    }

    function test_debtGettersReplaceDeployedCrvUsdNames() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (bool debtExists, bytes memory encodedDebt) =
            address(keeper).staticcall(abi.encodeWithSignature("debt()"));
        assertTrue(debtExists);
        assertEq(abi.decode(encodedDebt, (uint256)), 0);

        (bool maxDebtExists, bytes memory encodedMaxDebt) =
            address(keeper).staticcall(abi.encodeWithSignature("max_debt()"));
        assertTrue(maxDebtExists);
        assertEq(abi.decode(encodedMaxDebt, (uint256)), MAX_DEBT);

        (bool oldDebtGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("deployed_crvusd()"));
        assertFalse(oldDebtGetterExists);
        (bool oldMaxDebtGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("max_deployed_crvusd()"));
        assertFalse(oldMaxDebtGetterExists);
    }

    function test_lpBalanceReplacesAccountedLpTokensGetter() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (bool lpBalanceExists, bytes memory encodedLpBalance) =
            address(keeper).staticcall(abi.encodeWithSignature("lp_balance()"));
        assertTrue(lpBalanceExists);
        assertEq(abi.decode(encodedLpBalance, (uint256)), 0);

        (bool oldGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("accounted_lp_tokens()"));
        assertFalse(oldGetterExists);
    }

    function test_reduceDebtReplacesReduceDeployedCrvUsdSelector() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        crvUsd.mint(address(keeper), 20_000e18);

        vm.prank(governance);
        keeper.borrow_crvusd(10_000e18, makeAddr("module"));
        assertEq(keeper.debt(), 10_000e18);

        vm.prank(governance);
        keeper.reduce_debt(4_000e18);
        assertEq(keeper.debt(), 6_000e18);

        vm.prank(governance);
        keeper.reduce_debt(type(uint256).max);
        assertEq(keeper.debt(), 0);

        vm.prank(governance);
        (bool oldReduceDebtExists,) =
            address(keeper).call(abi.encodeWithSignature("reduce_deployed_crvusd(uint256)", 0));
        assertFalse(oldReduceDebtExists);
    }

    function test_feeReceiverSurfaceLivesOnlyOnSelectedPolicy() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (bool getterExists,) = address(keeper).staticcall(abi.encodeWithSignature("fee_receiver()"));
        assertFalse(getterExists);

        vm.prank(governance);
        (bool setterExists,) = address(keeper)
            .call(abi.encodeWithSignature("set_fee_receiver(address)", makeAddr("keeper receiver")));
        assertFalse(setterExists);
    }

    function test_actionDelayMatchesV2GetterAndLegacyNameIsAbsent() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        (bool actionDelayExists, bytes memory encodedDelay) =
            address(keeper).staticcall(abi.encodeWithSignature("action_delay()"));
        assertTrue(actionDelayExists);
        assertEq(abi.decode(encodedDelay, (uint256)), 12);

        (bool legacyGetterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("min_intervention_delay()"));
        assertFalse(legacyGetterExists);
    }

    function test_policyAllowsExitProfitFloorBelowEntryProfitFloor() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        vm.prank(governance);
        keeper.set_policy(500, 100, 100_000_000e18);

        assertEq(keeper.entry_min_profit_ppm(), 500);
        assertEq(keeper.normal_exit_min_profit_ppm(), 100);
    }

    function test_keeperRewardShareIsKeeperLocalAndAdminControlled() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        controllerAndPolicy.increaseDebtCeiling(address(keeper), 10_000e18);

        assertEq(keeper.keeper_profit_share_bps(), 3_000);
        (, uint256 grossProfit, uint256 keeperReward,) = keeper.preview_expansion();
        assertGt(grossProfit, 0);
        assertEq(keeperReward, grossProfit * 3_000 / 10_000);

        vm.prank(makeAddr("not admin"));
        vm.expectRevert();
        keeper.set_keeper_profit_share_bps(1_250);

        vm.prank(governance);
        keeper.set_keeper_profit_share_bps(1_250);
        assertEq(keeper.keeper_profit_share_bps(), 1_250);
        (, grossProfit, keeperReward,) = keeper.preview_expansion();
        assertEq(keeperReward, grossProfit * 1_250 / 10_000);

        vm.prank(governance);
        keeper.set_keeper_profit_share_bps(0);
        assertEq(keeper.keeper_profit_share_bps(), 0);

        vm.prank(governance);
        vm.expectRevert();
        keeper.set_keeper_profit_share_bps(10_001);
    }

    function test_keeperRewardShareChangesAreIndependentAcrossStandaloneKeepers() public {
        ILpPegKeeperV3 first = _deployKeeper(address(yieldAmm));
        ILpPegKeeperV3 second = _deployKeeper(address(yieldAmm));

        vm.prank(governance);
        first.set_keeper_profit_share_bps(1_250);

        assertEq(first.keeper_profit_share_bps(), 1_250);
        assertEq(second.keeper_profit_share_bps(), 3_000);
    }

    function test_entryProfitFloorUsesGrossProfitBeforeKeeperRewardInPreview() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_005);
        controllerAndPolicy.increaseDebtCeiling(address(keeper), 10_000e18);

        vm.prank(governance);
        keeper.set_policy(500, 100, MAX_DEBT);

        (uint256 deployed, uint256 grossProfit, uint256 keeperReward, uint256 lpOut) =
            keeper.preview_expansion();

        assertEq(deployed, 10_000e18);
        assertEq(lpOut, 10_005e18);
        assertEq(grossProfit, 5e18);
        assertEq(keeperReward, 1.5e18);
    }

    function test_entryProfitFloorUsesGrossProfitBeforeKeeperRewardInExecution() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_005);
        controllerAndPolicy.increaseDebtCeiling(address(keeper), 10_000e18);

        vm.prank(governance);
        keeper.set_policy(500, 100, MAX_DEBT);

        address caller = makeAddr("five-bps entry caller");
        vm.prank(caller);
        (uint256 deployed, uint256 lpReceived, uint256 keeperReward) = keeper.expand_supply();

        assertEq(deployed, 10_000e18);
        assertEq(lpReceived, 10_005e18);
        assertEq(keeperReward, 1.5e18);
        assertEq(yieldAmm.balanceOf(caller), 1.5e18);
        assertEq(keeper.trusted_backing_value(), 10_003.5e18);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_yieldOraclePolicyDefaultsToTenBasisPointFloorAndAdminCanUpdate() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));

        assertEq(keeper.backing_oracle(), address(yieldOracle));
        assertEq(keeper.min_backing_oracle_price(), 0.999e18);

        LpYieldOracle replacement = new LpYieldOracle();
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        keeper.set_backing_oracle_policy(address(replacement), 0.998e18);

        vm.prank(governance);
        keeper.set_backing_oracle_policy(address(replacement), 0.998e18);
        assertEq(keeper.backing_oracle(), address(replacement));
        assertEq(keeper.min_backing_oracle_price(), 0.998e18);
    }

    function test_yieldOracleTenBasisPointFloorIsInclusive() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);

        yieldOracle.setPrice(0.999e18);
        keeper.preview_expansion();

        yieldOracle.setPrice(0.999e18 - 1);
        vm.expectRevert();
        keeper.preview_expansion();
        vm.expectRevert();
        keeper.expand_supply();
    }

    function test_lpVirtualPriceIsSoleBackingRateForErc4626YieldToken() public {
        LpYieldToken underlying = new LpYieldToken(18);
        LpYieldVault vault = new LpYieldVault(address(underlying));
        LpYieldAmm vaultAmm = new LpYieldAmm(address(crvUsd), address(vault));
        ILpPegKeeperV3 keeper =
            _deployKeeperCustom(address(underlying), address(vault), address(vaultAmm));
        vaultAmm.setVirtualPrice(1.1e18);
        vaultAmm.mint(address(keeper), 100e18);

        assertEq(keeper.trusted_backing_value(), 110e18);
        vault.setAssetsPerShare(2e18);
        assertEq(keeper.trusted_backing_value(), 110e18);
    }

    function test_directExpansionUsesErc4626AssetsForLocalImbalance() public {
        LpYieldToken underlying = new LpYieldToken(18);
        LpYieldVault vault = new LpYieldVault(address(underlying));
        LpYieldAmm vaultAmm = new LpYieldAmm(address(crvUsd), address(vault));
        ILpPegKeeperV3 keeper =
            _deployKeeperCustom(address(underlying), address(vault), address(vaultAmm));
        vm.startPrank(governance);
        keeper.set_amm_execution_buffer(0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        vault.setAssetsPerShare(2e18);
        crvUsd.mint(address(vaultAmm), 40_000e18);
        vault.mint(address(vaultAmm), 50_000e18);
        crvUsd.mint(address(keeper), 100_000e18);

        assertEq(keeper.available_expansion(), 60_000e18 * 2_000 / 10_000);
    }

    function test_neutralDonationSettlementDoesNotConsumeInterventionShareOrTimer() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.clearBalancesOverride();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(yieldAmm), 100_000e18);
        yieldToken.mint(address(yieldAmm), 160_000e18);
        crvUsd.mint(address(keeper), 100_000e18);
        yieldToken.mint(address(keeper), 10_000e18);

        keeper.sweep_donated_paired_token(10_000e18);

        uint256 localLimit = 60_000e18 * 2_000 / 10_000;
        assertEq(keeper.last_intervention_at(), 0);
        assertEq(keeper.available_expansion(), localLimit);
        keeper.preview_expansion();
        keeper.expand_supply();
    }

    function test_expandDepositsCrvUsdDirectlyWhenTargetAndYieldAmmAreSame() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        address caller = makeAddr("directKeeper");
        vm.prank(caller);
        (uint256 deposited, uint256 lpReceived, uint256 reward) = keeper.expand_supply();

        assertEq(deposited, 10_000e18);
        assertEq(lpReceived, 10_001e18);
        assertEq(reward, 0.3e18);

        assertEq(yieldAmm.lastAmounts(0), 10_000e18);
        assertEq(yieldAmm.lastAmounts(1), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 10_000.7e18);
        assertEq(yieldAmm.balanceOf(caller), 0.3e18);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_directExpansionAlsoMatchesAndSweepsYieldDonation() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        (
            uint256 expectedDeposited,
            uint256 expectedProfit,
            uint256 expectedReward,
            uint256 expectedLp
        ) = keeper.preview_expansion();
        assertEq(expectedDeposited, 12_000e18);
        assertEq(expectedProfit, 1.4e18);
        assertEq(expectedReward, 0.42e18);
        assertEq(expectedLp, 14_001.4e18);

        vm.prank(makeAddr("keeper"));
        (uint256 deposited, uint256 lpReceived, uint256 reward) = keeper.expand_supply();

        assertEq(deposited, 12_000e18);
        assertEq(lpReceived, 14_001.4e18);
        assertEq(reward, 0.42e18);

        assertEq(yieldAmm.lastAmounts(0), 12_000e18);
        assertEq(yieldAmm.lastAmounts(1), 2_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 14_000.98e18);
        assertEq(keeper.debt(), 12_000e18);
    }

    function test_sweep_donated_paired_tokenWorksWithoutTargetTrade() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 25_000e18);

        address caller = makeAddr("donationSweeper");
        vm.prank(caller);
        (uint256 swept, uint256 matched, uint256 lpReceived, uint256 reward) =
            keeper.sweep_donated_paired_token(12_000e18);

        assertEq(swept, 12_000e18);
        assertEq(matched, 12_000e18);
        assertEq(lpReceived, 24_002.4e18);
        assertEq(reward, 0.72e18);
        assertEq(yieldAmm.addLiquidityCalls(), 1);
        assertEq(yieldAmm.lastAmounts(0), 12_000e18);
        assertEq(yieldAmm.lastAmounts(1), 12_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 3_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 13_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 24_001.68e18);
        assertEq(yieldAmm.balanceOf(caller), 0.72e18);
        assertEq(keeper.debt(), 12_000e18);
    }

    function test_sweepDonationUsesFixedArrayLiquidityMode() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeperWithMode(false);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 25_000e18);

        keeper.sweep_donated_paired_token(12_000e18);

        assertEq(yieldAmm.fixedAddLiquidityCalls(), 1);
        assertEq(yieldAmm.dynamicAddLiquidityCalls(), 0);
        assertEq(keeper.debt(), 12_000e18);
    }

    function test_sweepUsesDonationToAbsorbLpCostWithoutRewardingDonation() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(9_990);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        address caller = makeAddr("donationSweeper");
        vm.prank(caller);
        (uint256 swept, uint256 matched, uint256 lpReceived, uint256 reward) =
            keeper.sweep_donated_paired_token(12_000e18);

        assertEq(swept, 12_000e18);
        assertEq(matched, 12_000e18);
        assertEq(lpReceived, 23_976e18);
        assertEq(reward, 0);
        assertEq(yieldAmm.balanceOf(caller), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 23_976e18);
        assertEq(keeper.debt(), 12_000e18);
        assertGe(keeper.trusted_backing_value(), keeper.debt());
    }

    function test_sweepDonationRollsBackWhenYieldAmmDoesNotSpendExactAmounts() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        yieldAmm.setSpendBps(9_999);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.prank(makeAddr("donationSweeper"));
        vm.expectRevert();
        keeper.sweep_donated_paired_token(12_000e18);

        assertEq(crvUsd.balanceOf(address(keeper)), 12_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.addLiquidityCalls(), 0);
        assertEq(crvUsd.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(yieldToken.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(keeper.debt(), 0);
    }

    function test_sweepDonationAcceptsSmallPositiveAmount() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 9_999e18);
        yieldToken.mint(address(keeper), 9_999e18);

        keeper.sweep_donated_paired_token(type(uint256).max);

        assertEq(keeper.debt(), 9_999e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
    }

    function test_sweepDonationIsBlockedByExpansionPause() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));
        vm.prank(governance);
        keeper.set_direction_paused(0, true);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.expectRevert();
        keeper.sweep_donated_paired_token(12_000e18);

        assertEq(keeper.debt(), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
    }

    function test_sweepDonationRejectsUnhealthyYieldToken() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldOracle.setPrice(0.5e18);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.expectRevert();
        keeper.sweep_donated_paired_token(12_000e18);

        assertEq(keeper.debt(), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
    }

    function test_contractBurnsLpAndWithdrawsOnlyCrvUsd() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        vm.prank(makeAddr("expansionKeeper"));
        keeper.expand_supply();
        yieldAmm.setBalances(5_050e18, 0);

        (uint256 quoted, uint256 grossProfit, uint256 quotedReward) = keeper.preview_contraction();
        assertEq(quoted, 1_010e18);
        assertEq(grossProfit, 10e18);
        assertEq(quotedReward, 3e18);

        address caller = makeAddr("contractionKeeper");
        vm.prank(caller);
        (uint256 burned, uint256 received, uint256 reward) = keeper.contract_supply();

        assertEq(burned, 1_000e18);
        assertEq(received, 1_010e18);
        assertEq(reward, 3e18);
        assertEq(yieldAmm.removeLiquidityCalls(), 1);
        assertEq(yieldAmm.balanceOf(address(keeper)), 9_000.7e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 1_007e18);
        assertEq(crvUsd.balanceOf(caller), 3e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(keeper.debt(), 8_993e18);
        assertEq(keeper.trusted_backing_value(), 9_000.7e18);
    }

    function test_contractionUsesCanonicalCrvUsdAmountAndDynamicExactOutput() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(5_000e18, 0);

        uint256 expectedCrvUsd = 1_000e18;
        uint256 expectedBurn =
            (expectedCrvUsd * 10_000 + yieldAmm.withdrawBps() - 1) / yieldAmm.withdrawBps();
        (uint256 previewedCrvUsd,,) = keeper.preview_contraction();
        assertEq(previewedCrvUsd, expectedCrvUsd);

        (uint256 burned, uint256 received,) = keeper.contract_supply();
        assertEq(burned, expectedBurn);
        assertEq(received, expectedCrvUsd);
        assertEq(yieldAmm.dynamicRemoveLiquidityCalls(), 1);
        assertEq(yieldAmm.fixedRemoveLiquidityCalls(), 0);
    }

    function test_contractionUsesFixedExactOutputWithoutDynamicFallback() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeperWithMode(false);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(5_000e18, 0);

        (, uint256 received,) = keeper.contract_supply();
        assertEq(received, 1_000e18);
        assertEq(yieldAmm.dynamicRemoveLiquidityCalls(), 0);
        assertEq(yieldAmm.fixedRemoveLiquidityCalls(), 1);
    }

    function test_dynamicContractionDoesNotFallbackToFixedArrayLiquidity() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(5_000e18, 0);
        yieldAmm.setRejectedLiquidityModes(true, false);

        vm.expectRevert("dynamic liquidity rejected");
        keeper.preview_contraction();
    }

    function test_fixedContractionDoesNotFallbackToDynamicArrayLiquidity() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeperWithMode(false);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(5_000e18, 0);
        yieldAmm.setRejectedLiquidityModes(false, true);

        vm.expectRevert("fixed liquidity rejected");
        keeper.preview_contraction();
    }

    function test_contractionRejectsInexactMeasuredCrvUsdReceipt() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(5_000e18, 0);

        yieldAmm.setActualCrvUsdBps(9_999);
        vm.expectRevert();
        keeper.contract_supply();

        yieldAmm.setActualCrvUsdBps(10_001);
        vm.expectRevert();
        keeper.contract_supply();

        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_contractionPreviewUsesExpectedBurnInsteadOfMaximumSlippage() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        vm.startPrank(governance);
        keeper.set_amm_execution_buffer(3);
        keeper.set_policy(10, 100, MAX_DEBT);
        vm.stopPrank();
        yieldAmm.setBalances(5_000e18, 0);
        yieldAmm.setWithdrawBps(10_002);

        uint256 canonicalCrvUsd = 1_000e18;
        uint256 expectedBurn =
            (canonicalCrvUsd * 10_000 + yieldAmm.withdrawBps() - 1) / yieldAmm.withdrawBps();
        uint256 expectedGross = canonicalCrvUsd - expectedBurn;
        (uint256 previewedCrvUsd, uint256 grossProfit, uint256 expectedReward) =
            keeper.preview_contraction();

        assertEq(previewedCrvUsd, canonicalCrvUsd);
        assertEq(grossProfit, expectedGross);
        assertEq(expectedReward, expectedGross * 3_000 / 10_000);
        assertEq(keeper.estimate_caller_profit(), expectedReward);
        assertEq(keeper.update(), expectedReward);
    }

    function test_contractionExecutionRechecksProfitAtActualBurn() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        vm.startPrank(governance);
        keeper.set_amm_execution_buffer(3);
        keeper.set_policy(10, 100, MAX_DEBT);
        vm.stopPrank();
        yieldAmm.setBalances(5_000e18, 0);
        yieldAmm.setWithdrawBps(10_002);

        keeper.preview_contraction();
        uint256 lpBefore = keeper.lp_balance();
        uint256 debtBefore = keeper.debt();
        yieldAmm.setActualWithdrawBps(10_000);

        vm.expectRevert();
        keeper.contract_supply();

        assertEq(keeper.lp_balance(), lpBefore);
        assertEq(keeper.debt(), debtBefore);
        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_legacyCallerSelectedContractionSelectorIsAbsent() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        (bool success,) =
            address(keeper).call(abi.encodeWithSignature("contract_supply(uint256)", 10_000e18));
        assertFalse(success);
        (success,) = address(keeper)
            .staticcall(abi.encodeWithSignature("preview_contraction(uint256)", 10_000e18));
        assertFalse(success);
    }

    function test_legacyMinimumUpdateConfigurationSelectorsAreAbsent() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        (bool getterExists,) =
            address(keeper).staticcall(abi.encodeWithSignature("min_expansion_amount()"));
        assertFalse(getterExists);

        (bool oldSetterExists,) = address(keeper)
            .call(
                abi.encodeWithSignature(
                    "set_policy(uint256,uint256,uint256,uint256)", 10, 150, 10_000e18, MAX_DEBT
                )
            );
        assertFalse(oldSetterExists);
    }

    function test_updateAndEstimateCallerProfitUseMaximumContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(10_000e18, 0);

        uint256 estimatedRewardValue = keeper.estimate_caller_profit();
        assertGt(estimatedRewardValue, 0);
        uint256 rewardValue = keeper.update();

        assertEq(rewardValue, estimatedRewardValue);
        assertGt(yieldAmm.dynamicRemoveLiquidityCalls(), 0);
    }

    function test_contractionUsesTwentyPercentOfCurrentImbalance() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(10_000e18, 0);

        assertEq(keeper.available_contraction(), 2_000e18);
        (uint256 expectedCrvUsd,,) = keeper.preview_contraction();
        assertEq(expectedCrvUsd, 2_000e18);
        (, uint256 received,) = keeper.contract_supply();
        assertEq(received, 2_000e18);
    }

    function test_zeroExitProfitFloorRejectsBreakEvenPreview() public {
        ILpPegKeeperV3 keeper = _configuredContractionWithZeroExitFloor(10_000);

        vm.expectRevert();
        keeper.preview_contraction();
    }

    function test_zeroExitProfitFloorRejectsBreakEvenExecution() public {
        ILpPegKeeperV3 keeper = _configuredContractionWithZeroExitFloor(10_000);
        uint256 lpBefore = yieldAmm.balanceOf(address(keeper));
        uint256 debtBefore = keeper.debt();

        vm.prank(makeAddr("break-even contraction caller"));
        vm.expectRevert();
        keeper.contract_supply();

        assertEq(yieldAmm.balanceOf(address(keeper)), lpBefore);
        assertEq(keeper.debt(), debtBefore);
        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_zeroExitProfitFloorRejectsLossMakingPreviewDespiteSurplus() public {
        ILpPegKeeperV3 keeper = _configuredContractionWithZeroExitFloor(9_999);

        vm.expectRevert();
        keeper.preview_contraction();
    }

    function test_zeroExitProfitFloorRejectsLossMakingExecutionDespiteSurplus() public {
        ILpPegKeeperV3 keeper = _configuredContractionWithZeroExitFloor(9_999);
        uint256 lpBefore = yieldAmm.balanceOf(address(keeper));
        uint256 debtBefore = keeper.debt();

        vm.prank(makeAddr("loss-making contraction caller"));
        vm.expectRevert();
        keeper.contract_supply();

        assertEq(yieldAmm.balanceOf(address(keeper)), lpBefore);
        assertEq(keeper.debt(), debtBefore);
        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_preview_expansionIncludesDonationMatchAndLpReward() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        (uint256 matched, uint256 grossProfit, uint256 reward, uint256 lpOut) =
            keeper.preview_expansion();

        assertEq(matched, 12_000e18);
        assertEq(grossProfit, 1.4e18);
        assertEq(reward, 0.42e18);
        assertEq(lpOut, 14_001.4e18);
    }

    function test_partialLpDepositRollsBackWholeExpansion() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);
        yieldAmm.setSpendBps(5_000);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        keeper.expand_supply();

        assertEq(crvUsd.balanceOf(address(keeper)), 24_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 2_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.addLiquidityCalls(), 0);
        assertEq(keeper.debt(), 0);
    }

    function test_matchedCrvUsdCountsAgainstAvailableBalanceAndExposure() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 22_099e18);
        yieldToken.mint(address(keeper), 2_000e18);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        keeper.expand_supply();

        assertEq(crvUsd.balanceOf(address(keeper)), 22_099e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 2_000e18);
        assertEq(keeper.debt(), 0);
    }

    function test_contractionEnforcesQuotedMaximumLpBurn() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        vm.prank(makeAddr("expansionKeeper"));
        keeper.expand_supply();

        yieldAmm.setBalances(100_000_000e18, 0);
        yieldAmm.setActualWithdrawBps(10_000);
        vm.prank(makeAddr("contractionKeeper"));
        vm.expectRevert(bytes("withdraw slippage"));
        keeper.contract_supply();

        assertEq(yieldAmm.balanceOf(address(keeper)), 10_000.7e18);
        assertEq(keeper.debt(), 10_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_contractionRemainsOpenAfterControllerCeilingFallsBelowExposure() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        controllerAndPolicy.setDebtCeiling(address(keeper), 1e18);
        yieldAmm.setBalances(100_000_000e18, 0);

        keeper.contract_supply();

        assertLt(keeper.debt(), 10_000e18);
        assertGe(keeper.trusted_backing_value(), keeper.debt());
    }

    function test_terminalContractionPaysOnlyCurrentCallExcessToLiveFeeReceiver() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(100_000_000e18, 0);

        crvUsd.mint(address(keeper), 100e18);
        address newFeeReceiver = makeAddr("new fee receiver");
        controllerAndPolicy.setFeeReceiver(newFeeReceiver);

        uint256 idleBefore = crvUsd.balanceOf(address(keeper));
        (uint256 expectedCrvUsd,, uint256 keeperReward) = keeper.preview_contraction();
        uint256 currentCallNet = expectedCrvUsd - keeperReward;
        uint256 expectedTerminalProfit = currentCallNet - keeper.debt();

        keeper.contract_supply();

        assertEq(keeper.debt(), 0);
        assertEq(keeper.lp_balance(), 0);
        assertEq(crvUsd.balanceOf(newFeeReceiver), expectedTerminalProfit);
        assertEq(
            crvUsd.balanceOf(address(keeper)), idleBefore + currentCallNet - expectedTerminalProfit
        );
        assertEq(crvUsd.balanceOf(feeReceiver), 0);
    }

    function test_normalExitRequiresFiveBpsGrossAndSplitsEdgeAfterward() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        assertEq(keeper.normal_exit_min_profit_ppm(), 500);

        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        yieldAmm.setBalances(5_002.5e18, 0);
        yieldAmm.setWithdrawBps(10_005);
        uint256 debtBefore = keeper.debt();
        (uint256 expectedCrvUsd, uint256 grossProfit, uint256 expectedReward) =
            keeper.preview_contraction();
        assertEq(expectedCrvUsd, 1_000e18 + 5e17);
        assertEq(grossProfit, 5e17);
        assertEq(expectedReward, 15e16);

        uint256 keeperBalanceBefore = crvUsd.balanceOf(address(this));
        (uint256 lpBurned, uint256 crvUsdReceived, uint256 keeperReward) = keeper.contract_supply();

        assertEq(lpBurned, 1_000e18);
        assertEq(crvUsdReceived, expectedCrvUsd);
        assertEq(keeperReward, expectedReward);
        assertEq(crvUsd.balanceOf(address(this)) - keeperBalanceBefore, 15e16);
        assertEq(debtBefore - keeper.debt(), 1_000e18 + 35e16);
    }

    function test_contractionAcceptsQuoteAndReceiptExactlyAtLocalImbalanceShare() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(5_000, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        yieldAmm.setBalances(120_010e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        (uint256 expectedCrvUsd,,) = keeper.preview_contraction();
        assertEq(expectedCrvUsd, 10_005e18);

        (, uint256 actualCrvUsd,) = keeper.contract_supply();
        assertEq(actualCrvUsd, 10_005e18);
    }

    function test_actionDelayIsSharedAcrossExpansionAndContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 12);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 30_000e18);
        uint256 firstInterventionAt = block.timestamp;
        keeper.expand_supply();
        assertEq(keeper.last_intervention_at(), firstInterventionAt);

        yieldAmm.setBalances(120_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();

        vm.warp(firstInterventionAt + 11);
        vm.expectRevert();
        keeper.preview_contraction();

        vm.warp(firstInterventionAt + 12);
        keeper.preview_contraction();
        keeper.contract_supply();
        assertEq(keeper.last_intervention_at(), firstInterventionAt + 12);

        yieldAmm.setBalances(0, 100_000e18);
        vm.expectRevert();
        keeper.preview_expansion();
    }

    function test_zeroActionDelayAllowsSameTimestampContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        uint256 interventionAt = block.timestamp;
        keeper.expand_supply();
        yieldAmm.setBalances(120_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        keeper.preview_contraction();
        keeper.contract_supply();

        assertEq(keeper.last_intervention_at(), interventionAt);
    }

    function test_previewAndExecutionRejectOneWeiBelowGrossExitMargin() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        yieldAmm.setWithdrawBps(10_000);
        yieldAmm.setWithdrawBonus(5e17 - 1);
        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();
    }

    function test_preview_contractionRejectsFinalInsolvency() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        yieldAmm.setVirtualPrice(0.9e18);
        yieldAmm.setWithdrawBps(10_000);
        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();
    }

    function test_deficitRecoveryDoesNotCountTowardGrossExitMargin() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        // Burning 1,000 LP removes 900 of trusted value. The 1,899.37 principal-recovery
        // basis includes the existing deficit, leaving only 0.43 gross profit: below 5 bp.
        yieldAmm.setVirtualPrice(0.9e18);
        yieldAmm.setWithdrawBps(18_998);
        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();
    }

    function test_typedBackingOracleCallUsesDeclaredPriceInterface() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        LpYieldOversizedOracle oversizedOracle = new LpYieldOversizedOracle();
        vm.prank(governance);
        keeper.set_backing_oracle_policy(address(oversizedOracle), 0.999e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        assertTrue(keeper.can_expand_without_policy());
        keeper.preview_expansion();
        keeper.expand_supply();
        assertGt(keeper.debt(), 0);
    }

    function test_policyGatesExpansionWithoutChangingLocalViability() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);

        assertTrue(keeper.can_expand_without_policy());
        controllerAndPolicy.setPolicyExpansionAllowed(false);
        assertTrue(keeper.can_expand_without_policy());
        assertEq(keeper.available_expansion(), 0);
        vm.expectRevert();
        keeper.preview_expansion();
        vm.expectRevert();
        keeper.expand_supply();

        controllerAndPolicy.setPolicyExpansionAllowed(true);
        assertGt(keeper.available_expansion(), 0);
        keeper.expand_supply();
    }

    function test_adminCanBorrowCrvUsdWhenPolicyAllowsAndDebtIsTracked() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        address receiver = makeAddr("module");
        crvUsd.mint(address(keeper), 20_000e18);
        uint256 borrowedAt = block.timestamp;

        vm.prank(governance);
        keeper.borrow_crvusd(10_000e18, receiver);

        assertEq(crvUsd.balanceOf(receiver), 10_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 10_000e18);
        assertEq(keeper.debt(), 10_000e18);
        assertEq(keeper.last_intervention_at(), borrowedAt);
    }

    function test_borrowCrvUsdPolicyDenialLeavesAccountingAndBalancesUnchanged() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        address receiver = makeAddr("module");
        crvUsd.mint(address(keeper), 20_000e18);
        controllerAndPolicy.setPolicyExpansionAllowed(false);

        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(10_000e18, receiver);

        assertEq(crvUsd.balanceOf(receiver), 0);
        assertEq(crvUsd.balanceOf(address(keeper)), 20_000e18);
        assertEq(keeper.debt(), 0);
    }

    function test_borrowCrvUsdRejectsUnauthorizedZeroReceiverAndCapacityExcess() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        crvUsd.mint(address(keeper), MAX_DEBT * 2);

        vm.expectRevert();
        keeper.borrow_crvusd(1, makeAddr("module"));

        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(1, address(0));

        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(0, makeAddr("zero-amount receiver"));

        controllerAndPolicy.setDebtCeiling(address(keeper), 5_000e18);
        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(5_000e18 + 1, makeAddr("module"));

        assertEq(keeper.debt(), 0);
    }

    function test_borrowCrvUsdEnforcesKeeperLocalExpansionGuards() public {
        address receiver = makeAddr("bounded module");

        ILpPegKeeperV3 pausedKeeper = _deployKeeper(address(yieldAmm));
        crvUsd.mint(address(pausedKeeper), 100_000e18);
        vm.prank(governance);
        pausedKeeper.set_direction_paused(0, true);
        vm.prank(governance);
        vm.expectRevert();
        pausedKeeper.borrow_crvusd(10_000e18, receiver);

        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        crvUsd.mint(address(keeper), 100_000e18);

        yieldAmm.setBalances(0, 30_000e18);
        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(10_000e18, receiver);

        yieldAmm.setBalances(0, 100_000_000e18);
        yieldOracle.setPrice(0.998e18);
        vm.prank(governance);
        vm.expectRevert();
        keeper.borrow_crvusd(10_000e18, receiver);
    }

    function test_legacySetPathsSelectorIsAbsent() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        bytes4 selector = bytes4(
            keccak256("setPaths((uint256,address,address,address,int128,int128,uint256)[],uint256)")
        );
        bytes memory data =
            abi.encodePacked(selector, abi.encode(uint256(64), uint256(100), uint256(0)));

        vm.prank(governance);
        (bool success,) = address(keeper).call(data);
        assertFalse(success);
    }

    function test_localExpansionProbeIncludesPauseBackingAndExecutionViability() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        assertTrue(keeper.can_expand_without_policy());

        vm.prank(governance);
        keeper.set_direction_paused(0, true);
        assertFalse(keeper.can_expand_without_policy());

        vm.prank(governance);
        keeper.set_direction_paused(0, false);
        yieldOracle.setPrice(0.998e18);
        assertFalse(keeper.can_expand_without_policy());

        yieldOracle.setPrice(1e18);
        yieldAmm.setLpMintBps(9_999);
        assertFalse(keeper.can_expand_without_policy());
    }

    function test_policyGatesContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 0);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();

        aggregateCrvUsdOracle.setPrice(1e18 - 1);
        yieldAmm.setBalances(120_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        controllerAndPolicy.setPolicyContractionAllowed(false);
        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();

        controllerAndPolicy.setPolicyContractionAllowed(true);
        keeper.preview_contraction();
        keeper.contract_supply();
    }

    function test_donationMatchingDoesNotRequireSeparateAllocationRuling() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        yieldToken.mint(address(keeper), 10_000e18);

        (uint256 swept, uint256 matched,,) = keeper.sweep_donated_paired_token(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 10_000e18);
        assertEq(keeper.debt(), 10_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
    }

    function test_policyExpansionDenialPreventsDonationDebtGrowth() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        controllerAndPolicy.setPolicyExpansionAllowed(false);

        (uint256 swept, uint256 matched,,) = keeper.sweep_donated_paired_token(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 0);
        assertEq(keeper.debt(), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
    }

    function test_aggregateCrvUsdPriceGatesExpansionAtOneDollar() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        assertEq(keeper.available_expansion(), 0);
        vm.expectRevert();
        keeper.preview_expansion();
        vm.expectRevert();
        keeper.expand_supply();

        aggregateCrvUsdOracle.setPrice(1e18);
        assertGt(keeper.available_expansion(), 0);
        keeper.expand_supply();
    }

    function test_unpausedKeeperCannotUseDonatedCrvUsdAtZeroControllerCeiling() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));
        controllerAndPolicy.setDebtCeiling(address(keeper), 0);
        crvUsd.mint(address(keeper), 100_000e18);
        yieldAmm.setBalances(0, 100_000_000e18);
        vm.warp(block.timestamp + keeper.action_delay());

        assertFalse(keeper.expansion_paused());
        assertFalse(keeper.all_execution_paused());
        assertEq(keeper.available_expansion(), 0);
        assertFalse(keeper.can_expand_without_policy());
        vm.expectRevert();
        keeper.expand_supply();
        assertEq(keeper.debt(), 0);
    }

    function test_sameBlockDonationSweepCannotRoundTripWithoutExitEdge() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);
        keeper.sweep_donated_paired_token(12_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);
        yieldAmm.setWithdrawBps(10_000);

        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();
    }

    function test_contractionRegimeSmallDonationIsEntirelyOneSided() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 500_000e18);
        yieldToken.mint(address(yieldAmm), 450_000e18);
        yieldToken.mint(address(keeper), 40_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        (uint256 swept, uint256 matched,,) = keeper.sweep_donated_paired_token(40_000e18);

        assertEq(swept, 40_000e18);
        assertEq(matched, 0);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 500_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 490_000e18);
        assertEq(keeper.debt(), 0);
    }

    function test_expansionRegimeDonationSweepMatchesFullDonation() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 10_000e18);
        yieldToken.mint(address(keeper), 10_000e18);

        (uint256 swept, uint256 matched,,) = keeper.sweep_donated_paired_token(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 10_000e18);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_aggregateCrvUsdPriceGatesContractionAtOneDollar() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand_supply();
        yieldAmm.setBalances(100_000_000e18, 0);
        aggregateCrvUsdOracle.setPrice(1e18 + 1);

        vm.expectRevert();
        keeper.preview_contraction();
        vm.expectRevert();
        keeper.contract_supply();

        aggregateCrvUsdOracle.setPrice(1e18);
        keeper.preview_contraction();
        keeper.contract_supply();
    }

    function test_contractionRegimeDonationSweepDoesNotGrowDebt() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 5_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        (uint256 swept, uint256 matched,,) = keeper.sweep_donated_paired_token(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 0);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 50_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(keeper.debt(), 0);
    }

    function test_withdrawProfitSweepsDonationBeforeClaimDuringContractionRegime() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        uint256 claimed = keeper.withdraw_profit(10_000e18);

        assertEq(claimed, 10_000e18);
        assertEq(crvUsd.balanceOf(feeReceiver), 10_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 50_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_withdrawProfitWithoutLimitWithdrawsAllEligibleProfit() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        address updatedFeeReceiver = makeAddr("updated fee receiver");
        controllerAndPolicy.setFeeReceiver(updatedFeeReceiver);

        vm.expectEmit(true, true, false, true, address(keeper));
        emit ProfitWithdrawn(address(this), updatedFeeReceiver, 10_000e18, 10_000e18);
        uint256 withdrawn = keeper.withdraw_profit();

        assertEq(withdrawn, 10_000e18);
        assertEq(crvUsd.balanceOf(updatedFeeReceiver), 10_000e18);
        assertEq(crvUsd.balanceOf(feeReceiver), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_withdrawProfitUsesReplacementPolicyFeeReceiver() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        address replacementFeeReceiver = makeAddr("replacement policy fee receiver");
        LpYieldControllerAndPolicy replacementPolicy = new LpYieldControllerAndPolicy(
            address(crvUsd),
            governance,
            emergencyAdmin,
            replacementFeeReceiver,
            address(aggregateCrvUsdOracle)
        );
        vm.prank(governance);
        keeper.set_policy_contract(address(replacementPolicy));

        vm.expectEmit(true, true, false, true, address(keeper));
        emit ProfitWithdrawn(address(this), replacementFeeReceiver, 10_000e18, 10_000e18);
        uint256 withdrawn = keeper.withdraw_profit();

        assertEq(withdrawn, 10_000e18);
        assertEq(crvUsd.balanceOf(replacementFeeReceiver), 10_000e18);
        assertEq(crvUsd.balanceOf(feeReceiver), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(keeper.debt(), 10_000e18);
    }

    function test_withdrawProfitSelectorsMatchV2NameAndBoundedOverload() public pure {
        assertEq(bytes4(keccak256("withdraw_profit()")), bytes4(0x2c9f7f92));
        assertEq(bytes4(keccak256("withdraw_profit(uint256)")), bytes4(0x8262e458));
    }

    function test_legacyYieldVocabularySelectorsAreAbsent() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(yieldAmm));
        bytes4[9] memory selectors = [
            bytes4(keccak256("yield_amm()")),
            bytes4(keccak256("yield_token()")),
            bytes4(keccak256("yield_token_is_erc4626()")),
            bytes4(keccak256("yield_amm_crvusd_index()")),
            bytes4(keccak256("yield_amm_yield_token_index()")),
            bytes4(keccak256("yield_amm_execution_buffer_bps()")),
            bytes4(keccak256("yield_oracle()")),
            bytes4(keccak256("min_yield_oracle_price()")),
            bytes4(keccak256("yield_contraction_paused()"))
        ];

        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(keeper).staticcall(abi.encodePacked(selectors[i]));
            assertFalse(success);
        }

        (bool assetsSuccess,) = address(keeper)
            .staticcall(
                abi.encodeWithSelector(bytes4(keccak256("yield_token_assets(uint256)")), 1e18)
            );
        (bool unitsSuccess,) = address(keeper)
            .staticcall(
                abi.encodeWithSelector(bytes4(keccak256("yield_token_units(uint256)")), 1e18)
            );
        assertFalse(assetsSuccess);
        assertFalse(unitsSuccess);
    }

    function test_legacyClaimSurplusSelectorIsAbsent() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        (bool success,) =
            address(keeper).call(abi.encodeWithSignature("claimSurplus(uint256)", 10_000e18));

        assertFalse(success);
    }

    function _configuredNormalKeeper() internal returns (ILpPegKeeperV3 keeper) {
        return _configuredDirectKeeper();
    }

    function _configuredDirectKeeper() internal returns (ILpPegKeeperV3 keeper) {
        return _configuredDirectKeeperWithMode(true);
    }

    function _configuredDirectKeeperWithMode(bool poolUsesDynamicArrays)
        internal
        returns (ILpPegKeeperV3 keeper)
    {
        keeper = _deployKeeperCustomWithMode(
            address(yieldToken), address(yieldToken), address(yieldAmm), poolUsesDynamicArrays
        );
        vm.startPrank(governance);
        keeper.set_amm_execution_buffer(0);
        keeper.set_intervention_policy(2_000, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        keeper.set_direction_paused(1, false);
        vm.stopPrank();
        yieldAmm.setBalances(0, 100_000_000e18);
    }

    function _configuredContractionWithZeroExitFloor(uint256 withdrawBps)
        internal
        returns (ILpPegKeeperV3 keeper)
    {
        keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        controllerAndPolicy.increaseDebtCeiling(address(keeper), 10_000e18);
        vm.prank(makeAddr("break-even expansion caller"));
        keeper.expand_supply();

        vm.prank(governance);
        keeper.set_policy(500, 0, MAX_DEBT);
        yieldAmm.setBalances(100_000_000e18, 0);
        yieldAmm.setWithdrawBps(withdrawBps);
    }

    function _deployKeeper(address) internal returns (ILpPegKeeperV3 keeper) {
        return _deployKeeperCustom(address(yieldToken), address(yieldToken), address(yieldAmm));
    }

    function _deployKeeperCustom(address backingAsset_, address yieldToken_, address yieldAmm_)
        internal
        returns (ILpPegKeeperV3 keeper)
    {
        return _deployKeeperCustomWithMode(backingAsset_, yieldToken_, yieldAmm_, true);
    }

    function _deployKeeperCustomWithMode(
        address backingAsset_,
        address yieldToken_,
        address yieldAmm_,
        bool poolUsesDynamicArrays_
    ) internal returns (ILpPegKeeperV3 keeper) {
        bytes memory keeperCreationCode = bytes.concat(
            vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"),
            abi.encode(
                address(controllerAndPolicy),
                yieldAmm_,
                backingAsset_ != yieldToken_,
                poolUsesDynamicArrays_,
                MAX_DEBT,
                1,
                address(yieldOracle)
            ),
            abi.encode(10, 500, 3, 3_000, governance, emergencyAdmin, address(controllerAndPolicy))
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(keeperCreationCode, 0x20), mload(keeperCreationCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        keeper = ILpPegKeeperV3(deployed);
        assertEq(keeper.backing_asset(), backingAsset_);
        controllerAndPolicy.setDebtCeiling(deployed, MAX_DEBT);
    }
}
