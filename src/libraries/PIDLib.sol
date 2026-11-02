// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title PIDLib
 * @author ZengLLQ
 * @notice Fixed-point discrete Proportional-Integral-Derivative (PID) feedback loop controller.
 *         Governs dynamic stability fee adjustments in response to market peg deviations.
 */
library PIDLib {
    struct State {
        int256 lastError; // e_{k-1} in WAD
        int256 integral; // Accumulated integral sum
        uint256 lastTimestamp; // Previous update timestamp
        int256 kp; // Proportional gain (WAD)
        int256 ki; // Integral gain (WAD)
        int256 kd; // Derivative gain (WAD)
        int256 integralMin; // Anti-windup lower bound
        int256 integralMax; // Anti-windup upper bound
        uint256 outputMin; // Minimum output rate (e.g. 0.5% APY in RAY)
        uint256 outputMax; // Maximum output rate (e.g. 30.0% APY in RAY)
        uint256 baseRate; // Base benchmark borrow rate in RAY
    }

    /// @notice Computes next PID output given current market price and target price
    /// @param state Current PID controller state
    /// @param targetPrice Target price in WAD (e.g. 1.0e18 for $1.00 USD)
    /// @param marketPrice Current market price in WAD
    /// @return newOutput Adjusted rate output in RAY
    function compute(State storage state, uint256 targetPrice, uint256 marketPrice)
        internal
        returns (uint256 newOutput)
    {
        uint256 currentTimestamp = block.timestamp;
        uint256 dt = currentTimestamp - state.lastTimestamp;
        if (dt == 0) {
            return state.baseRate;
        }

        // Error: e(t) = targetPrice - marketPrice
        // When marketPrice < targetPrice ($0.98 < $1.00), error > 0 -> Increase borrow rate to contract supply
        int256 error = int256(targetPrice) - int256(marketPrice);

        // Proportional term: P = Kp * e(t)
        int256 pTerm = (state.kp * error) / 1e18;

        // Integral term with anti-windup clamping: I = Ki * ∫ e(t) dt
        int256 newIntegral = state.integral + (error * int256(dt)) / 1e18;
        if (newIntegral > state.integralMax) {
            newIntegral = state.integralMax;
        } else if (newIntegral < state.integralMin) {
            newIntegral = state.integralMin;
        }
        state.integral = newIntegral;
        int256 iTerm = (state.ki * newIntegral) / 1e18;

        // Derivative term: D = Kd * (e(t) - e(t-1)) / dt
        int256 dError = error - state.lastError;
        int256 dTerm = dt > 0 ? (state.kd * dError) / (int256(dt) * 1e18) : int256(0);

        // Total control signal delta in RAY
        // u = baseRate + (P + I + D) * 1e9
        int256 controlDelta = (pTerm + iTerm + dTerm) * 1e9;
        int256 calculatedRate = int256(state.baseRate) + controlDelta;

        if (calculatedRate < int256(state.outputMin)) {
            newOutput = state.outputMin;
        } else if (calculatedRate > int256(state.outputMax)) {
            newOutput = state.outputMax;
        } else {
            newOutput = uint256(calculatedRate);
        }

        state.lastError = error;
        state.lastTimestamp = currentTimestamp;
    }
}
