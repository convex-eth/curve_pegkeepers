// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface ILpPegKeeperV3 {
    struct RouteStep {
        uint256 kind;
        address venue;
        address tokenIn;
        address tokenOut;
        int128 poolIndexIn;
        int128 poolIndexOut;
        uint256 executionBufferBps;
    }

    function initialize(
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployedCrvUsd,
        uint256 keeperIndex,
        address yieldOracle
    ) external;

    function initialized() external view returns (bool);
    function target_amm() external view returns (address);
    function target_asset() external view returns (address);
    function backing_asset() external view returns (address);
    function yield_token() external view returns (address);
    function yield_amm() external view returns (address);
    function yield_amm_crvusd_index() external view returns (uint256);
    function yield_amm_yield_token_index() external view returns (uint256);
    function accounted_lp_tokens() external view returns (uint256);
    function trusted_backing_value() external view returns (uint256);
    function deployed_crvusd() external view returns (uint256);
    function normal_exit_min_profit_ppm() external view returns (uint256);
    function max_intervention_share_bps() external view returns (uint256);
    function min_intervention_delay() external view returns (uint256);
    function last_intervention_at() external view returns (uint256);
    function expansion_pressure() external view returns (uint256);
    function available_expansion() external view returns (uint256);
    function expansion_path_length() external view returns (uint256);
    function setPaths(RouteStep[] calldata expansion, uint256 expansionMaxRouteLossBps) external;
    function set_expansion_config(
        uint256 targetAmmExecutionBufferBps,
        uint256 yieldAmmExecutionBufferBps
    ) external;
    function yield_oracle() external view returns (address);
    function min_yield_oracle_price() external view returns (uint256);
    function set_yield_oracle_policy(address yieldOracle, uint256 minYieldPrice) external;
    function set_policy(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    ) external;
    function set_intervention_policy(uint256 maxInterventionShareBps, uint256 minInterventionDelay)
        external;
    function set_direction_paused(uint256 direction, bool paused) external;
    function expand(uint256 crvUsdAmount)
        external
        returns (
            uint256 crvUsdSold,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,
            uint256 keeperReward,
            bool directDeposit
        );
    function previewExpansion(uint256 crvUsdAmount)
        external
        view
        returns (
            uint256 targetOut,
            uint256 crvUsdMatched,
            uint256 grossProfit,
            uint256 keeperReward,
            uint256 lpTokensOut,
            bool directDeposit
        );
    function sweepDonatedYield(uint256 maxYieldTokenAmount)
        external
        returns (
            uint256 yieldTokenSwept,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,
            uint256 keeperReward
        );
    function previewKeeperBuyback(uint256 lpTokenAmount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward);
    function contractViaAmm(uint256 lpTokenAmount)
        external
        returns (uint256 lpTokensBurned, uint256 crvUsdReceived, uint256 keeperReward);
    function claimSurplus(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
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

contract LpYieldFactory {
    address public immutable stablecoin;
    address public immutable controllerFactory;
    address public admin;
    address public emergency_admin;
    address public fee_receiver;
    address public aggregateCrvUsdOracle;
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
    }

    function setDebtCeiling(address keeper, uint256 amount) external {
        debt_ceiling[keeper] = amount;
    }

    function setFeeReceiver(address receiver) external {
        fee_receiver = receiver;
    }

    function setAggregateCrvUsdOracle(address oracle) external {
        aggregateCrvUsdOracle = oracle;
    }
}

contract LpYieldTargetAmm {
    uint256 internal constant PPM = 1_000_000;

    LpYieldToken public immutable crvUsd;
    LpYieldToken public immutable targetAsset;
    uint256 public quotePricePpm = 1_010_000;
    uint256 public executionPricePpm = 1_010_000;
    uint256 public exchangeCalls;

    constructor(LpYieldToken crvUsd_, LpYieldToken targetAsset_) {
        crvUsd = crvUsd_;
        targetAsset = targetAsset_;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return address(targetAsset);
        require(index == 1, "coin index");
        return address(crvUsd);
    }

    function balances(uint256 index) external view returns (uint256) {
        if (index == 0) return targetAsset.balanceOf(address(this));
        require(index == 1, "coin index");
        return crvUsd.balanceOf(address(this));
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        require(i == 1 && j == 0, "direction");
        return dx * quotePricePpm / PPM / 10 ** (18 - targetAsset.decimals());
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut)
    {
        require(i == 1 && j == 0, "indices");
        exchangeCalls++;
        amountOut = dx * executionPricePpm / PPM / 10 ** (18 - targetAsset.decimals());
        require(amountOut >= minDy, "slippage");
        require(crvUsd.transferFrom(msg.sender, address(this), dx), "transfer in");
        targetAsset.mint(msg.sender, amountOut);
    }
}

contract LpYieldRoutePool {
    LpYieldToken public immutable targetAsset;
    LpYieldToken public immutable yieldToken;
    bool public shouldRevert;

    constructor(LpYieldToken targetAsset_, LpYieldToken yieldToken_) {
        targetAsset = targetAsset_;
        yieldToken = yieldToken_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return address(targetAsset);
        require(index == 1, "coin index");
        return address(yieldToken);
    }

    function get_dy(int128 i, int128 j, uint256 dx) external pure returns (uint256) {
        require(i == 0 && j == 1, "indices");
        return dx * 1e12;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut)
    {
        require(!shouldRevert, "route failed");
        require(i == 0 && j == 1, "indices");
        amountOut = dx * 1e12;
        require(amountOut >= minDy, "slippage");
        require(targetAsset.transferFrom(msg.sender, address(this), dx), "transfer in");
        yieldToken.mint(msg.sender, amountOut);
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
    uint256 public withdrawBonus;
    uint256 public spendBps = 10_000;
    uint256 public addLiquidityCalls;
    uint256 public removeLiquidityCalls;
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

    function setActualWithdrawBps(uint256 value) external {
        actualWithdrawBps = value;
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
        require(isDeposit, "deposit only");
        return (amounts[0] + amounts[1]) * lpMintBps / 10_000;
    }

    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount)
        external
        returns (uint256 minted)
    {
        addLiquidityCalls++;
        require(amounts.length == 2, "two coins");
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
}

contract PegKeeperV3LpYieldTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    LpYieldToken internal crvUsd;
    LpYieldToken internal targetAsset;
    LpYieldToken internal yieldToken;
    LpYieldFactory internal factory;
    LpYieldTargetAmm internal targetAmm;
    LpYieldAmm internal yieldAmm;
    LpYieldRoutePool internal routePool;
    LpYieldOracle internal yieldOracle;
    LpYieldOracle internal aggregateCrvUsdOracle;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        targetAsset = new LpYieldToken(6);
        yieldToken = new LpYieldToken(18);
        aggregateCrvUsdOracle = new LpYieldOracle();
        factory = new LpYieldFactory(
            address(crvUsd), governance, emergencyAdmin, feeReceiver, address(aggregateCrvUsdOracle)
        );
        targetAmm = new LpYieldTargetAmm(crvUsd, targetAsset);
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        routePool = new LpYieldRoutePool(targetAsset, yieldToken);
        yieldOracle = new LpYieldOracle();
    }

    function test_initializePinsYieldAmmAndLpAccountingEndpoints() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        assertTrue(keeper.initialized());
        assertEq(keeper.target_amm(), address(targetAmm));
        assertEq(keeper.target_asset(), address(targetAsset));
        assertEq(keeper.backing_asset(), address(yieldToken));
        assertEq(keeper.yield_token(), address(yieldToken));
        assertEq(keeper.yield_amm(), address(yieldAmm));
        assertEq(keeper.yield_amm_crvusd_index(), 0);
        assertEq(keeper.yield_amm_yield_token_index(), 1);
        assertEq(keeper.accounted_lp_tokens(), 0);
        assertEq(keeper.trusted_backing_value(), 0);
    }

    function test_interventionPolicyDefaultsAndAdminCanSetZeroDelay() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        assertEq(keeper.max_intervention_share_bps(), 3_333);
        assertEq(keeper.min_intervention_delay(), 12);
        assertEq(keeper.last_intervention_at(), 0);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        keeper.set_intervention_policy(5_000, 0);

        vm.prank(governance);
        keeper.set_intervention_policy(5_000, 0);
        assertEq(keeper.max_intervention_share_bps(), 5_000);
        assertEq(keeper.min_intervention_delay(), 0);

        vm.startPrank(governance);
        vm.expectRevert();
        keeper.set_intervention_policy(0, 0);
        vm.expectRevert();
        keeper.set_intervention_policy(10_001, 0);
        vm.stopPrank();
    }

    function test_yieldOraclePolicyDefaultsToTenBasisPointFloorAndAdminCanUpdate() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        assertEq(keeper.yield_oracle(), address(yieldOracle));
        assertEq(keeper.min_yield_oracle_price(), 0.999e18);

        LpYieldOracle replacement = new LpYieldOracle();
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        keeper.set_yield_oracle_policy(address(replacement), 0.998e18);

        vm.prank(governance);
        keeper.set_yield_oracle_policy(address(replacement), 0.998e18);
        assertEq(keeper.yield_oracle(), address(replacement));
        assertEq(keeper.min_yield_oracle_price(), 0.998e18);
    }

    function test_yieldOracleTenBasisPointFloorIsInclusive() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);

        yieldOracle.setPrice(0.999e18);
        keeper.previewExpansion(10_000e18);

        yieldOracle.setPrice(0.999e18 - 1);
        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
        vm.expectRevert();
        keeper.expand(10_000e18);
    }

    function test_lpVirtualPriceIsSoleBackingRateForErc4626YieldToken() public {
        LpYieldToken underlying = new LpYieldToken(18);
        LpYieldVault vault = new LpYieldVault(address(underlying));
        LpYieldAmm vaultAmm = new LpYieldAmm(address(crvUsd), address(vault));
        ILpPegKeeperV3 keeper = _deployKeeperCustom(
            address(vaultAmm),
            address(vault),
            address(underlying),
            address(vault),
            address(vaultAmm)
        );
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
        ILpPegKeeperV3 keeper = _deployKeeperCustom(
            address(vaultAmm),
            address(vault),
            address(underlying),
            address(vault),
            address(vaultAmm)
        );
        ILpPegKeeperV3.RouteStep[] memory empty = new ILpPegKeeperV3.RouteStep[](0);
        vm.startPrank(governance);
        keeper.setPaths(empty, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        vault.setAssetsPerShare(2e18);
        crvUsd.mint(address(vaultAmm), 40_000e18);
        vault.mint(address(vaultAmm), 50_000e18);
        crvUsd.mint(address(keeper), 100_000e18);

        assertEq(keeper.available_expansion(), 60_000e18 * 3_333 / 10_000);
    }

    function test_separateTargetPoolUsesErc4626AssetsForLocalImbalance() public {
        LpYieldToken underlying = new LpYieldToken(18);
        LpYieldVault vault = new LpYieldVault(address(underlying));
        LpYieldTargetAmm vaultTargetAmm = new LpYieldTargetAmm(crvUsd, vault);
        LpYieldAmm vaultYieldAmm = new LpYieldAmm(address(crvUsd), address(vault));
        ILpPegKeeperV3 keeper = _deployKeeperCustom(
            address(vaultTargetAmm),
            address(vault),
            address(underlying),
            address(vault),
            address(vaultYieldAmm)
        );
        ILpPegKeeperV3.RouteStep[] memory empty = new ILpPegKeeperV3.RouteStep[](0);
        vm.startPrank(governance);
        keeper.setPaths(empty, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        vault.setAssetsPerShare(2e18);
        crvUsd.mint(address(vaultTargetAmm), 40_000e18);
        vault.mint(address(vaultTargetAmm), 50_000e18);
        crvUsd.mint(address(keeper), 100_000e18);

        assertEq(keeper.available_expansion(), 60_000e18 * 3_333 / 10_000);
    }

    function test_neutralDonationSettlementDoesNotConsumeInterventionShareOrTimer() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.clearBalancesOverride();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(yieldAmm), 100_000e18);
        yieldToken.mint(address(yieldAmm), 160_000e18);
        crvUsd.mint(address(keeper), 100_000e18);
        yieldToken.mint(address(keeper), 10_000e18);

        keeper.sweepDonatedYield(10_000e18);

        uint256 localLimit = 60_000e18 * 3_333 / 10_000;
        assertEq(keeper.last_intervention_at(), 0);
        assertEq(keeper.available_expansion(), localLimit);
        keeper.previewExpansion(localLimit);
        keeper.expand(localLimit);
    }

    function test_expandRoutesTargetSweepsYieldDonationAndMatchesWithCrvUsd() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));
        ILpPegKeeperV3.RouteStep[] memory expansion = _singleExpansionStep();

        vm.startPrank(governance);
        keeper.setPaths(expansion, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        targetAsset.mint(address(targetAmm), 100_000_000e6);
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        address caller = makeAddr("keeper");
        vm.prank(caller);
        (uint256 sold, uint256 matched, uint256 lpReceived, uint256 reward, bool directDeposit) =
            keeper.expand(10_000e18);

        assertEq(sold, 10_000e18);
        assertEq(matched, 12_100e18);
        assertEq(lpReceived, 24_200e18);
        assertEq(reward, 30e18);
        assertFalse(directDeposit);
        assertEq(yieldAmm.balanceOf(address(keeper)), 24_170e18);
        assertEq(yieldAmm.balanceOf(caller), 30e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 1_900e18);
        assertEq(targetAsset.balanceOf(address(keeper)), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.lastAmounts(0), 12_100e18);
        assertEq(yieldAmm.lastAmounts(1), 12_100e18);
        assertEq(keeper.deployed_crvusd(), 22_100e18);
        assertEq(keeper.expansion_pressure(), 22_100e18);
        assertEq(keeper.trusted_backing_value(), 24_170e18);
    }

    function test_routedExpansionRejectsAboveLocalImbalanceShare() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        targetAsset.burn(address(targetAmm), 100_000_000e6);
        crvUsd.mint(address(targetAmm), 100_000e18);
        targetAsset.mint(address(targetAmm), 160_000e6);
        crvUsd.mint(address(keeper), 100_000e18);

        uint256 localLimit = 60_000e18 * 3_333 / 10_000;
        assertEq(localLimit, 19_998e18);
        assertEq(keeper.available_expansion(), localLimit);

        vm.expectRevert();
        keeper.previewExpansion(localLimit + 1);
        vm.expectRevert();
        keeper.expand(localLimit + 1);
    }

    function test_sameYieldTargetInSeparatePoolSweepsDonation() public {
        LpYieldTargetAmm yieldTargetAmm = new LpYieldTargetAmm(crvUsd, yieldToken);
        ILpPegKeeperV3 keeper = _deployKeeperWithEndpoints(
            address(yieldTargetAmm), address(yieldToken), address(yieldAmm)
        );
        ILpPegKeeperV3.RouteStep[] memory emptyPath = new ILpPegKeeperV3.RouteStep[](0);
        vm.startPrank(governance);
        keeper.setPaths(emptyPath, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();
        yieldToken.mint(address(yieldTargetAmm), 100_000_000e18);
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        keeper.expand(10_000e18);

        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.lastAmounts(0), 12_100e18);
        assertEq(yieldAmm.lastAmounts(1), 12_100e18);
        assertEq(keeper.deployed_crvusd(), 22_100e18);
    }

    function test_expandDepositsCrvUsdDirectlyWhenTargetAndYieldAmmAreSame() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        address caller = makeAddr("directKeeper");
        vm.prank(caller);
        (uint256 sold, uint256 deposited, uint256 lpReceived, uint256 reward, bool directDeposit) =
            keeper.expand(10_000e18);

        assertEq(sold, 0);
        assertEq(deposited, 10_000e18);
        assertEq(lpReceived, 10_001e18);
        assertEq(reward, 0.3e18);
        assertTrue(directDeposit);
        assertEq(yieldAmm.lastAmounts(0), 10_000e18);
        assertEq(yieldAmm.lastAmounts(1), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 10_000.7e18);
        assertEq(yieldAmm.balanceOf(caller), 0.3e18);
        assertEq(keeper.deployed_crvusd(), 10_000e18);
    }

    function test_directExpansionAlsoMatchesAndSweepsYieldDonation() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        (
            uint256 expectedTarget,
            uint256 expectedDeposited,
            uint256 expectedProfit,
            uint256 expectedReward,
            uint256 expectedLp,
            bool expectedDirect
        ) = keeper.previewExpansion(10_000e18);
        assertEq(expectedTarget, 0);
        assertEq(expectedDeposited, 12_000e18);
        assertEq(expectedProfit, 1.4e18);
        assertEq(expectedReward, 0.42e18);
        assertEq(expectedLp, 14_001.4e18);
        assertTrue(expectedDirect);

        vm.prank(makeAddr("keeper"));
        (uint256 sold, uint256 deposited, uint256 lpReceived, uint256 reward, bool direct) =
            keeper.expand(10_000e18);

        assertEq(sold, 0);
        assertEq(deposited, 12_000e18);
        assertEq(lpReceived, 14_001.4e18);
        assertEq(reward, 0.42e18);
        assertTrue(direct);
        assertEq(yieldAmm.lastAmounts(0), 12_000e18);
        assertEq(yieldAmm.lastAmounts(1), 2_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 14_000.98e18);
        assertEq(keeper.deployed_crvusd(), 12_000e18);
    }

    function test_sweepDonatedYieldWorksWithoutTargetTrade() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 25_000e18);

        address caller = makeAddr("donationSweeper");
        vm.prank(caller);
        (uint256 swept, uint256 matched, uint256 lpReceived, uint256 reward) =
            keeper.sweepDonatedYield(12_000e18);

        assertEq(swept, 12_000e18);
        assertEq(matched, 12_000e18);
        assertEq(lpReceived, 24_002.4e18);
        assertEq(reward, 0.72e18);
        assertEq(targetAmm.exchangeCalls(), 0);
        assertEq(yieldAmm.addLiquidityCalls(), 1);
        assertEq(yieldAmm.lastAmounts(0), 12_000e18);
        assertEq(yieldAmm.lastAmounts(1), 12_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 3_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 13_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 24_001.68e18);
        assertEq(yieldAmm.balanceOf(caller), 0.72e18);
        assertEq(keeper.deployed_crvusd(), 12_000e18);
        assertEq(keeper.expansion_pressure(), 12_000e18);
    }

    function test_sweepUsesDonationToAbsorbLpCostWithoutRewardingDonation() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(9_990);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        address caller = makeAddr("donationSweeper");
        vm.prank(caller);
        (uint256 swept, uint256 matched, uint256 lpReceived, uint256 reward) =
            keeper.sweepDonatedYield(12_000e18);

        assertEq(swept, 12_000e18);
        assertEq(matched, 12_000e18);
        assertEq(lpReceived, 23_976e18);
        assertEq(reward, 0);
        assertEq(yieldAmm.balanceOf(caller), 0);
        assertEq(yieldAmm.balanceOf(address(keeper)), 23_976e18);
        assertEq(keeper.deployed_crvusd(), 12_000e18);
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function test_sweepDonationRollsBackWhenYieldAmmDoesNotSpendExactAmounts() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        yieldAmm.setSpendBps(9_999);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.prank(makeAddr("donationSweeper"));
        vm.expectRevert();
        keeper.sweepDonatedYield(12_000e18);

        assertEq(crvUsd.balanceOf(address(keeper)), 12_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.addLiquidityCalls(), 0);
        assertEq(crvUsd.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(yieldToken.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(keeper.expansion_pressure(), 0);
    }

    function test_sweepDonationBelowMinimumDoesNotChangeAccounting() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 9_999e18);
        yieldToken.mint(address(keeper), 9_999e18);

        vm.expectRevert();
        keeper.sweepDonatedYield(type(uint256).max);

        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(keeper.expansion_pressure(), 0);
    }

    function test_sweepDonationIsBlockedByExpansionPause() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));
        vm.prank(governance);
        keeper.set_direction_paused(2, false);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.expectRevert();
        keeper.sweepDonatedYield(12_000e18);

        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
    }

    function test_sweepDonationRejectsUnhealthyYieldToken() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldOracle.setPrice(0.5e18);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);

        vm.expectRevert();
        keeper.sweepDonatedYield(12_000e18);

        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 12_000e18);
    }

    function test_contractViaAmmBurnsLpAndWithdrawsOnlyCrvUsd() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        vm.prank(makeAddr("expansionKeeper"));
        keeper.expand(10_000e18);
        yieldAmm.setBalances(100_000_000e18, 0);

        (uint256 quoted, uint256 grossProfit, uint256 quotedReward) =
            keeper.previewKeeperBuyback(1_000e18);
        assertEq(quoted, 1_010e18);
        assertEq(grossProfit, 10e18);
        assertEq(quotedReward, 3e18);

        address caller = makeAddr("contractionKeeper");
        vm.prank(caller);
        (uint256 burned, uint256 received, uint256 reward) = keeper.contractViaAmm(1_000e18);

        assertEq(burned, 1_000e18);
        assertEq(received, 1_010e18);
        assertEq(reward, 3e18);
        assertEq(yieldAmm.removeLiquidityCalls(), 1);
        assertEq(yieldAmm.balanceOf(address(keeper)), 9_000.7e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 1_007e18);
        assertEq(crvUsd.balanceOf(caller), 3e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(keeper.deployed_crvusd(), 8_993e18);
        assertEq(keeper.trusted_backing_value(), 9_000.7e18);
    }

    function test_previewExpansionIncludesDonationMatchAndLpReward() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        (
            uint256 targetOut,
            uint256 matched,
            uint256 grossProfit,
            uint256 reward,
            uint256 lpOut,
            bool directDeposit
        ) = keeper.previewExpansion(10_000e18);

        assertEq(targetOut, 10_100e6);
        assertEq(matched, 12_100e18);
        assertEq(grossProfit, 100e18);
        assertEq(reward, 30e18);
        assertEq(lpOut, 24_200e18);
        assertFalse(directDeposit);
    }

    function test_routeFailureRollsBackWholeExpansion() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);
        routePool.setShouldRevert(true);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert(bytes("route failed"));
        keeper.expand(10_000e18);

        assertEq(crvUsd.balanceOf(address(keeper)), 24_000e18);
        assertEq(targetAsset.balanceOf(address(keeper)), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 2_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 0);
        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(keeper.expansion_pressure(), 0);
    }

    function test_partialLpDepositRollsBackWholeExpansion() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);
        yieldAmm.setSpendBps(5_000);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        keeper.expand(10_000e18);

        assertEq(crvUsd.balanceOf(address(keeper)), 24_000e18);
        assertEq(targetAsset.balanceOf(address(keeper)), 0);
        assertEq(yieldToken.balanceOf(address(keeper)), 2_000e18);
        assertEq(yieldAmm.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.addLiquidityCalls(), 0);
        assertEq(keeper.deployed_crvusd(), 0);
    }

    function test_matchedCrvUsdCountsAgainstAvailableBalanceAndExposure() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(keeper), 22_099e18);
        yieldToken.mint(address(keeper), 2_000e18);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        keeper.expand(10_000e18);

        assertEq(crvUsd.balanceOf(address(keeper)), 22_099e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 2_000e18);
        assertEq(keeper.deployed_crvusd(), 0);
    }

    function test_contractionEnforcesExecutableOneCoinQuote() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        vm.prank(makeAddr("expansionKeeper"));
        keeper.expand(10_000e18);

        yieldAmm.setBalances(100_000_000e18, 0);
        yieldAmm.setActualWithdrawBps(10_000);
        vm.prank(makeAddr("contractionKeeper"));
        vm.expectRevert(bytes("withdraw slippage"));
        keeper.contractViaAmm(1_000e18);

        assertEq(yieldAmm.balanceOf(address(keeper)), 10_000.7e18);
        assertEq(keeper.deployed_crvusd(), 10_000e18);
        assertEq(crvUsd.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.removeLiquidityCalls(), 0);
    }

    function test_contractionRemainsOpenAfterFactoryCeilingFallsBelowExposure() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);
        factory.setDebtCeiling(address(keeper), 1e18);
        yieldAmm.setBalances(100_000_000e18, 0);

        keeper.contractViaAmm(1_000e18);

        assertLt(keeper.deployed_crvusd(), 10_000e18);
        assertGt(keeper.deployed_crvusd(), factory.debt_ceiling(address(keeper)));
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function test_terminalContractionPaysOnlyCurrentCallExcessToLiveFeeReceiver() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);
        yieldAmm.setBalances(100_000_000e18, 0);

        crvUsd.mint(address(keeper), 100e18);
        address newFeeReceiver = makeAddr("new fee receiver");
        factory.setFeeReceiver(newFeeReceiver);

        uint256 idleBefore = crvUsd.balanceOf(address(keeper));
        uint256 lpAmount = keeper.accounted_lp_tokens();
        uint256 quoted = yieldAmm.calc_withdraw_one_coin(lpAmount, 0);
        uint256 grossProfit = quoted - lpAmount;
        uint256 keeperReward = grossProfit * 3_000 / 10_000;
        uint256 currentCallNet = quoted - keeperReward;
        uint256 expectedTerminalProfit = currentCallNet - keeper.deployed_crvusd();

        keeper.contractViaAmm(lpAmount);

        assertEq(keeper.deployed_crvusd(), 0);
        assertEq(keeper.accounted_lp_tokens(), 0);
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
        keeper.expand(10_000e18);

        yieldAmm.setBalances(100_000_000e18, 0);
        yieldAmm.setWithdrawBps(10_005);
        uint256 deployedBefore = keeper.deployed_crvusd();
        (uint256 expectedCrvUsd, uint256 grossProfit, uint256 expectedReward) =
            keeper.previewKeeperBuyback(1_000e18);
        assertEq(expectedCrvUsd, 1_000e18 + 5e17);
        assertEq(grossProfit, 5e17);
        assertEq(expectedReward, 15e16);

        uint256 keeperBalanceBefore = crvUsd.balanceOf(address(this));
        (uint256 lpBurned, uint256 crvUsdReceived, uint256 keeperReward) =
            keeper.contractViaAmm(1_000e18);

        assertEq(lpBurned, 1_000e18);
        assertEq(crvUsdReceived, expectedCrvUsd);
        assertEq(keeperReward, expectedReward);
        assertEq(crvUsd.balanceOf(address(this)) - keeperBalanceBefore, 15e16);
        assertEq(deployedBefore - keeper.deployed_crvusd(), 1_000e18 + 35e16);
    }

    function test_contractionRejectsQuoteAboveLocalImbalanceShare() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        yieldAmm.setBalances(130_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        vm.expectRevert();
        keeper.previewKeeperBuyback(10_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(10_000e18);
    }

    function test_contractionRejectsMeasuredReceiptAboveLocalImbalanceShare() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(5_000, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        // 50% of the 20,010 crvUSD excess is 10,005. Preview is exactly at the cap,
        // but execution returns one basis point more and must revert instead of overshooting.
        yieldAmm.setBalances(120_010e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        yieldAmm.setActualWithdrawBps(10_006);
        keeper.previewKeeperBuyback(10_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(10_000e18);
    }

    function test_contractionAcceptsQuoteAndReceiptExactlyAtLocalImbalanceShare() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(5_000, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        yieldAmm.setBalances(120_010e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        (uint256 expectedCrvUsd,,) = keeper.previewKeeperBuyback(10_000e18);
        assertEq(expectedCrvUsd, 10_005e18);

        (, uint256 actualCrvUsd,) = keeper.contractViaAmm(10_000e18);
        assertEq(actualCrvUsd, 10_005e18);
    }

    function test_interventionDelayIsSharedAcrossExpansionAndContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 12);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 30_000e18);
        uint256 firstInterventionAt = block.timestamp;
        keeper.expand(10_000e18);
        assertEq(keeper.last_intervention_at(), firstInterventionAt);

        yieldAmm.setBalances(120_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);

        vm.warp(firstInterventionAt + 11);
        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);

        vm.warp(firstInterventionAt + 12);
        keeper.previewKeeperBuyback(1_000e18);
        keeper.contractViaAmm(1_000e18);
        assertEq(keeper.last_intervention_at(), firstInterventionAt + 12);

        yieldAmm.setBalances(0, 100_000e18);
        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
    }

    function test_zeroInterventionDelayAllowsSameTimestampContraction() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        vm.prank(governance);
        keeper.set_intervention_policy(3_333, 0);
        yieldAmm.setBalances(0, 100_000e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        uint256 interventionAt = block.timestamp;
        keeper.expand(10_000e18);
        yieldAmm.setBalances(120_000e18, 100_000e18);
        yieldAmm.setWithdrawBps(10_005);
        keeper.previewKeeperBuyback(1_000e18);
        keeper.contractViaAmm(1_000e18);

        assertEq(keeper.last_intervention_at(), interventionAt);
    }

    function test_previewAndExecutionRejectOneWeiBelowGrossExitMargin() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        yieldAmm.setWithdrawBps(10_000);
        yieldAmm.setWithdrawBonus(5e17 - 1);
        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);
    }

    function test_previewKeeperBuybackRejectsFinalInsolvency() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        yieldAmm.setVirtualPrice(0.9e18);
        yieldAmm.setWithdrawBps(10_000);
        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);
    }

    function test_deficitRecoveryDoesNotCountTowardGrossExitMargin() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);

        // Burning 1,000 LP removes 900 of trusted value. The 1,899.37 principal-recovery
        // basis includes the existing deficit, leaving only 0.43 gross profit: below 5 bp.
        yieldAmm.setVirtualPrice(0.9e18);
        yieldAmm.setWithdrawBps(18_998);
        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);
    }

    function test_previewAndExecutionRejectOversizedYieldOracleReturn() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        LpYieldOversizedOracle oversizedOracle = new LpYieldOversizedOracle();
        vm.prank(governance);
        keeper.set_yield_oracle_policy(address(oversizedOracle), 0.999e18);
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);

        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
        vm.expectRevert();
        keeper.expand(10_000e18);
    }

    function test_aggregateCrvUsdPriceGatesExpansionAtOneDollar() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 20_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        assertEq(keeper.available_expansion(), 0);
        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
        vm.expectRevert();
        keeper.expand(10_000e18);

        aggregateCrvUsdOracle.setPrice(1e18);
        assertGt(keeper.available_expansion(), 0);
        keeper.expand(10_000e18);
    }

    function test_sameBlockRoutedExpansionCannotRoundTripWithoutExitEdge() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 25_000e18);
        keeper.expand(10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);
        yieldAmm.setWithdrawBps(10_000);

        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);
    }

    function test_sameBlockDonationSweepCannotRoundTripWithoutExitEdge() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 12_000e18);
        yieldToken.mint(address(keeper), 12_000e18);
        keeper.sweepDonatedYield(12_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);
        yieldAmm.setWithdrawBps(10_000);

        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);
    }

    function test_contractionRegimeSmallDonationIsEntirelyOneSided() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 500_000e18);
        yieldToken.mint(address(yieldAmm), 450_000e18);
        yieldToken.mint(address(keeper), 40_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        (uint256 swept, uint256 matched,,) = keeper.sweepDonatedYield(40_000e18);

        assertEq(swept, 40_000e18);
        assertEq(matched, 0);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 500_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 490_000e18);
        assertEq(keeper.deployed_crvusd(), 0);
    }

    function test_expansionRegimeDonationSweepMatchesFullDonation() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 10_000e18);
        yieldToken.mint(address(keeper), 10_000e18);

        (uint256 swept, uint256 matched,,) = keeper.sweepDonatedYield(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 10_000e18);
        assertEq(keeper.deployed_crvusd(), 10_000e18);
    }

    function test_aggregateCrvUsdPriceGatesContractionAtOneDollar() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        keeper.expand(10_000e18);
        yieldAmm.setBalances(100_000_000e18, 0);
        aggregateCrvUsdOracle.setPrice(1e18 + 1);

        vm.expectRevert();
        keeper.previewKeeperBuyback(1_000e18);
        vm.expectRevert();
        keeper.contractViaAmm(1_000e18);

        aggregateCrvUsdOracle.setPrice(1e18);
        keeper.previewKeeperBuyback(1_000e18);
        keeper.contractViaAmm(1_000e18);
    }

    function test_malformedAggregateOracleFailsPreviewAndExecutionClosed() public {
        ILpPegKeeperV3 keeper = _configuredDirectKeeper();
        LpYieldOversizedOracle malformedOracle = new LpYieldOversizedOracle();
        factory.setAggregateCrvUsdOracle(address(malformedOracle));
        crvUsd.mint(address(keeper), 25_000e18);
        yieldAmm.mint(address(keeper), 1_000e18);

        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
        vm.expectRevert();
        keeper.expand(10_000e18);
        vm.expectRevert();
        keeper.previewKeeperBuyback(100e18);
        vm.expectRevert();
        keeper.contractViaAmm(100e18);
    }

    function test_contractionRegimeDonationSweepMatchesOnlyOvershoot() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 5_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        (uint256 swept, uint256 matched,,) = keeper.sweepDonatedYield(10_000e18);

        assertEq(swept, 10_000e18);
        assertEq(matched, 5_000e18);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(keeper.deployed_crvusd(), 5_000e18);
    }

    function test_claimSurplusSweepsDonationBeforeClaimDuringContractionRegime() public {
        ILpPegKeeperV3 keeper = _configuredNormalKeeper();
        crvUsd.mint(address(yieldAmm), 50_000e18);
        yieldToken.mint(address(yieldAmm), 45_000e18);
        crvUsd.mint(address(keeper), 15_000e18);
        yieldToken.mint(address(keeper), 10_000e18);
        aggregateCrvUsdOracle.setPrice(1e18 - 1);

        uint256 claimed = keeper.claimSurplus(10_000e18);

        assertEq(claimed, 10_000e18);
        assertEq(crvUsd.balanceOf(feeReceiver), 10_000e18);
        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(crvUsd.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(yieldToken.balanceOf(address(yieldAmm)), 55_000e18);
        assertEq(keeper.deployed_crvusd(), 15_000e18);
        assertEq(keeper.expansion_pressure(), 15_000e18);
    }

    function test_unauthorizedPathChangesAndEmergencyUnpauseAreRejected() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        keeper.setPaths(_singleExpansionStep(), 100);
        assertEq(keeper.expansion_path_length(), 0);

        vm.prank(emergencyAdmin);
        vm.expectRevert();
        keeper.set_direction_paused(2, false);

        vm.prank(emergencyAdmin);
        keeper.set_direction_paused(2, true);
    }

    function test_obsoleteOracleContractionPathAndUndeployedSurfaceIsRemoved() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        (bool targetOracleGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("target_oracle()"));
        (bool targetFloorGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("min_target_oracle_price()"));
        (bool contractionPathGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("contraction_path_length()"));
        (bool undeployedGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("undeployed_backing()"));
        (bool looseYieldGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("accounted_yield_token_units()"));
        (bool backingPauseGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("backing_deployment_paused()"));
        (bool earlyMarginGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("early_exit_min_profit_ppm()"));
        (bool deploymentTimeGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("min_deployment_time()"));
        (bool lastExpansionGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("last_expansion_at()"));

        assertFalse(targetOracleGetter);
        assertFalse(targetFloorGetter);
        assertFalse(contractionPathGetter);
        assertFalse(undeployedGetter);
        assertFalse(looseYieldGetter);
        assertFalse(backingPauseGetter);
        assertFalse(earlyMarginGetter);
        assertFalse(deploymentTimeGetter);
        assertFalse(lastExpansionGetter);

        vm.prank(governance);
        (bool oldOracleSetter,) = address(keeper)
            .call(
                abi.encodeWithSignature(
                    "set_oracles(address,address,uint256,uint256)",
                    address(yieldOracle),
                    address(yieldOracle),
                    1e18,
                    1e18
                )
            );
        assertFalse(oldOracleSetter);

        ILpPegKeeperV3.RouteStep[] memory obsoleteFraxRedemption = _singleExpansionStep();
        obsoleteFraxRedemption[0].kind = 5;
        vm.prank(governance);
        vm.expectRevert();
        keeper.setPaths(obsoleteFraxRedemption, 100);

        ILpPegKeeperV3.RouteStep[] memory crvUsdLoop = new ILpPegKeeperV3.RouteStep[](2);
        crvUsdLoop[0] = ILpPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(targetAmm),
            tokenIn: address(targetAsset),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 0
        });
        crvUsdLoop[1] = ILpPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(yieldAmm),
            tokenIn: address(crvUsd),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 0
        });
        vm.prank(governance);
        vm.expectRevert();
        keeper.setPaths(crvUsdLoop, 100);
    }

    function _configuredNormalKeeper() internal returns (ILpPegKeeperV3 keeper) {
        keeper = _deployKeeper(address(targetAmm));
        targetAsset.mint(address(targetAmm), 100_000_000e6);
        vm.startPrank(governance);
        keeper.setPaths(_singleExpansionStep(), 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_intervention_policy(3_333, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function _configuredDirectKeeper() internal returns (ILpPegKeeperV3 keeper) {
        keeper =
            _deployKeeperWithEndpoints(address(yieldAmm), address(yieldToken), address(yieldAmm));
        ILpPegKeeperV3.RouteStep[] memory empty = new ILpPegKeeperV3.RouteStep[](0);
        vm.startPrank(governance);
        keeper.setPaths(empty, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_intervention_policy(3_333, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        keeper.set_direction_paused(1, false);
        vm.stopPrank();
        yieldAmm.setBalances(0, 100_000_000e18);
    }

    function _singleExpansionStep()
        internal
        view
        returns (ILpPegKeeperV3.RouteStep[] memory expansion)
    {
        expansion = new ILpPegKeeperV3.RouteStep[](1);
        expansion[0] = ILpPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(routePool),
            tokenIn: address(targetAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 0
        });
    }

    function _deployKeeper(address targetAmm_) internal returns (ILpPegKeeperV3 keeper) {
        keeper = _deployKeeperWithEndpoints(targetAmm_, address(targetAsset), address(yieldAmm));
    }

    function _deployKeeperWithEndpoints(address targetAmm_, address targetAsset_, address yieldAmm_)
        internal
        returns (ILpPegKeeperV3 keeper)
    {
        keeper = _deployKeeperCustom(
            targetAmm_, targetAsset_, address(yieldToken), address(yieldToken), yieldAmm_
        );
    }

    function _deployKeeperCustom(
        address targetAmm_,
        address targetAsset_,
        address backingAsset_,
        address yieldToken_,
        address yieldAmm_
    ) internal returns (ILpPegKeeperV3 keeper) {
        bytes memory previewCreationCode = vm.getCode(
            "out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json"
        );
        address previewModule;
        assembly ("memory-safe") {
            previewModule := create(0, add(previewCreationCode, 0x20), mload(previewCreationCode))
            if iszero(previewModule) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        bytes memory keeperCreationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory keeperInitCode = bytes.concat(keeperCreationCode, abi.encode(previewModule));
        address implementation;
        assembly ("memory-safe") {
            implementation := create(0, add(keeperInitCode, 0x20), mload(keeperInitCode))
            if iszero(implementation) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        bytes memory proxyInitCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        address proxy;
        assembly ("memory-safe") {
            proxy := create(0, add(proxyInitCode, 0x20), mload(proxyInitCode))
            if iszero(proxy) { revert(0, 0) }
        }

        keeper = ILpPegKeeperV3(proxy);
        vm.prank(address(factory));
        keeper.initialize(
            targetAmm_,
            targetAsset_,
            backingAsset_,
            yieldToken_,
            yieldAmm_,
            MAX_DEPLOYED,
            1,
            address(yieldOracle)
        );
        factory.setDebtCeiling(proxy, MAX_DEPLOYED);
    }
}
