// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MathLib
 * @author ZengLLQ
 * @notice Fixed-point mathematics library supporting WAD (18 decimals) and RAY (27 decimals)
 *         with high-precision binomial series interest compounding.
 */
library MathLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days; // 31,536,000 seconds

    error DivisionByZero();
    error MultiplicationOverflow();

    /// @notice Multiplies two WAD numbers with rounding
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_WAD) / WAD;
    }

    /// @notice Divides two WAD numbers with rounding
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        if (a == 0) return 0;
        return (a * WAD + b / 2) / b;
    }

    /// @notice Multiplies two RAY numbers with rounding
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    /// @notice Divides two RAY numbers with rounding
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        if (a == 0) return 0;
        return (a * RAY + b / 2) / b;
    }

    /// @notice Converts WAD to RAY
    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * 1e9;
    }

    /// @notice Converts RAY to WAD with rounding
    function rayToWad(uint256 a) internal pure returns (uint256) {
        return (a + 0.5e9) / 1e9;
    }

    /// @notice Computes (1 + ratePerSecond)^elapsed via binomial expansion in RAY precision
    /// @param ratePerSecond Borrow rate per second in RAY (e.g. 1e27 + per_second_increment)
    /// @param elapsed Seconds elapsed since last update
    /// @return Accrued compounding factor in RAY
    function calculateCompoundedInterest(uint256 ratePerSecond, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed == 0) return RAY;

        uint256 exp = elapsed;
        uint256 base = ratePerSecond;
        uint256 result = RAY;

        while (exp > 0) {
            if (exp % 2 != 0) {
                result = rayMul(result, base);
            }
            exp /= 2;
            if (exp > 0) {
                base = rayMul(base, base);
            }
        }
        return result;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
