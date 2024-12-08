// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {MinHeapLib} from "solady/utils/MinHeapLib.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

import {console} from "forge-std/Test.sol";

contract IdleOptimizerHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using MinHeapLib for MinHeapLib.Heap;

    error IdleOptimizerHook_IndexOutOfBound();

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

    struct LendingPosition {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
    }

    // Offset to shift `int24` into `uint256` range.
    uint256 constant OFFSET = 1 << 23;
    uint256 constant ITERATION_LIMIT = 200;

    // Maybe this should be private?
    IPool public immutable lendingPool;

    // These 2 probably don't need to have an outer mapping by poolId since the hash already contains the `PoolKey`.
    mapping(PoolId poolId => mapping(bytes32 positionHash => Position position)) private posByHash;
    mapping(PoolId poolId => mapping(bytes32 positionHash => bool isActive)) private posStateByHash;

    mapping(PoolId poolId => mapping(int24 tickLower => bytes32[] positionHashes)) private activePosHashesByTickLower;
    mapping(PoolId poolId => mapping(int24 tickUpper => bytes32[] positionHashes)) private activePosHashesByTickUpper;
    mapping(PoolId poolId => MinHeapLib.Heap) private activeTickLowersDesc;
    mapping(PoolId poolId => MinHeapLib.Heap) private activeTickUppersAsc;

    mapping(bytes32 positionHash => LendingPosition lendingPosition) private lendingPosByPosHash;

    // TODO: Optimize storing inactive positions and moving them to liquidity pool.
    mapping(PoolId poolId => bytes32[] positionHashes) private inactivePositionHashes;

    constructor(IPoolManager _manager, address _lendingPool) BaseHook(_manager) {
        lendingPool = IPool(_lendingPool);
    }

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

    // TODO: Implement working with native ETH and not just ERC20s.
    function afterSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, /* params */
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
        console.log("`addLiquidity` reached!");

        (uint128 liquidity, uint256 trueAmount0, uint256 trueAmount1) =
            _calculateAmountsAndLiquidity(key, tickLower, tickUpper, amount0, amount1);

        IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), trueAmount0);
        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), trueAmount1);

        Position memory position =
            Position({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, owner: msg.sender, key: key});
        bytes32 posHash = keccak256(abi.encode(position));

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        if (tickLower <= currentTick && tickUpper >= currentTick) {

            console.log("`addLiquidity` 2 reached! adding liquidity to pool!");
            console.log("`currentTick`: ", currentTick);
            console.log("`tickLower`: ", tickLower);
            console.log("`tickUpper`: ", tickUpper);

            (trueAmount0, trueAmount1) = _addLiquidityFromHookToPool(tickLower, tickUpper, liquidity, key);

            posByHash[key.toId()][posHash] = position;
            posStateByHash[key.toId()][posHash] = true;
            if (activePosHashesByTickLower[key.toId()][position.tickLower].length == 0) {
                _heapInsertTick(activeTickLowersDesc[key.toId()], tickLower, true);
            }
            if (activePosHashesByTickUpper[key.toId()][position.tickUpper].length == 0) {
                _heapInsertTick(activeTickUppersAsc[key.toId()], tickUpper, false);
            }
            activePosHashesByTickLower[key.toId()][position.tickLower].push(posHash);
            activePosHashesByTickUpper[key.toId()][position.tickUpper].push(posHash);
        } else {

            console.log("`addLiquidity` 2 reached! adding liquidity to lending!");
            console.log("`currentTick`: ", currentTick);
            console.log("`tickLower`: ", tickLower);
            console.log("`tickUpper`: ", tickUpper);
            
            // Not sure if i should use `trueAmount0` and `trueAmount1` here or `amount0` and `amount1`.
            _addLiquidityFromHookToLending(posHash, key, trueAmount0, trueAmount1);

            posByHash[key.toId()][posHash] = position;
            posStateByHash[key.toId()][posHash] = false;
            LendingPosition memory lendingPosition = LendingPosition({
                token0: Currency.unwrap(key.currency0),
                token1: Currency.unwrap(key.currency1),
                amount0: trueAmount0,
                amount1: trueAmount1
            });
            lendingPosByPosHash[posHash] = lendingPosition;
            inactivePositionHashes[key.toId()].push(posHash);
        }

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

        uint256 amount0;
        uint256 amount1;

        if (isActive) {
            (amount0, amount1) = _removeLiquidityFromPoolToHook(tickLower, tickUpper, liquidity, key);

            // Here i should also probably check if there are still any hashes
            // associated with this `tickUpper` and `tickLower` and if not
            // remove it from the heap i think.
            delete posByHash[key.toId()][posHash];
            delete posStateByHash[key.toId()][posHash];
            delete activePosHashesByTickLower[key.toId()][tickLower];
            delete activePosHashesByTickUpper[key.toId()][tickUpper];
            // `if (activePosHashesByTickLower[key.toId()][tickLower].length == 0)` then delete the tick from the heap as well.
        } else {
            (amount0, amount1) = _removeLiquidityFromLendingToHook(posHash);

            delete posByHash[key.toId()][posHash];
            delete posStateByHash[key.toId()][posHash];
            delete lendingPosByPosHash[posHash];
            bytes32[] storage inactivePositions = inactivePositionHashes[key.toId()];
            for (uint256 i = 0; i < inactivePositions.length; i++) {
                if (posHash == inactivePositions[i]) {
                    _removeWithoutOrder(inactivePositions, i);
                    break;
                }
            }
        }

        if (amount0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
        }

        return (liquidity, amount0, amount1);
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
        bytes32[] storage currInactivePosHashes = inactivePositionHashes[key.toId()];

        if (currInactivePosHashes.length == 0) {
            return;
        }
        // TODO: Implement a more efficient way to find inactive positions that became activated.
        for (uint256 i = 0; i < currInactivePosHashes.length && i < ITERATION_LIMIT; i++) {
            bytes32 posHash = currInactivePosHashes[i];
            Position memory position = posByHash[key.toId()][posHash];

            if (position.tickLower < poolTick && position.tickUpper > poolTick) {
                (uint256 amount0, uint256 amount1) = _removeLiquidityFromLendingToHook(posHash);
                _addLiquidityFromHookToLending(posHash, key, amount0, amount1);

                // Should part of the state be updated after removal and part of it after adding (probably for reentrancy).
                // For ex. deleting active positions only after removal and adding inactive positions after only after adding
                // instead of all at once in the end.
                _removeWithoutOrder(currInactivePosHashes, i);
                delete lendingPosByPosHash[posHash];

                posStateByHash[key.toId()][posHash] = true;
                activePosHashesByTickLower[key.toId()][position.tickLower].push(posHash);
                activePosHashesByTickUpper[key.toId()][position.tickUpper].push(posHash);
                // TODO: Again the issue is how to update the 2 heaps (`activeTickLowersDesc` and `activeTickUppersAsc`)
                // if a tick has become "activated" by adding an active position to it's mapping.
            }
        }
    }

    function _findAndMoveInactiveLiquidityToLending(int24 poolTick, PoolKey memory key) internal {
        int24 positionTick = type(int24).min;
        if (activeTickLowersDesc[key.toId()].length() == 0) {
            return;
        }
        for (uint256 i = 0; positionTick < poolTick && i < ITERATION_LIMIT; i++) {
            positionTick = _heapPeekTick(activeTickLowersDesc[key.toId()], true);

            bytes32[] storage activePosHashesForCurrTickLower = activePosHashesByTickLower[key.toId()][positionTick];
            if (activePosHashesForCurrTickLower.length == 0) {
                _heapPopTick(activeTickLowersDesc[key.toId()], true);
                continue;
            }

            for (uint256 i2 = 0; i2 < activePosHashesForCurrTickLower.length && i2 < ITERATION_LIMIT; i2++) {
                bytes32 positionHash = activePosHashesForCurrTickLower[i2];

                _moveLiquidityFromPoolToLending(i2, positionHash, activePosHashesForCurrTickLower, key);

                // Remove from the corresponding `tickUpper` mapping as well.
                Position memory position = posByHash[key.toId()][positionHash];
                bytes32[] storage activePosHashesForCurrTickUpper =
                    activePosHashesByTickUpper[key.toId()][position.tickUpper];
                for (uint256 i3 = 0; i3 < activePosHashesForCurrTickUpper.length; i3++) {
                    if (activePosHashesForCurrTickUpper[i3] == positionHash) {
                        _removeWithoutOrder(activePosHashesForCurrTickUpper, i3);
                        break;
                    }
                    // Somewhere i should also check if there are still any hashes associated with this `tickUpper`
                    // and if not remove it from the heap, but not sure if it should be here.
                }
            }

            _heapPopTick(activeTickLowersDesc[key.toId()], true);
            // TODO: Check also the position's `tickUpper` in `activeTickUppersAsc` and remove the value if there are no other positions associated?
        }

        positionTick = type(int24).max;
        if (activeTickUppersAsc[key.toId()].length() == 0) {
            return;
        }
        for (uint256 i = 0; positionTick > poolTick && i < ITERATION_LIMIT; i++) {
            positionTick = _heapPeekTick(activeTickUppersAsc[key.toId()], false);

            bytes32[] storage activePosHashesForCurrTickUpper = activePosHashesByTickUpper[key.toId()][positionTick];
            if (activePosHashesForCurrTickUpper.length == 0) {
                _heapPopTick(activeTickLowersDesc[key.toId()], true);
                continue;
            }

            for (uint256 i2 = 0; i2 < activePosHashesForCurrTickUpper.length && i2 < ITERATION_LIMIT; i2++) {
                bytes32 positionHash = activePosHashesForCurrTickUpper[i2];

                _moveLiquidityFromPoolToLending(i2, positionHash, activePosHashesForCurrTickUpper, key);

                // Remove from the corresponding `tickUpper` mapping as well.
                Position memory position = posByHash[key.toId()][positionHash];
                bytes32[] storage activePosHashesForCurrTickLower =
                    activePosHashesByTickLower[key.toId()][position.tickLower];
                for (uint256 i3 = 0; i3 < activePosHashesForCurrTickLower.length; i3++) {
                    if (activePosHashesForCurrTickLower[i3] == positionHash) {
                        _removeWithoutOrder(activePosHashesForCurrTickLower, i3);
                        break;
                    }
                    // Somewhere i should also check if there are still any hashes associated with this `tickLower`
                    // and if not remove it from the heap, but not sure if it should be here.
                }
            }

            _heapPopTick(activeTickUppersAsc[key.toId()], true);
            // TODO: Check also the position's `tickUpper` in `activeTickUppersAsc` and remove the value if there are no other positions associated?
        }
    }

    function _moveLiquidityFromPoolToLending(
        uint256 index,
        bytes32 positionHash,
        bytes32[] storage activePosHashesForTick,
        PoolKey memory key
    ) internal {
        Position memory position = posByHash[key.toId()][positionHash];
        // If position doesn't exist or is inactive pop it off the array.
        if (position.owner == address(0) || !posStateByHash[key.toId()][positionHash]) {
            _removeWithoutOrder(activePosHashesForTick, index);
            // Also search and remove from `inactivePositionHashes`?
            return;
        }

        (uint256 amount0, uint256 amount1) =
            _removeLiquidityFromPoolToHook(position.tickLower, position.tickUpper, position.liquidity, position.key);
        _addLiquidityFromHookToLending(positionHash, key, amount0, amount1);

        // Should mappings be updated here or within the functions?
        activePosHashesForTick.pop();
        posStateByHash[key.toId()][positionHash] = false;

        inactivePositionHashes[key.toId()].push(positionHash);
        LendingPosition memory lendingPosition = LendingPosition({
            token0: Currency.unwrap(position.key.currency0),
            token1: Currency.unwrap(position.key.currency1),
            amount0: amount0,
            amount1: amount1
        });
        lendingPosByPosHash[positionHash] = lendingPosition;
    }

    function _addLiquidityFromHookToPool(int24 tickLower, int24 tickUpper, uint128 liquidity, PoolKey memory key)
        internal
        returns (uint256 absAmount0, uint256 absAmount1)
    {
        console.log("`_addLiquidityFromHookToPool` reached!");

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
        console.log("`_modifyLiquidityFromHookToPool` reached!");

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, bytes32(0));

        UnlockCallData memory unlockData = UnlockCallData(key, params);
        UnlockCallbackData memory callbackData =
            abi.decode(poolManager.unlock(abi.encode(unlockData)), (UnlockCallbackData));

        absAmount0 = callbackData.absAmount0;
        absAmount1 = callbackData.absAmount1;
        // TODO: Add validations and think about return data.
    }

    function _addLiquidityFromHookToLending(bytes32 positionHash, PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
    {
        Position memory position = posByHash[key.toId()][positionHash];

        address token0 = Currency.unwrap(position.key.currency0);
        address token1 = Currency.unwrap(position.key.currency1);

        if (amount0 > 0) {
            IERC20(token0).approve(address(lendingPool), amount0);
            lendingPool.supply(token0, amount0, address(this), 0);
        }
        if (amount1 > 0) {
            IERC20(token1).approve(address(lendingPool), amount1);
            lendingPool.supply(token1, amount1, address(this), 0);
        }
    }

    function _removeLiquidityFromLendingToHook(bytes32 posHash) internal returns (uint256 amount0, uint256 amount1) {
        //Position memory position = posByHash[key.toId()][posHash];
        LendingPosition memory lendingPos = lendingPosByPosHash[posHash];

        if (lendingPos.amount0 > 0) {
            amount0 = lendingPool.withdraw(lendingPos.token0, lendingPos.amount0, address(this));
        }
        if (lendingPos.amount1 > 0) {
            amount1 = lendingPool.withdraw(lendingPos.token1, lendingPos.amount1, address(this));
        }
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

    function _removeWithoutOrder(bytes32[] storage array, uint256 index) internal {
        if (index < array.length) {
            revert IdleOptimizerHook_IndexOutOfBound();
        }
        array[index] = array[array.length - 1];
        array.pop();
    }

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

    // -------------------------
    // External getter functions
    // -------------------------

    function getPosition(PoolId poolId, bytes32 positionHash) external view returns (Position memory) {
        return posByHash[poolId][positionHash];
    }

    function getPositionState(PoolId poolId, bytes32 positionHash) external view returns (bool) {
        return posStateByHash[poolId][positionHash];
    }

    function getPositionHashesByTickLower(PoolId poolId, int24 tickLower) external view returns (bytes32[] memory) {
        return activePosHashesByTickLower[poolId][tickLower];
    }

    function getPositionHashesByTickUpper(PoolId poolId, int24 tickUpper) external view returns (bytes32[] memory) {
        return activePosHashesByTickUpper[poolId][tickUpper];
    }

    function getLendingPosition(bytes32 positionHash) external view returns (LendingPosition memory) {
        return lendingPosByPosHash[positionHash];
    }

    function getInactivePositionHashes(PoolId poolId) external view returns (bytes32[] memory) {
        return inactivePositionHashes[poolId];
    }

    function getactiveTickLowersDescLength(PoolId poolId) external view returns (uint256) {
        return activeTickLowersDesc[poolId].length();
    }

        function getactiveTickUppersAscLength(PoolId poolId) external view returns (uint256) {
        return activeTickUppersAsc[poolId].length();
    }
}
