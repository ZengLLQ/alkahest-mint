// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStabilityPool} from "../interfaces/IStabilityPool.sol";
import {IAlkahestUSD} from "../interfaces/IAlkahestUSD.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {MathLib} from "../libraries/MathLib.sol";

/**
 * @title StabilityPool
 * @author ZengLLQ
 * @notice Absorbs undercollateralized vault debt using pooled AUSD deposits and distributes
 *         discounted liquidated collateral to depositors via share-indexed accounting.
 */
contract StabilityPool is IStabilityPool {
    using MathLib for uint256;

    IAlkahestUSD public immutable ausd;
    address public vaultManager;
    address public owner;

    event VaultManagerUpdated(address indexed newManager);

    uint256 public override totalAUSDDeposited;
    uint256 public totalShares;

    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public rewardPerShareSnapshot; // user => collateral => snapshot
    mapping(address => mapping(address => uint256)) public accumulatedRewards; // user => collateral => pending

    // collateral => cumulativeRewardPerShare (in WAD)
    mapping(address => uint256) public cumulativeRewardPerShare;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares();
    error TransferFailed();
    error ReentrancyGuard();

    uint256 private _locked;

    modifier nonReentrant() {
        if (_locked != 0) revert ReentrancyGuard();
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _ausd) {
        owner = msg.sender;
        ausd = IAlkahestUSD(_ausd);
    }

    function setVaultManager(address _vaultManager) external onlyOwner {
        if (_vaultManager == address(0)) revert ZeroAddress();
        vaultManager = _vaultManager;
        emit VaultManagerUpdated(_vaultManager);
    }

    /// @notice Deposits AUSD into the stability pool
    function deposit(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 sharesToMint;
        if (totalShares == 0 || totalAUSDDeposited == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalAUSDDeposited;
        }

        // Pull AUSD from depositor
        ausd.transferFrom(msg.sender, address(this), amount);

        sharesOf[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalAUSDDeposited += amount;

        emit StabilityDeposit(msg.sender, amount);
    }

    /// @notice Withdraws AUSD proportional to current pool share value
    function withdraw(uint256 shareAmount) external override nonReentrant {
        if (shareAmount == 0) revert ZeroAmount();
        if (sharesOf[msg.sender] < shareAmount) revert InsufficientShares();

        uint256 ausdAmount = (shareAmount * totalAUSDDeposited) / totalShares;

        sharesOf[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalAUSDDeposited -= ausdAmount;

        emit StabilityWithdrawal(msg.sender, ausdAmount);

        ausd.transfer(msg.sender, ausdAmount);
    }

    /// @notice Called by VaultManager during liquidation to offset bad debt
    function offsetDebt(address collateral, uint256 debtToOffset, uint256 collateralToAdd)
        external
        override
        onlyVaultManager
        returns (uint256 debtAbsorbed, uint256 collateralRewarded)
    {
        if (totalAUSDDeposited == 0 || totalShares == 0) {
            return (0, 0);
        }

        // Absorb up to available pool deposits
        debtAbsorbed = MathLib.min(debtToOffset, totalAUSDDeposited);
        collateralRewarded = (collateralToAdd * debtAbsorbed) / debtToOffset;

        // Burn the absorbed AUSD debt from the pool
        totalAUSDDeposited -= debtAbsorbed;
        ausd.burn(address(this), debtAbsorbed);

        // Update cumulative reward per share for depositors
        uint256 rewardDelta = (collateralRewarded * 1e18) / totalShares;
        cumulativeRewardPerShare[collateral] += rewardDelta;

        emit DebtOffset(collateral, debtAbsorbed, collateralRewarded);
    }

    /// @notice Claims accumulated collateral liquidation rewards for a specific asset
    function claimRewards(address collateral) external override nonReentrant returns (uint256 amountClaimed) {
        amountClaimed = _updateUserRewards(msg.sender, collateral);
        if (amountClaimed > 0) {
            accumulatedRewards[msg.sender][collateral] = 0;
            emit RewardsClaimed(msg.sender, collateral, amountClaimed);
            bool success = IERC20(collateral).transfer(msg.sender, amountClaimed);
            if (!success) revert TransferFailed();
        }
    }

    /// @notice Computes current claimable collateral rewards for user
    function getDepositorCollateralGain(address user, address collateral) external view override returns (uint256) {
        uint256 userShares = sharesOf[user];
        uint256 pending = accumulatedRewards[user][collateral];
        uint256 snapshot = rewardPerShareSnapshot[user][collateral];
        uint256 currentRewardPerShare = cumulativeRewardPerShare[collateral];

        if (currentRewardPerShare > snapshot && userShares > 0) {
            uint256 delta = currentRewardPerShare - snapshot;
            pending += (userShares * delta) / 1e18;
        }
        return pending;
    }

    function getDepositorBalance(address user) external view override returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[user] * totalAUSDDeposited) / totalShares;
    }

    function _updateUserRewards(address user, address collateral) internal returns (uint256) {
        uint256 userShares = sharesOf[user];
        uint256 snapshot = rewardPerShareSnapshot[user][collateral];
        uint256 currentRewardPerShare = cumulativeRewardPerShare[collateral];

        if (currentRewardPerShare > snapshot) {
            if (userShares > 0) {
                uint256 delta = currentRewardPerShare - snapshot;
                accumulatedRewards[user][collateral] += (userShares * delta) / 1e18;
            }
            rewardPerShareSnapshot[user][collateral] = currentRewardPerShare;
        }

        return accumulatedRewards[user][collateral];
    }
}
