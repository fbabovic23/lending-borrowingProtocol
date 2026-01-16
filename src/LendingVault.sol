//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LendingVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    address private borrowingPool;

    error LendingVault__ValueIsZero();

    constructor()
        ERC4626(IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F))
        ERC20("Lending Vault DAI", "lvDAI")
        Ownable(msg.sender)
    {
        borrowingPool = msg.sender;
    }

    function lend(address borrower, uint256 amount) external onlyOwner {
        if (amount == 0) {
            revert LendingVault__ValueIsZero();
        }

        IERC20(asset()).safeTransfer(borrower, amount);
    }

    function totalAssetsInVault() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (assets == 0) {
            revert LendingVault__ValueIsZero();
        }

        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (shares == 0) {
            revert LendingVault__ValueIsZero();
        }
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (assets == 0) {
            revert LendingVault__ValueIsZero();
        }

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (shares == 0) {
            revert LendingVault__ValueIsZero();
        }
        return super.redeem(shares, receiver, owner);
    }

    ////////////////////////////////////////////////////
    /////////////  INTERNAL FUNCTIONS //////////////////
    ////////////////////////////////////////////////////
}
