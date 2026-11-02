// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPIDRateController} from "../interfaces/IPIDRateController.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {PIDLib} from "../libraries/PIDLib.sol";

/**
 * @title PIDRateController
 * @author ZengLLQ
 * @notice Discrete Proportional-Integral-Derivative (PID) controller dynamically adjusting
 *         borrow stability rates to keep AUSD tethered to $1.00 USD.
 */
contract PIDRateController is IPIDRateController {
    using PIDLib for PIDLib.State;

    IPriceOracle public immutable oracle;
    address public immutable ausd;
    address public owner;

    uint256 public targetPriceWad = 1e18; // $1.00 target
    PIDLib.State public pidState;

    error Unauthorized();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _oracle, address _ausd) {
        if (_oracle == address(0) || _ausd == address(0)) revert ZeroAddress();
        owner = msg.sender;
        oracle = IPriceOracle(_oracle);
        ausd = _ausd;

        // Default PID settings:
        // baseRate: ~4.0% APY in per-second RAY: 1e27 + 1.24e18 per second
        // Kp = 0.5e18, Ki = 0.05e18, Kd = 0.1e18
        pidState = PIDLib.State({
            lastError: 0,
            integral: 0,
            lastTimestamp: block.timestamp,
            kp: 0.5e18,
            ki: 0.05e18,
            kd: 0.1e18,
            integralMin: -10e18,
            integralMax: 10e18,
            outputMin: 1e27 + 1.58e17, // ~0.5% APY
            outputMax: 1e27 + 7.92e18, // ~25.0% APY
            baseRate: 1e27 + 1.24e18 // ~4.0% APY
        });
    }

    function setPIDParameters(int256 kp, int256 ki, int256 kd, int256 intMin, int256 intMax) external onlyOwner {
        pidState.kp = kp;
        pidState.ki = ki;
        pidState.kd = kd;
        pidState.integralMin = intMin;
        pidState.integralMax = intMax;
        emit PIDParametersUpdated(kp, ki, kd);
    }

    function setRateBounds(uint256 baseRate, uint256 minRate, uint256 maxRate) external onlyOwner {
        pidState.baseRate = baseRate;
        pidState.outputMin = minRate;
        pidState.outputMax = maxRate;
    }

    function updateStabilityFee() external override returns (uint256 newBorrowRateRay) {
        uint256 marketPrice = oracle.getPrice(ausd);
        newBorrowRateRay = pidState.compute(targetPriceWad, marketPrice);
        emit RateUpdated(newBorrowRateRay, marketPrice, pidState.lastError);
    }

    function getCurrentBorrowRate() external view override returns (uint256) {
        return pidState.baseRate;
    }

    function getLatestError() external view override returns (int256) {
        return pidState.lastError;
    }
}
