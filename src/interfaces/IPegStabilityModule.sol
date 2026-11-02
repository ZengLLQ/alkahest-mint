// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPegStabilityModule {
    event PSMSwappedToAUSD(address indexed user, uint256 underlyingIn, uint256 ausdOut, uint256 fee);
    event PSMSwappedFromAUSD(address indexed user, uint256 ausdIn, uint256 underlyingOut, uint256 fee);
    event FeesUpdated(uint16 mintFeeBps, uint16 redeemFeeBps);
    event CeilingUpdated(uint256 newCeiling);

    function swapExactUnderlyingForAUSD(uint256 amountUnderlying) external returns (uint256 amountAUSDOut);

    function swapExactAUSDForUnderlying(uint256 amountAUSD) external returns (uint256 amountUnderlyingOut);

    function getMintAmountOut(uint256 amountUnderlying) external view returns (uint256 amountAUSDOut, uint256 fee);

    function getRedeemAmountOut(uint256 amountAUSD) external view returns (uint256 amountUnderlyingOut, uint256 fee);
}
