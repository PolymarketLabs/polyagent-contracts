// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDC is ERC20 {
    uint8 public constant DECIMALS = 6;
    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 10 ** DECIMALS;

    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function decimals() public view virtual override returns (uint8) {
        return DECIMALS;
    }
}
