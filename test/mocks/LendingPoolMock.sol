// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract LendingPoolMock {
    mapping(address user => mapping(address asset => uint256 amount)) public balances;
    mapping(address asset => uint256) public totalSupplied; // asset address => total amount supplied

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /*referralCode*/ ) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[onBehalfOf][asset] += amount;
        totalSupplied[asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 userBalance = balances[msg.sender][asset];
        require(userBalance >= amount, "Not enough balance");
        balances[msg.sender][asset] -= amount;
        totalSupplied[asset] -= amount;
        MockERC20(asset).transfer(to, amount);
        return amount;
    }
}
