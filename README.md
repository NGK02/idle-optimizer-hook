# Idle Optimizer
![smallLogo](https://github.com/user-attachments/assets/7ca33a05-dfb5-4d9f-9718-38baab48f384)

## Introduction
DISCLAIMER: This project is still a rough PoC and should not be used as production code!
A capital optimization Uniswap v4 hook that automatically deploys out-of-range Uniswap v4 liquidity to lending protocols and returns it to the pool when prices move back into range, eliminating idle capital while preserving liquidity functionality. This hook was created as part of the Uniswap Hook Incubator 3 hookathon.

## What can you do with this hook?
This hook must be attatched to a Uniswap v4 pool, then it functions as a router to add liquidity to the pool. Once liquidity is added via the hook, depending on whether it's currently active or not it will be moved back and forth between the liquidity pool and a lending protocol. This happens based on the current tick of the pool after every swap. The liquidity can be removed at any time by it's owner regardless of whether it's currently in lending or the Uniswap protocol.

## Getting Started
### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
