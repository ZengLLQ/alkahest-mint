// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {IAlkahestUSD} from "../interfaces/IAlkahestUSD.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IStabilityPool} from "../interfaces/IStabilityPool.sol";
import {IDutchAuctionLiquidator} from "../interfaces/IDutchAuctionLiquidator.sol";
import {IPIDRateController} from "../interfaces/IPIDRateController.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {MathLib} from "../libraries/MathLib.sol";

/**
 * @title VaultManager
 * @author ZengLLQ
 * @notice Core Collateralized Debt Position (CDP) engine of AlkahestMint.
 *         Governs multi-collateral vaults, dynamic interest compounding,
 *         health factor validation, and dual-layer liquidations.
 */
contract VaultManager is IVaultManager {
    using MathLib for uint256;

    IAlkahestUSD public immutable ausd;
    IPriceOracle public oracle;
    IStabilityPool public stabilityPool;
    IDutchAuctionLiquidator public dutchLiquidator;
    IPIDRateController public rateController;

    address public owner;
    address public feeReceiver;
    uint16 public borrowFeeBps = 50; // 0.5% mint fee
    uint16 public closeFactorBps = 5000; // 50% max liquidation close factor per call

    mapping(address => CollateralConfig) public collateralConfigs;
    address[] public supportedCollaterals;

    // user => collateral => VaultPosition
    mapping(address => mapping(address => VaultPosition)) public vaults;

    // Custom Errors
    error Unauthorized();
    error CollateralNotAllowed();
    error ZeroAmount();
    error DebtCeilingExceeded();
    error InsufficientCollateral();
    error PositionHealthy(uint256 healthFactor);
    error HealthFactorBelowMin(uint256 healthFactor);
    error ExceedsCloseFactor();
    error TransferFailed();
    error ReentrancyGuard();

    uint256 private _locked;

    modifier nonReentrant() {
        if (_locked != 0) revert ReentrancyGuard();
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _ausd, address _oracle) {
        owner = msg.sender;
        feeReceiver = msg.sender;
        ausd = IAlkahestUSD(_ausd);
        oracle = IPriceOracle(_oracle);
    }

    function setStabilityPool(address _stabilityPool) external onlyOwner {
        stabilityPool = IStabilityPool(_stabilityPool);
    }

    function setDutchLiquidator(address _dutchLiquidator) external onlyOwner {
        dutchLiquidator = IDutchAuctionLiquidator(_dutchLiquidator);
    }

    function setRateController(address _rateController) external onlyOwner {
        rateController = IPIDRateController(_rateController);
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    function configureCollateral(
        address collateral,
        uint16 maxLTV,
        uint16 liquidationThreshold,
        uint16 liquidationPenalty,
        uint256 debtCeiling
    ) external onlyOwner {
        require(maxLTV < liquidationThreshold, "maxLTV must be < liquidationThreshold");
        require(liquidationThreshold <= 10000, "threshold cannot exceed 100%");

        uint8 decimals = IERC20(collateral).decimals();
        bool alreadySupported = collateralConfigs[collateral].isAllowed;

        collateralConfigs[collateral] = CollateralConfig({
            isAllowed: true,
            decimals: decimals,
            maxLTV: maxLTV,
            liquidationThreshold: liquidationThreshold,
            liquidationPenalty: liquidationPenalty,
            debtCeiling: debtCeiling,
            totalDeposited: collateralConfigs[collateral].totalDeposited,
            totalBorrowed: collateralConfigs[collateral].totalBorrowed,
            cumulativeBorrowIndex: collateralConfigs[collateral].cumulativeBorrowIndex == 0
                ? MathLib.RAY
                : collateralConfigs[collateral].cumulativeBorrowIndex,
            lastAccrualTimestamp: block.timestamp,
            borrowRatePerSecond: 1e27 + 1.24e18 // ~4% APY default
        });

        if (!alreadySupported) {
            supportedCollaterals.push(collateral);
        }

        emit CollateralConfigured(collateral, maxLTV, liquidationThreshold);
    }

    function accrueInterest(address collateral) public {
        CollateralConfig storage config = collateralConfigs[collateral];
        if (!config.isAllowed) revert CollateralNotAllowed();

        uint256 elapsed = block.timestamp - config.lastAccrualTimestamp;
        if (elapsed == 0) return;

        // Optionally fetch updated rate from PID controller if available
        if (address(rateController) != address(0)) {
            config.borrowRatePerSecond = rateController.getCurrentBorrowRate();
        }

        uint256 compoundingFactor = MathLib.calculateCompoundedInterest(config.borrowRatePerSecond, elapsed);
        config.cumulativeBorrowIndex = MathLib.rayMul(config.cumulativeBorrowIndex, compoundingFactor);
        config.lastAccrualTimestamp = block.timestamp;
    }

    function depositCollateral(address collateral, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(collateral);

        CollateralConfig storage config = collateralConfigs[collateral];
        if (!config.isAllowed) revert CollateralNotAllowed();

        vaults[msg.sender][collateral].collateralAmount += amount;
        config.totalDeposited += amount;

        bool success = IERC20(collateral).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        emit CollateralDeposited(msg.sender, collateral, amount);
    }

    function withdrawCollateral(address collateral, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(collateral);

        VaultPosition storage pos = vaults[msg.sender][collateral];
        if (pos.collateralAmount < amount) revert InsufficientCollateral();

        pos.collateralAmount -= amount;
        collateralConfigs[collateral].totalDeposited -= amount;

        // Check health factor after withdrawal if position has debt
        if (pos.debtShares > 0) {
            uint256 hf = getHealthFactor(msg.sender, collateral);
            if (hf < 1e18) revert HealthFactorBelowMin(hf);
        }

        emit CollateralWithdrawn(msg.sender, collateral, amount);

        bool success = IERC20(collateral).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
    }

    function borrowUSD(address collateral, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(collateral);

        CollateralConfig storage config = collateralConfigs[collateral];
        if (!config.isAllowed) revert CollateralNotAllowed();

        uint256 fee = (amount * borrowFeeBps) / 10000;
        uint256 grossDebt = amount + fee;

        if (config.totalBorrowed + grossDebt > config.debtCeiling) {
            revert DebtCeilingExceeded();
        }

        // Convert gross debt into debt shares: shares = grossDebt / cumulativeIndex
        uint256 sharesToMint = MathLib.rayDiv(grossDebt * 1e9, config.cumulativeBorrowIndex) / 1e9;

        VaultPosition storage pos = vaults[msg.sender][collateral];
        pos.debtShares += sharesToMint;
        config.totalBorrowed += grossDebt;

        // Check that new position respects max LTV
        uint256 collateralValueUSD = _getCollateralValueUSD(collateral, pos.collateralAmount);
        uint256 maxBorrowable = (collateralValueUSD * config.maxLTV) / 10000;
        uint256 currentDebt = _getCurrentDebt(pos.debtShares, config.cumulativeBorrowIndex);

        if (currentDebt > maxBorrowable) {
            revert HealthFactorBelowMin((maxBorrowable * 1e18) / currentDebt);
        }

        // Mint net amount to borrower, fee to feeReceiver
        ausd.mint(msg.sender, amount);
        if (fee > 0) {
            ausd.mint(feeReceiver, fee);
        }

        emit USDBorrowed(msg.sender, collateral, amount, fee);
    }

    function repayUSD(address collateral, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(collateral);

        CollateralConfig storage config = collateralConfigs[collateral];
        VaultPosition storage pos = vaults[msg.sender][collateral];

        uint256 currentDebt = _getCurrentDebt(pos.debtShares, config.cumulativeBorrowIndex);
        uint256 repayAmount = MathLib.min(amount, currentDebt);

        uint256 sharesToBurn = (repayAmount * pos.debtShares) / currentDebt;
        pos.debtShares -= sharesToBurn;

        if (repayAmount <= config.totalBorrowed) {
            config.totalBorrowed -= repayAmount;
        } else {
            config.totalBorrowed = 0;
        }

        ausd.burn(msg.sender, repayAmount);

        emit USDRepaid(msg.sender, collateral, repayAmount);
    }

    function liquidate(address borrower, address collateral, uint256 debtToCover)
        external
        override
        nonReentrant
        returns (uint256 collateralSeized)
    {
        if (debtToCover == 0) revert ZeroAmount();
        accrueInterest(collateral);

        CollateralConfig storage config = collateralConfigs[collateral];
        VaultPosition storage pos = vaults[borrower][collateral];

        uint256 hf = getHealthFactor(borrower, collateral);
        if (hf >= 1e18) revert PositionHealthy(hf);

        uint256 totalDebt = _getCurrentDebt(pos.debtShares, config.cumulativeBorrowIndex);
        uint256 maxClose = (totalDebt * closeFactorBps) / 10000;
        uint256 actualDebtCover = MathLib.min(debtToCover, maxClose);

        // Seize calculation with liquidation penalty bonus
        uint256 priceWad = oracle.getPrice(collateral);
        uint256 bonusWad = 1e18 + (uint256(config.liquidationPenalty) * 1e18) / 10000;
        uint256 seizeValueUSD = (actualDebtCover * bonusWad) / 1e18;

        // Convert USD value to collateral token units
        uint256 scale = 10 ** (18 - config.decimals);
        collateralSeized = (seizeValueUSD * 1e18) / (priceWad * scale);
        collateralSeized = MathLib.min(collateralSeized, pos.collateralAmount);

        // Burn debt shares
        uint256 sharesBurned = (actualDebtCover * pos.debtShares) / totalDebt;
        pos.debtShares -= sharesBurned;
        pos.collateralAmount -= collateralSeized;
        config.totalDeposited -= collateralSeized;

        if (actualDebtCover <= config.totalBorrowed) {
            config.totalBorrowed -= actualDebtCover;
        } else {
            config.totalBorrowed = 0;
        }

        emit VaultLiquidated(
            borrower, collateral, msg.sender, actualDebtCover, collateralSeized, config.liquidationPenalty
        );

        // Layer 1: Check if Stability Pool absorbs bad debt
        uint256 stabilityPoolBalance = address(stabilityPool) != address(0) ? stabilityPool.totalAUSDDeposited() : 0;

        if (stabilityPoolBalance >= actualDebtCover && address(stabilityPool) != address(0)) {
            // Transfer seized collateral to Stability Pool
            bool success = IERC20(collateral).transfer(address(stabilityPool), collateralSeized);
            if (!success) revert TransferFailed();
            stabilityPool.offsetDebt(collateral, actualDebtCover, collateralSeized);
        } else {
            // Layer 2: Liquidator covers debt directly with AUSD and receives collateral
            ausd.burn(msg.sender, actualDebtCover);
            bool success = IERC20(collateral).transfer(msg.sender, collateralSeized);
            if (!success) revert TransferFailed();
        }
    }

    function getHealthFactor(address borrower, address collateral) public view override returns (uint256) {
        VaultPosition memory pos = vaults[borrower][collateral];
        if (pos.debtShares == 0) return type(uint256).max;

        CollateralConfig memory config = collateralConfigs[collateral];
        uint256 currentDebt = _getCurrentDebt(pos.debtShares, config.cumulativeBorrowIndex);
        if (currentDebt == 0) return type(uint256).max;

        uint256 collateralValueUSD = _getCollateralValueUSD(collateral, pos.collateralAmount);
        uint256 thresholdValue = (collateralValueUSD * config.liquidationThreshold) / 10000;

        return (thresholdValue * 1e18) / currentDebt;
    }

    function getVaultPosition(address borrower, address collateral)
        external
        view
        override
        returns (uint256 collateralAmount, uint256 currentDebt)
    {
        VaultPosition memory pos = vaults[borrower][collateral];
        collateralAmount = pos.collateralAmount;
        currentDebt = _getCurrentDebt(pos.debtShares, collateralConfigs[collateral].cumulativeBorrowIndex);
    }

    function _getCollateralValueUSD(address collateral, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 priceWad = oracle.getPrice(collateral);
        uint8 dec = collateralConfigs[collateral].decimals;
        uint256 scale = 10 ** (18 - dec);
        return (amount * scale * priceWad) / 1e18;
    }

    function _getCurrentDebt(uint256 shares, uint256 indexRay) internal pure returns (uint256) {
        if (shares == 0) return 0;
        return (shares * indexRay) / MathLib.RAY;
    }
}
