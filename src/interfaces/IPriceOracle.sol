// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPriceOracle {
    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event FeedConfigured(address indexed token, address indexed feed, uint32 heartbeat);

    function getPrice(address token) external view returns (uint256 priceWad);
    function isPriceFresh(address token) external view returns (bool);
}
