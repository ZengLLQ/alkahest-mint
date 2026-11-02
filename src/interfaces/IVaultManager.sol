// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVaultManager {
    struct CollateralConfig {
        bool isAllowed;
        uint8 decimals;
        uint16 maxLTV; // Basis points (e.g. 8000 = 80%)
        uint16 liquidationThreshold; // Basis points (e.g. 8500 = 85%)
        uint16 liquidationPenalty; // Basis points (e.g. 500 = 5% penalty bonus for liquidator)
        uint256 debtCeiling; // Max AUSD debt mintable against this collateral
        uint256 totalDeposited; // Total units of token deposited
        uint256 totalBorrowed; // Total AUSD debt principal
        uint256 cumulativeBorrowIndex; // Compounded interest index in RAY
        uint256 lastAccrualTimestamp;
        uint256 borrowRatePerSecond; // Current borrow rate per second in RAY
    }

    struct VaultPosition {
        uint256 collateralAmount; // Native tokens deposited
        uint256 debtShares; // Normalized debt shares
    }

    event CollateralConfigured(address indexed collateral, uint16 maxLTV, uint16 liquidationThreshold);
    event CollateralDeposited(address indexed user, address indexed collateral, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed collateral, uint256 amount);
    event USDBorrowed(address indexed user, address indexed collateral, uint256 amount, uint256 fee);
    event USDRepaid(address indexed user, address indexed collateral, uint256 amount);
    event VaultLiquidated(
        address indexed borrower,
        address indexed collateral,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 penaltyBonus
    );

    function depositCollateral(address collateral, uint256 amount) external;
    function withdrawCollateral(address collateral, uint256 amount) external;
    function borrowUSD(address collateral, uint256 amount) external;
    function repayUSD(address collateral, uint256 amount) external;
    function liquidate(address borrower, address collateral, uint256 debtToCover)
        external
        returns (uint256 collateralSeized);
    function getHealthFactor(address borrower, address collateral) external view returns (uint256);
    function getVaultPosition(address borrower, address collateral)
        external
        view
        returns (uint256 collateralAmount, uint256 currentDebt);
}
