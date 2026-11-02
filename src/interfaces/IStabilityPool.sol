// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IStabilityPool {
    event StabilityDeposit(address indexed user, uint256 amount);
    event StabilityWithdrawal(address indexed user, uint256 amount);
    event DebtOffset(address indexed collateral, uint256 debtAbsorbed, uint256 collateralGained);
    event RewardsClaimed(address indexed user, address indexed collateral, uint256 amount);

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function offsetDebt(address collateral, uint256 debtToOffset, uint256 collateralToAdd)
        external
        returns (uint256 debtAbsorbed, uint256 collateralRewarded);
    function claimRewards(address collateral) external returns (uint256 amountClaimed);
    function getDepositorCollateralGain(address user, address collateral) external view returns (uint256);
    function getDepositorBalance(address user) external view returns (uint256);
    function totalAUSDDeposited() external view returns (uint256);
}
