// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract OutOfRangeHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    struct UnlockCallData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams modifyLiquidityParams;
    }

    struct UnlockCallbackData {
        uint256 absAmount0;
        uint256 absAmount1;
    }

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // TODO: Implement moving liquidity back and forth between pool and lending protocol on tick shift.

        return (this.afterSwap.selector, 0);
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        returns (uint128, uint256, uint256)
    {
        // (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
        //     sqrtPriceX96,
        //     TickMath.getSqrtPriceAtTick(tickLower),
        //     TickMath.getSqrtPriceAtTick(tickUpper),
        //     amount0,
        //     amount1
        // );

        // (uint256 trueAmount0, uint256 trueAmount1) = LiquidityAmounts.getAmountsForLiquidity(
        //     sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
        // );

        (uint128 liquidityDelta, uint256 trueAmount0, uint256 trueAmount1) =
            _calculateAmountsAndLiquidity(key, tickLower, tickUpper, amount0, amount1);

        IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), trueAmount0);
        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), trueAmount1);

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidityDelta)), bytes32(0));

        UnlockCallData memory unlockData = UnlockCallData(key, params);

        poolManager.unlock(abi.encode(unlockData));

        return (liquidityDelta, trueAmount0, trueAmount1);
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint128, uint256, uint256)
    {
        // TODO: Add validation for whether the user actually has that liquidity.

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), bytes32(0));

        UnlockCallData memory unlockData = UnlockCallData(key, params);
        UnlockCallbackData memory callbackData = abi.decode(poolManager.unlock(abi.encode(unlockData)), (UnlockCallbackData));

        if (callbackData.absAmount0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, callbackData.absAmount0);
        }
        if (callbackData.absAmount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, callbackData.absAmount1);
        }

        return (liquidity, callbackData.absAmount0, callbackData.absAmount1);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        UnlockCallData memory unlockData = abi.decode(data, (UnlockCallData));

        (BalanceDelta balanceDelta,) =
            poolManager.modifyLiquidity(unlockData.key, unlockData.modifyLiquidityParams, new bytes(0));

        (uint256 absAmount0, uint256 absAmount1) = _settleAndTakeBalances(unlockData.key.currency0, unlockData.key.currency1, balanceDelta);

        UnlockCallbackData memory callbackData = UnlockCallbackData(absAmount0, absAmount1);

        return (abi.encode(callbackData));
    }

    function _settleAndTakeBalances(Currency currency0, Currency currency1, BalanceDelta balanceDelta)
        internal
        returns (uint256 absAmount0, uint256 absAmount1)
    {
        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        if (amount0 < 0) {
            absAmount0 = uint256(uint128(-amount0));
            _settle(currency0, absAmount0);
        } else if (amount0 > 0) {
            absAmount0 = uint256(uint128(amount0));
            _take(currency0, absAmount0);
        }

        if (amount1 < 0) {
            absAmount1 = uint256(uint128(-amount1));
            _settle(currency1, absAmount1);
        } else if (amount1 > 0) {
            absAmount1 = uint256(uint128(amount1));
            _take(currency1, absAmount1);
        }
    }

    function _settle(Currency currency, uint256 amount) internal {
        // Transfer tokens to the PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint256 amount) internal {
        // Transfer tokens from the PM
        poolManager.take(currency, address(this), amount);
    }

    function _calculateAmountsAndLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint128 liquidityDelta, uint256 trueAmount0, uint256 trueAmount1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        (trueAmount0, trueAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
        );
    }
}
