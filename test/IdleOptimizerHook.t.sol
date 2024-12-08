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

import {IdleOptimizerHook} from "../src/IdleOptimizerHook.sol";

contract IdleOptimizerHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;

    IdleOptimizerHook hook;

    function setUp() public {
        console.log("`setUp` reached!");
        
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        // TODO: Add a dummy implementation of the lending pool contract for testing.
        deployCodeTo("IdleOptimizerHook.sol", abi.encode(manager, address(0)), hookAddress);
        hook = IdleOptimizerHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool
        // // Some liquidity from -60 to +60 tick range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -60,
        //         tickUpper: 60,
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
        // // Some liquidity from -120 to +120 tick range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -120,
        //         tickUpper: 120,
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
        // // some liquidity for full range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: TickMath.minUsableTick(60),
        //         tickUpper: TickMath.maxUsableTick(60),
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
    }

    function test_addLiquidityInRange() public {
        console.log("`test_addLiquidityInRange` reached!");

        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 initialAmount0 = 1 ether;
        uint256 initialAmount1 = 1 ether;
        int24 tickLower = tick - key.tickSpacing;
        int24 tickUpper = tick + key.tickSpacing;

        (uint128 expectedLiquidityInPool,,) = hook.addLiquidity(key, tickLower, tickUpper, initialAmount0, initialAmount1);

        IdleOptimizerHook.Position memory expectedPosition = IdleOptimizerHook.Position({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: expectedLiquidityInPool,
            owner: address(this),
            key: key
        });
        bytes32 expectedPosHash = keccak256(abi.encode(expectedPosition));
        bool expectedPosIsActive = true;

        IdleOptimizerHook.Position memory resultPosition = hook.getPosition(key.toId(), expectedPosHash);
        bytes32 resultPosHash = keccak256(abi.encode(resultPosition));
        bool resultPosIsActive = hook.getPositionState(key.toId(), resultPosHash);
        bytes32[] memory resultActivePosHashesByTickLower = hook.getPositionHashesByTickLower(key.toId(), tickLower);
        bytes32[] memory resultActivePosHashesByTickUpper = hook.getPositionHashesByTickUpper(key.toId(), tickUpper);
        uint256 resultActiveTickUppersCount = hook.getactiveTickUppersAscLength(key.toId());
        uint256 resultActiveTickLowersCount = hook.getactiveTickLowersDescLength(key.toId());
        (uint128 resultLiquidityInPool,,) = manager.getPositionInfo(key.toId(), address(hook), tickLower, tickUpper, bytes32(0));

        // Is there a point to comparing the positions themselves?
        assertEq(expectedPosHash, resultPosHash);
        assertEq(expectedPosIsActive, resultPosIsActive);
        assertEq(1, resultActivePosHashesByTickLower.length);
        assertEq(1, resultActivePosHashesByTickUpper.length);
        assertEq(1, resultActiveTickLowersCount);
        assertEq(1, resultActiveTickUppersCount);
        assertEq(expectedLiquidityInPool, resultLiquidityInPool);
    }
}
