// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPegKeeperV3} from "./interfaces/IPegKeeperV3.sol";

interface IPreviewToken {
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint256);
}

interface IPreviewPool {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface IPreviewControllerFactory {
    function debt_ceiling(address keeper) external view returns (uint256);
}

interface IPreviewYieldToken {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IPreviewOracle {
    function price() external view returns (uint256);
}

interface IPreviewCurveRoute {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface IPreviewErc4626Route {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

/// @notice Shared stateless quote engine for PegKeeperV3 minimal proxies.
/// @dev Keepers preserve their public preview selectors and forward only view computation here.
contract PegKeeperV3PreviewModule {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant PRECISION = 1e18;

    uint256 internal constant STEP_CURVE_SWAP = 0;
    uint256 internal constant STEP_DAI_USDS_CONVERTER = 1;
    uint256 internal constant STEP_ERC4626_DEPOSIT = 2;
    uint256 internal constant STEP_FRXUSD_MINT = 4;

    struct ExpansionRoutePreview {
        uint256 backingAssetOut;
        uint256 grossProfit;
        uint256 keeperReward;
        uint256 yieldTokenOut;
        bool deployToYield;
    }

    struct ExpansionPreview {
        uint256 targetOut;
        uint256 backingAssetOut;
        uint256 grossProfit;
        uint256 keeperReward;
        uint256 yieldTokenOut;
        bool deployToYield;
    }

    function previewUndeployedContraction(address keeper_, uint256 targetAmount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit)
    {
        require(keeper_ == msg.sender);
        IPegKeeperV3 keeper = IPegKeeperV3(keeper_);
        require(targetAmount > 0 && targetAmount <= keeper.undeployed_backing());

        expectedCrvUsd = IPreviewPool(keeper.target_amm())
            .get_dy(
                int128(uint128(keeper.target_amm_target_index())),
                int128(uint128(keeper.target_amm_crvusd_index())),
                targetAmount
            );
        uint256 targetValue = _normalize(targetAmount, keeper.target_asset());
        uint256 trustedBackingAfter = keeper.trusted_backing_value() - targetValue;
        grossProfit =
            _realizedContractionProfit(keeper, expectedCrvUsd, targetValue, trustedBackingAfter);
        keeperReward = grossProfit * keeper.keeper_profit_share_bps() / BPS;
        earlyExit = _isEarlyExit(keeper);
    }

    function previewKeeperBuyback(address keeper_, uint256 yieldTokenAmount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit)
    {
        require(keeper_ == msg.sender);
        IPegKeeperV3 keeper = IPegKeeperV3(keeper_);
        uint256 accounted = keeper.accounted_yield_token_units();
        require(yieldTokenAmount > 0 && yieldTokenAmount <= accounted);
        uint256 pathLength = keeper.contraction_path_length();
        require(pathLength > 0);

        uint256 trustedBefore = _trustedYieldValue(keeper, accounted);
        uint256 trustedAfter = _trustedYieldValue(keeper, accounted - yieldTokenAmount);
        uint256 trustedRemoved = trustedBefore - trustedAfter;
        require(trustedRemoved <= keeper.deployed_crvusd());

        expectedCrvUsd = yieldTokenAmount;
        for (uint256 i; i < pathLength; ++i) {
            expectedCrvUsd = _previewRouteStep(keeper.contraction_path_step(i), expectedCrvUsd);
        }
        uint256 trustedBackingAfter = keeper.trusted_backing_value() - trustedRemoved;
        grossProfit =
            _realizedContractionProfit(keeper, expectedCrvUsd, trustedRemoved, trustedBackingAfter);
        keeperReward = grossProfit * keeper.keeper_profit_share_bps() / BPS;
        earlyExit = _isEarlyExit(keeper);
    }

    function previewExpansion(address keeper_, uint256 crvUsdAmount)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, bool)
    {
        require(keeper_ == msg.sender);
        ExpansionPreview memory quote = _previewExpansion(keeper_, crvUsdAmount);
        return (
            quote.targetOut,
            quote.backingAssetOut,
            quote.grossProfit,
            quote.keeperReward,
            quote.yieldTokenOut,
            quote.deployToYield
        );
    }

    function _previewExpansion(address keeper_, uint256 crvUsdAmount)
        internal
        view
        returns (ExpansionPreview memory quote)
    {
        IPegKeeperV3 keeper = IPegKeeperV3(keeper_);
        require(crvUsdAmount >= keeper.min_expansion_amount());
        require(crvUsdAmount <= IPreviewToken(keeper.crv_usd()).balanceOf(keeper_));
        require(crvUsdAmount <= keeper.available_expansion_velocity());
        uint256 deployedAfter = keeper.deployed_crvusd() + crvUsdAmount;
        require(deployedAfter <= keeper.max_deployed_crvusd());
        require(
            deployedAfter
                <= IPreviewControllerFactory(keeper.controller_factory()).debt_ceiling(keeper_)
        );

        uint256 targetPrice = IPreviewOracle(keeper.target_oracle()).price();
        require(targetPrice >= keeper.min_target_oracle_price());
        quote.targetOut = IPreviewPool(keeper.target_amm())
            .get_dy(
                int128(uint128(keeper.target_amm_crvusd_index())),
                int128(uint128(keeper.target_amm_target_index())),
                crvUsdAmount
            );
        ExpansionRoutePreview memory route =
            _previewExpansionRoute(keeper, quote.targetOut, crvUsdAmount, targetPrice);
        quote.backingAssetOut = route.backingAssetOut;
        quote.grossProfit = route.grossProfit;
        quote.keeperReward = route.keeperReward;
        quote.yieldTokenOut = route.yieldTokenOut;
        quote.deployToYield = route.deployToYield;
        uint256 trustedBackingBefore = keeper.trusted_backing_value();
        if (quote.deployToYield) {
            require(
                trustedBackingBefore + _trustedYieldValue(keeper, quote.yieldTokenOut)
                    >= deployedAfter
            );
            return quote;
        }

        uint256 targetMultiplier = _multiplier(keeper.target_asset());
        uint256 targetValue = _oracleValue(quote.targetOut * targetMultiplier, targetPrice);
        quote.grossProfit = targetValue > crvUsdAmount ? targetValue - crvUsdAmount : 0;
        quote.keeperReward =
            (quote.grossProfit * keeper.keeper_profit_share_bps() / BPS) / targetMultiplier;
        require(quote.keeperReward <= quote.targetOut);
        uint256 retained = quote.targetOut - quote.keeperReward;
        require(
            _meetsEntryFloor(
                keeper, _oracleValue(retained * targetMultiplier, targetPrice), crvUsdAmount
            )
        );
        require(trustedBackingBefore + retained * targetMultiplier >= deployedAfter);
        quote.backingAssetOut = 0;
        quote.yieldTokenOut = 0;
    }

    function _previewExpansionRoute(
        IPegKeeperV3 keeper,
        uint256 targetAmount,
        uint256 crvUsdAmount,
        uint256 targetPrice
    ) internal view returns (ExpansionRoutePreview memory quote) {
        uint256 pathLength = keeper.expansion_path_length();
        if (pathLength == 0) return quote;
        (uint256 yieldPrice, bool healthy) = _readYieldPrice(keeper);
        if (!healthy) return quote;

        uint256 amountOut = targetAmount;
        uint256 backingMultiplier = _multiplier(keeper.backing_asset());
        for (uint256 i; i < pathLength; ++i) {
            IPegKeeperV3.RouteStep memory step = keeper.expansion_path_step(i);
            if (i == pathLength - 1) {
                quote.backingAssetOut = amountOut;
                uint256 backingValue =
                    _oracleValue(quote.backingAssetOut * backingMultiplier, yieldPrice);
                quote.grossProfit = backingValue > crvUsdAmount ? backingValue - crvUsdAmount : 0;
                quote.keeperReward = _backingReward(keeper, quote.grossProfit, backingMultiplier);
                if (quote.keeperReward > quote.backingAssetOut) return quote;
                amountOut = quote.backingAssetOut - quote.keeperReward;
            }
            amountOut = _previewRouteStep(step, amountOut);
        }
        quote.yieldTokenOut = amountOut;
        if (quote.yieldTokenOut == 0) return quote;

        uint256 trustedYieldValue =
            _oracleValue(_trustedYieldValue(keeper, quote.yieldTokenOut), yieldPrice);
        uint256 targetValue =
            _oracleValue(targetAmount * _multiplier(keeper.target_asset()), targetPrice);
        uint256 retainedRouteValue =
            trustedYieldValue + _oracleValue(quote.keeperReward * backingMultiplier, yieldPrice);
        uint256 conversionCost =
            targetValue > retainedRouteValue ? targetValue - retainedRouteValue : 0;
        if (conversionCost > targetValue * keeper.expansion_max_route_loss_bps() / BPS) {
            return quote;
        }
        if (!_meetsEntryFloor(keeper, trustedYieldValue, crvUsdAmount)) return quote;
        quote.deployToYield = true;
    }

    function _backingReward(IPegKeeperV3 keeper, uint256 grossProfit, uint256 backingMultiplier)
        internal
        view
        returns (uint256)
    {
        return (grossProfit * keeper.keeper_profit_share_bps() / BPS) / backingMultiplier;
    }

    function _previewRouteStep(IPegKeeperV3.RouteStep memory step, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (step.kind == STEP_CURVE_SWAP) {
            return
                IPreviewCurveRoute(step.venue).get_dy(step.poolIndexIn, step.poolIndexOut, amountIn);
        }
        if (step.kind == STEP_DAI_USDS_CONVERTER) return amountIn;
        if (step.kind == STEP_ERC4626_DEPOSIT || step.kind == STEP_FRXUSD_MINT) {
            return IPreviewErc4626Route(step.venue).previewDeposit(amountIn);
        }
        return IPreviewErc4626Route(step.venue).previewRedeem(amountIn);
    }

    function _readYieldPrice(IPegKeeperV3 keeper)
        internal
        view
        returns (uint256 price, bool healthy)
    {
        (bool ok, bytes memory response) =
            keeper.yield_oracle().staticcall(abi.encodeCall(IPreviewOracle.price, ()));
        if (!ok || response.length != 32) return (0, false);
        price = abi.decode(response, (uint256));
        healthy = price >= keeper.min_yield_oracle_price();
    }

    function _trustedYieldValue(IPegKeeperV3 keeper, uint256 shares)
        internal
        view
        returns (uint256)
    {
        return IPreviewYieldToken(keeper.yield_token()).convertToAssets(shares)
            * _multiplier(keeper.backing_asset());
    }

    function _realizedContractionProfit(
        IPegKeeperV3 keeper,
        uint256 received,
        uint256 trustedRemoved,
        uint256 trustedBackingAfter
    ) internal view returns (uint256) {
        uint256 principalRecovery = trustedRemoved;
        uint256 deployed = keeper.deployed_crvusd();
        if (deployed > trustedBackingAfter) {
            uint256 solvencyRecovery = deployed - trustedBackingAfter;
            if (solvencyRecovery > principalRecovery) principalRecovery = solvencyRecovery;
        }
        return received > principalRecovery ? received - principalRecovery : 0;
    }

    function _meetsEntryFloor(IPegKeeperV3 keeper, uint256 retainedValue, uint256 principal)
        internal
        view
        returns (bool)
    {
        if (retainedValue < principal) return false;
        uint256 profit = retainedValue - principal;
        uint256 ppm = keeper.entry_min_profit_ppm();
        uint256 required = principal / PPM * ppm + principal % PPM * ppm / PPM;
        return profit >= required;
    }

    function _isEarlyExit(IPegKeeperV3 keeper) internal view returns (bool) {
        return keeper.deployed_crvusd() > 0
            && block.timestamp < keeper.last_expansion_at() + keeper.min_deployment_time();
    }

    function _normalize(uint256 amount, address token) internal view returns (uint256) {
        return amount * _multiplier(token);
    }

    function _multiplier(address token) internal view returns (uint256) {
        uint256 decimals = IPreviewToken(token).decimals();
        require(decimals <= 18);
        return 10 ** (18 - decimals);
    }

    function _oracleValue(uint256 value, uint256 price) internal pure returns (uint256) {
        uint256 cappedPrice = price > PRECISION ? PRECISION : price;
        return value / PRECISION * cappedPrice + value % PRECISION * cappedPrice / PRECISION;
    }
}
