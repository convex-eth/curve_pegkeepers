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
        address targetOracle,
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
    function expansion_pressure() external view returns (uint256);
    function expansion_path_length() external view returns (uint256);
    function setPaths(RouteStep[] calldata expansion, uint256 expansionMaxRouteLossBps) external;
    function set_expansion_config(
        uint256 targetAmmExecutionBufferBps,
        uint256 yieldAmmExecutionBufferBps
    ) external;
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
    function previewKeeperBuyback(uint256 lpTokenAmount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit);
    function contractViaAmm(uint256 lpTokenAmount)
        external
        returns (uint256 lpTokensBurned, uint256 crvUsdReceived, uint256 keeperReward);
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

contract LpYieldFactory {
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

    function setDebtCeiling(address keeper, uint256 amount) external {
        debt_ceiling[keeper] = amount;
    }

    function setFeeReceiver(address receiver) external {
        fee_receiver = receiver;
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
    uint256 public spendBps = 10_000;
    uint256 public addLiquidityCalls;
    uint256 public removeLiquidityCalls;
    uint256[2] public lastAmounts;

    constructor(address coin0, address coin1) LpYieldToken(18) {
        _coins = [coin0, coin1];
    }

    function coins(uint256 index) external view returns (address) {
        return _coins[index];
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
        return lpTokens * withdrawBps / 10_000;
    }

    function remove_liquidity_one_coin(uint256 lpTokens, int128 index, uint256 minAmount)
        external
        returns (uint256 amountOut)
    {
        require(index == 0, "crvUSD only");
        removeLiquidityCalls++;
        amountOut = lpTokens * actualWithdrawBps / 10_000;
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
    LpYieldOracle internal targetOracle;
    LpYieldOracle internal yieldOracle;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        targetAsset = new LpYieldToken(6);
        yieldToken = new LpYieldToken(18);
        factory = new LpYieldFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        targetAmm = new LpYieldTargetAmm(crvUsd, targetAsset);
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        routePool = new LpYieldRoutePool(targetAsset, yieldToken);
        targetOracle = new LpYieldOracle();
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

    function test_expandRoutesTargetSweepsYieldDonationAndMatchesWithCrvUsd() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));
        ILpPegKeeperV3.RouteStep[] memory expansion = _singleExpansionStep();

        vm.startPrank(governance);
        keeper.setPaths(expansion, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

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
        crvUsd.mint(address(keeper), 24_000e18);
        yieldToken.mint(address(keeper), 2_000e18);

        keeper.expand(10_000e18);

        assertEq(yieldToken.balanceOf(address(keeper)), 0);
        assertEq(yieldAmm.lastAmounts(0), 12_100e18);
        assertEq(yieldAmm.lastAmounts(1), 12_100e18);
        assertEq(keeper.deployed_crvusd(), 22_100e18);
    }

    function test_expandDepositsCrvUsdDirectlyWhenTargetAndYieldAmmAreSame() public {
        ILpPegKeeperV3 keeper =
            _deployKeeperWithEndpoints(address(yieldAmm), address(yieldToken), address(yieldAmm));
        ILpPegKeeperV3.RouteStep[] memory empty = new ILpPegKeeperV3.RouteStep[](0);

        vm.startPrank(governance);
        keeper.setPaths(empty, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

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

    function test_contractViaAmmBurnsLpAndWithdrawsOnlyCrvUsd() public {
        ILpPegKeeperV3 keeper =
            _deployKeeperWithEndpoints(address(yieldAmm), address(yieldToken), address(yieldAmm));
        ILpPegKeeperV3.RouteStep[] memory empty = new ILpPegKeeperV3.RouteStep[](0);
        vm.startPrank(governance);
        keeper.setPaths(empty, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        keeper.set_direction_paused(1, false);
        vm.stopPrank();

        yieldAmm.setLpMintBps(10_001);
        crvUsd.mint(address(keeper), 10_000e18);
        vm.prank(makeAddr("expansionKeeper"));
        keeper.expand(10_000e18);

        (uint256 quoted, uint256 grossProfit, uint256 quotedReward, bool earlyExit) =
            keeper.previewKeeperBuyback(1_000e18);
        assertEq(quoted, 1_010e18);
        assertEq(grossProfit, 10e18);
        assertEq(quotedReward, 3e18);
        assertTrue(earlyExit);

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
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));
        vm.prank(governance);
        keeper.setPaths(_singleExpansionStep(), 100);
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

    function test_obsoleteContractionPathAndUndeployedGettersAreRemoved() public {
        ILpPegKeeperV3 keeper = _deployKeeper(address(targetAmm));

        (bool contractionPathGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("contraction_path_length()"));
        (bool undeployedGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("undeployed_backing()"));
        (bool looseYieldGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("accounted_yield_token_units()"));
        (bool backingPauseGetter,) =
            address(keeper).staticcall(abi.encodeWithSignature("backing_deployment_paused()"));

        assertFalse(contractionPathGetter);
        assertFalse(undeployedGetter);
        assertFalse(looseYieldGetter);
        assertFalse(backingPauseGetter);

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
        vm.startPrank(governance);
        keeper.setPaths(_singleExpansionStep(), 100);
        keeper.set_expansion_config(0, 0);
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
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        keeper.set_direction_paused(1, false);
        vm.stopPrank();
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
            address(targetOracle),
            address(yieldOracle)
        );
        factory.setDebtCeiling(proxy, MAX_DEPLOYED);
    }
}
