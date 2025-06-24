// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IOracle} from "../../src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) private prices;
    
    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }
    
    function getCurrentPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }
}