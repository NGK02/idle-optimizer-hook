// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LendingPoolMock} from "./mocks/LendingPoolMock.sol";

import {IdleOptimizerHook} from "../src/IdleOptimizerHook.sol";

contract IdleOptimizerHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;
    LendingPoolMock lendingPool;

    IdleOptimizerHook hook;

    function setUp() public {
        console.log("`setUp` reached!");

        // Deploy v4 core contracts.
        deployFreshManagerAndRouters();

        // Deploy lending pool mock.
        lendingPool = new LendingPoolMock();

        // Deploy two test tokens.
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook.
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        // TODO: Add a dummy implementation of the lending pool contract for testing.
        deployCodeTo("IdleOptimizerHook.sol", abi.encode(manager, address(lendingPool)), hookAddress);
        hook = IdleOptimizerHook(hookAddress);

        // Approve our hook address to spend these tokens as well.
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens.
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_addLiquidityAddsLiquidityToPoolandUpdatesState() public {
        console.log("`test_addLiquidityInRange` reached!");

        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 initialAmount0 = 1 ether;
        uint256 initialAmount1 = 1 ether;
        int24 tickLower = tick - key.tickSpacing;
        int24 tickUpper = tick + key.tickSpacing;

        (uint128 expectedLiquidityInPool,,) =
            hook.addLiquidity(key, tickLower, tickUpper, initialAmount0, initialAmount1);

        IdleOptimizerHook.Position memory expectedPosition = IdleOptimizerHook.Position({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: expectedLiquidityInPool,
            owner: address(this),
            key: key
        });
        bytes32 expectedPosHash = keccak256(abi.encode(expectedPosition));

        (uint128 resultLiquidityInPool,,) =
            manager.getPositionInfo(key.toId(), address(hook), tickLower, tickUpper, bytes32(0));
        IdleOptimizerHook.Position memory resultPosition = hook.getPosition(key.toId(), expectedPosHash);
        bytes32 resultPosHash = keccak256(abi.encode(resultPosition));
        bool resultPosIsActive = hook.getPositionState(key.toId(), resultPosHash);
        bytes32[] memory resultActivePosHashesByTickLower = hook.getPositionHashesByTickLower(key.toId(), tickLower);
        bytes32[] memory resultActivePosHashesByTickUpper = hook.getPositionHashesByTickUpper(key.toId(), tickUpper);
        uint256 resultActiveTickUppersCount = hook.getactiveTickUppersAscLength(key.toId());
        uint256 resultActiveTickLowersCount = hook.getactiveTickLowersDescLength(key.toId());

        // Is there a point to comparing the positions themselves?
        assertEq(expectedPosHash, resultPosHash);
        assertEq(true, resultPosIsActive);
        assertEq(1, resultActivePosHashesByTickLower.length);
        assertEq(1, resultActivePosHashesByTickUpper.length);
        assertEq(1, resultActiveTickLowersCount);
        assertEq(1, resultActiveTickUppersCount);
        assertEq(expectedLiquidityInPool, resultLiquidityInPool);
    }

    function test_addLiquidityOutOfRangePutsLiquidityInLendingPool() public {
        console.log("`test_addLiquidityOutOfRangePutsLiquidityInLendingPool` reached!");

        // Arrange
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 initialAmount0 = 1 ether;
        uint256 initialAmount1 = 1 ether;
        int24 tickUpper = tick - 1000;
        int24 tickLower = tickUpper - 1000;
        // Choose `tickLower` and `tickUpper` such that `tick` is outside the range (for ex. `tick` > `tickHigher`).

        // Act
        console.log("`token0`: ", Currency.unwrap(key.currency0));
        console.log("`token1`: ", Currency.unwrap(key.currency1));
        (uint128 liquidity, uint256 expectedToken0InLendingPool, uint256 expectedToken1InLendingPool) =
            hook.addLiquidity(key, tickLower, tickUpper, initialAmount0, initialAmount1);

        // Now verify that the tokens have been supplied to the lending pool.
        IdleOptimizerHook.Position memory expectedPosition = IdleOptimizerHook.Position({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            owner: address(this),
            key: key
        });
        bytes32 expectedPosHash = keccak256(abi.encode(expectedPosition));

        uint256 resultToken0InLendingPool = MockERC20(Currency.unwrap(token0)).balanceOf(address(lendingPool));
        uint256 resultToken1InLendingPool = MockERC20(Currency.unwrap(token1)).balanceOf(address(lendingPool));
        (uint128 resultLiquidityInPool,,) =
            manager.getPositionInfo(key.toId(), address(hook), tickLower, tickUpper, bytes32(0));
        IdleOptimizerHook.Position memory resultPosition = hook.getPosition(key.toId(), expectedPosHash);
        bytes32 resultPosHash = keccak256(abi.encode(resultPosition));
        bool resultPosIsActive = hook.getPositionState(key.toId(), resultPosHash);
        bytes32[] memory inactivePositionHashes = hook.getInactivePositionHashes(key.toId());
        IdleOptimizerHook.LendingPosition memory lendingPosition = hook.getLendingPosition(expectedPosHash);

        assertEq(
            resultToken0InLendingPool, expectedToken0InLendingPool, "Token0 not correctly supplied to lending pool!"
        );
        assertEq(
            resultToken1InLendingPool, expectedToken1InLendingPool, "Token1 not correctly supplied to lending pool!"
        );
        assertEq(resultLiquidityInPool, 0, "Liquidity should not be added to the Uniswap pool!");

        assertEq(expectedPosHash, resultPosHash, "Position hash mismatch!");
        assertFalse(resultPosIsActive, "Position state mismatch!");
        assertEq(inactivePositionHashes.length, 1, "There should be one inactive position!");
        assertEq(inactivePositionHashes[0], expectedPosHash, "The inactive position hash should match!");
        assertEq(lendingPosition.token0, Currency.unwrap(token0), "`LendingPosition` mismatch!");
        assertEq(lendingPosition.token1, Currency.unwrap(token1), "`LendingPosition` mismatch!");
        assertEq(lendingPosition.amount0, expectedToken0InLendingPool, "`LendingPosition` mismatch!");
        assertEq(lendingPosition.amount1, expectedToken1InLendingPool, "`LendingPosition` mismatch!");
    }

    function test_removeLiquidityRemovesLiquidityFromPoolAndUpdatesState() public {
        // Arrange
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 initialAmount0 = 1 ether;
        uint256 initialAmount1 = 1 ether;
        int24 tickLower = tick - key.tickSpacing;
        int24 tickUpper = tick + key.tickSpacing;
        uint256 expectedToken0Balance = currency0.balanceOfSelf();
        uint256 expectedToken1Balance = currency1.balanceOfSelf();

        (uint128 liquidity,,) = hook.addLiquidity(key, tickLower, tickUpper, initialAmount0, initialAmount1);

        IdleOptimizerHook.Position memory toBeRemovedPosition = IdleOptimizerHook.Position({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            owner: address(this),
            key: key
        });
        bytes32 toBeRemovedPosHash = keccak256(abi.encode(toBeRemovedPosition));

        // Act
        hook.removeLiquidity(key, tickLower, tickUpper, liquidity);

        (uint128 resultLiquidityInPool,,) =
            manager.getPositionInfo(key.toId(), address(hook), tickLower, tickUpper, bytes32(0));
        bool resultPosIsActive = hook.getPositionState(key.toId(), toBeRemovedPosHash);
        IdleOptimizerHook.Position memory resultPosition = hook.getPosition(key.toId(), toBeRemovedPosHash);
        bytes32[] memory resultActivePosHashesByTickLower = hook.getPositionHashesByTickLower(key.toId(), tickLower);
        bytes32[] memory resultActivePosHashesByTickUpper = hook.getPositionHashesByTickUpper(key.toId(), tickUpper);
        uint256 resultToken0Balance = currency0.balanceOfSelf();
        uint256 resultToken1Balance = currency1.balanceOfSelf();

        // Assert
        assertEq(0, resultPosition.liquidity);
        assertEq(address(0), resultPosition.owner);
        assertEq(0, resultPosition.tickLower);
        assertEq(0, resultPosition.tickUpper);
        // How to compare the key for default value and is there a point?

        assertEq(false, resultPosIsActive);
        assertEq(0, resultActivePosHashesByTickLower.length);
        assertEq(0, resultActivePosHashesByTickUpper.length);
        assertEq(0, resultLiquidityInPool);
        assertApproxEqAbs(expectedToken0Balance, resultToken0Balance, 1);
        assertApproxEqAbs(expectedToken1Balance, resultToken1Balance, 1);
        // uint256 resultActiveTickUppersCount = hook.getactiveTickUppersAscLength(key.toId());
        // uint256 resultActiveTickLowersCount = hook.getactiveTickLowersDescLength(key.toId());
        // assertEq(0, resultActiveTickLowersCount);
        // assertEq(0, resultActiveTickUppersCount);
        // Not updating these on `removeLiquidity` at the moment, might do it at some point,
        // but not sure if it's worth it or it would take too much gas compared to removing them later.
    }
}
