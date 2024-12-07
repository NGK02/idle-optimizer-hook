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
import {MinHeapLib} from "solady/utils/MinHeapLib.sol";

contract OutOfRangeHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using MinHeapLib for MinHeapLib.Heap;

    struct UnlockCallData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams modifyLiquidityParams;
    }

    struct UnlockCallbackData {
        uint256 absAmount0;
        uint256 absAmount1;
    }

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address owner;
        PoolKey key;
    }

    // Offset to shift `int24` into `uint256` range.
    uint256 constant OFFSET = 1 << 23;
    uint256 constant ITERATION_LIMIT = 200;

    // These 2 probably don't need to have an outer mapping by poolId since the hash already contains the `PoolKey`.
    mapping(PoolId poolId => mapping(bytes32 positionHash => Position position)) private posByHash;
    mapping(PoolId poolId => mapping(bytes32 positionHash => bool isActive)) private posStateByHash;

    mapping(PoolId poolId => mapping(int24 tickLower => bytes32[] positionHashes)) private activePosHashesByTickLower;
    mapping(PoolId poolId => mapping(int24 tickUpper => bytes32[] positionHashes)) private activePosHashesByTickUpper;
    mapping(PoolId poolId => MinHeapLib.Heap) private tickLowersDesc;
    mapping(PoolId poolId => MinHeapLib.Heap) private tickUppersAsc;

    // TODO: Optimize storing inactive positions and moving them to liquidity pool.
    mapping(PoolId poolId => bytes32[] positionHashes) private inactivePositionHashes;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
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

    // ------------------
    // External functions
    // ------------------

    function afterSwap(
        address /* sender */,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // TODO: Implement moving liquidity back and forth between pool and lending protocol on tick shift.
        // 1. Get the current tick of the pool.
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        // 2. Go through currently active positions and move the ones that have become inactive to lending.
        // (if `tickLower` > `currentTick` or `tickUpper` < `currentTick`)
        _findAndMoveInactiveLiquidityToLending(currentTick, key);
        // 3. Go through currently inactive positions and move the ones that have become active to pool.
        // (if `tickLower` < `currentTick` < `tickUpper`)
        _findAndMoveActiveLiquidityToPool(currentTick, key);

        return (this.afterSwap.selector, 0);
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        returns (uint128, uint256, uint256)
    {
        (uint128 liquidity, uint256 trueAmount0, uint256 trueAmount1) =
            _calculateAmountsAndLiquidity(key, tickLower, tickUpper, amount0, amount1);

        IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), trueAmount0);
        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), trueAmount1);

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        if (tickLower <= currentTick && tickUpper <= currentTick) {
            (trueAmount0, trueAmount1) = _addLiquidityFromHookToPool(tickLower, tickUpper, liquidity, key);
        } else {
            _addLiquidityFromHookToLending();
        }

        Position memory position =
            Position({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, owner: msg.sender, key: key});
        bytes32 posHash = keccak256(abi.encode(position));
        posByHash[key.toId()][posHash] = position;
        // Other mappings would probably be updated in the nested functions.

        return (liquidity, trueAmount0, trueAmount1);
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint128, uint256, uint256)
    {
        // TODO: Add validation for whether position exists.
        // Does this need to be `storage`?
        Position memory position =
            Position({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, owner: msg.sender, key: key});

        bytes32 posHash = keccak256(abi.encode(position));
        bool isActive = posStateByHash[key.toId()][posHash];

        uint256 absAmount0;
        uint256 absAmount1;

        if (isActive) {
            (absAmount0, absAmount1) = _removeLiquidityFromPoolToHook(tickLower, tickUpper, liquidity, key);
        } else {
            (absAmount0, absAmount1) = _removeLiquidityFromLendingToHook();
        }

        if (absAmount0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, absAmount0);
        }
        if (absAmount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, absAmount1);
        }

        // Other mappings would probably be updated in the nested functions.
        delete posByHash[key.toId()][posHash];

        return (liquidity, absAmount0, absAmount1);
    }

    // ------------------
    // Internal core functions
    // ------------------

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        UnlockCallData memory unlockData = abi.decode(data, (UnlockCallData));

        (BalanceDelta balanceDelta,) =
            poolManager.modifyLiquidity(unlockData.key, unlockData.modifyLiquidityParams, new bytes(0));

        (uint256 absAmount0, uint256 absAmount1) =
            _settleAndTakeBalances(unlockData.key.currency0, unlockData.key.currency1, balanceDelta);

        UnlockCallbackData memory callbackData = UnlockCallbackData(absAmount0, absAmount1);

        return (abi.encode(callbackData));
    }

    function _findAndMoveActiveLiquidityToPool(int24 poolTick, PoolKey memory key) internal {
        // TODO: Implement function.
    }

    function _findAndMoveInactiveLiquidityToLending(int24 poolTick, PoolKey memory key) internal {
        int24 positionTick = type(int24).min;
        if (tickLowersDesc[key.toId()].length() == 0) {
            return;
        }
        for (uint256 i = 0; positionTick < poolTick && i < ITERATION_LIMIT; i++) {
            positionTick = _heapPeekTick(tickLowersDesc[key.toId()], true);

            bytes32[] storage activePosHashesForTick = activePosHashesByTickLower[key.toId()][positionTick];
            if (activePosHashesForTick.length == 0) {
                _heapPopTick(tickLowersDesc[key.toId()], true);
                continue;
            }

            for (uint256 i2 = activePosHashesForTick.length - 1; i2 >= 0 && i2 < ITERATION_LIMIT; i2--) {
                _moveLiquidityFromPoolToLending(i2, activePosHashesForTick, key);
            }

            _heapPopTick(tickLowersDesc[key.toId()], true);
            // TODO: Check also the position's `tickUpper` in `tickUppersAsc` and remove the value if there are no other positions associated?
        }

        positionTick = type(int24).max;
        if (tickUppersAsc[key.toId()].length() == 0) {
            return;
        }
        for (uint256 i = 0; positionTick > poolTick && i < ITERATION_LIMIT; i++) {
            positionTick = _heapPeekTick(tickUppersAsc[key.toId()], false);

            bytes32[] storage activePosHashesForTick = activePosHashesByTickUpper[key.toId()][positionTick];
            if (activePosHashesForTick.length == 0) {
                _heapPopTick(tickLowersDesc[key.toId()], true);
                continue;
            }

            for (uint256 i2 = 0; i2 < activePosHashesForTick.length && i2 < ITERATION_LIMIT; i2++) {
                _moveLiquidityFromPoolToLending(i2, activePosHashesForTick, key);
            }

            _heapPopTick(tickUppersAsc[key.toId()], true);
            // TODO: Check also the position's `tickUpper` in `tickUppersAsc` and remove the value if there are no other positions associated?
        }
    }

    function _moveLiquidityFromPoolToLending(uint256 index, bytes32[] storage activePosHashesForTick, PoolKey memory key) internal {
        bytes32 positionHash = activePosHashesForTick[index];
        Position memory position = posByHash[key.toId()][positionHash];
        // If position doesn't exist or is inactive pop it off the array.
        if (position.owner == address(0) || !posStateByHash[key.toId()][positionHash]) {
            activePosHashesForTick.pop();
            // Also search and remove from `inactivePositionHashes`?
            return;
        }

        _removeLiquidityFromPoolToHook(position.tickLower, position.tickUpper, position.liquidity, position.key);
        _addLiquidityFromHookToLending();

        // Should mappings be updated here or within the functions?
        activePosHashesForTick.pop();
        inactivePositionHashes[key.toId()].push(positionHash);
        posStateByHash[key.toId()][positionHash] = false;
        // TODO: Update `activePosHashesByTickUpper`. But should it be updated here or not? How to make it more gas efficient?
    }

    function _addLiquidityFromHookToPool(int24 tickLower, int24 tickUpper, uint128 liquidity, PoolKey memory key)
        internal
        returns (uint256 absAmount0, uint256 absAmount1)
    {
        return _modifyLiquidityFromHookToPool(tickLower, tickUpper, int256(uint256(liquidity)), key);
        // TODO: Add validations and think about return data.
    }

    function _removeLiquidityFromPoolToHook(int24 tickLower, int24 tickUpper, uint128 liquidity, PoolKey memory key)
        internal
        returns (uint256 absAmount0, uint256 absAmount1)
    {
        return _modifyLiquidityFromHookToPool(tickLower, tickUpper, -int256(uint256(liquidity)), key);
        // TODO: Add validations and think about return data.
    }

    function _modifyLiquidityFromHookToPool(int24 tickLower, int24 tickUpper, int256 liquidity, PoolKey memory key)
        internal
        returns (uint256 absAmount0, uint256 absAmount1)
    {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, bytes32(0));

        UnlockCallData memory unlockData = UnlockCallData(key, params);
        UnlockCallbackData memory callbackData =
            abi.decode(poolManager.unlock(abi.encode(unlockData)), (UnlockCallbackData));

        absAmount0 = callbackData.absAmount0;
        absAmount1 = callbackData.absAmount1;

        // TODO: Add validations and think about return data.
    }

    function _addLiquidityFromHookToLending() internal {
        // TODO: Implement function.
    }

    function _removeLiquidityFromLendingToHook() internal returns (uint256 absAmount0, uint256 absAmount1) {
        // TODO: Implement function.
    }

    // --------------------------------
    // Internal balance delta functions
    // --------------------------------

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

    // ----------------
    // Internal helpers
    // ----------------

    function _calculateAmountsAndLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 liquidityDelta, uint256 trueAmount0, uint256 trueAmount1) {
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

    // ---------------------
    // Internal heap helpers
    // ---------------------

    function _heapInsertTick(MinHeapLib.Heap storage heap, int24 tick, bool isMaxHeap) internal {
        uint256 unsignedTick = uint256(int256(tick) + int256(OFFSET));
        if (isMaxHeap) {
            uint256 invertedTick = ~unsignedTick;
            heap.push(invertedTick);
        } else {
            heap.push(unsignedTick);
        }
    }

    function _heapPopTick(MinHeapLib.Heap storage heap, bool isMaxHeap) internal returns (int24 tick) {
        uint256 unsignedTick;
        uint256 result = heap.pop();
        // Invert back.
        if (isMaxHeap) {
            unsignedTick = ~result;
        } else {
            unsignedTick = result;
        }
        tick = int24(int256(unsignedTick) - int256(OFFSET));
    }

    function _heapPeekTick(MinHeapLib.Heap storage heap, bool isMaxHeap) internal view returns (int24 tick) {
        uint256 unsignedTick;
        uint256 result = heap.root();
        // Invert back.
        if (isMaxHeap) {
            unsignedTick = ~result;
        } else {
            unsignedTick = result;
        }
        tick = int24(int256(unsignedTick) - int256(OFFSET));
    }
}
