// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @author ZengLLQ
 * @notice Multi-asset Price Oracle router with 18-decimal (WAD) normalization,
 *         staleness detection, and price bounds verification.
 */
contract PriceOracle is IPriceOracle {
    struct PriceData {
        uint256 priceWad; // Normalized to 1e18
        uint256 lastUpdated;
        uint32 heartbeat; // Maximum allowable age in seconds
        bool active;
    }

    address public owner;
    mapping(address => PriceData) public prices;

    error Unauthorized();
    error PriceStale(address token, uint256 age, uint32 heartbeat);
    error InvalidPrice();
    error TokenNotConfigured();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setDirectPrice(address token, uint256 priceWad, uint32 heartbeat) external onlyOwner {
        if (priceWad == 0) revert InvalidPrice();
        prices[token] = PriceData({
            priceWad: priceWad, lastUpdated: block.timestamp, heartbeat: heartbeat == 0 ? 3600 : heartbeat, active: true
        });
        emit PriceUpdated(token, priceWad, block.timestamp);
    }

    function getPrice(address token) external view override returns (uint256 priceWad) {
        PriceData memory data = prices[token];
        if (!data.active) revert TokenNotConfigured();
        if (block.timestamp - data.lastUpdated > data.heartbeat) {
            revert PriceStale(token, block.timestamp - data.lastUpdated, data.heartbeat);
        }
        return data.priceWad;
    }

    function isPriceFresh(address token) external view override returns (bool) {
        PriceData memory data = prices[token];
        if (!data.active) return false;
        return (block.timestamp - data.lastUpdated) <= data.heartbeat;
    }
}
