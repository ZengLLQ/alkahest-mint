// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPIDRateController {
    event RateUpdated(uint256 newBorrowRateRay, uint256 marketPriceWad, int256 errorWad);
    event PIDParametersUpdated(int256 kp, int256 ki, int256 kd);

    function updateStabilityFee() external returns (uint256 newBorrowRateRay);
    function getCurrentBorrowRate() external view returns (uint256);
    function getLatestError() external view returns (int256);
}
