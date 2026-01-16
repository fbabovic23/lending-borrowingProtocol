//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {BorrowingPool} from "../src/BorrowingPool.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Deployer {

    BorrowingPool borrowingPool;
    LendingVault lendingVault;

    function run() public returns() {}
}
