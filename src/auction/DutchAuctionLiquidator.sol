// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDutchAuctionLiquidator} from "../interfaces/IDutchAuctionLiquidator.sol";
import {IAlkahestUSD} from "../interfaces/IAlkahestUSD.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {MathLib} from "../libraries/MathLib.sol";

/**
 * @title DutchAuctionLiquidator
 * @author ZengLLQ
 * @notice Executes continuous descending linear Dutch auctions for seized vault collateral.
 */
contract DutchAuctionLiquidator is IDutchAuctionLiquidator {
    using MathLib for uint256;

    IAlkahestUSD public immutable ausd;
    address public vaultManager;
    address public owner;

    event VaultManagerUpdated(address indexed newManager);

    uint256 public nextAuctionId = 1;
    mapping(uint256 => Auction) public auctions;
    mapping(address => uint256) public borrowerSurplus;

    error Unauthorized();
    error ZeroAddress();
    error AuctionAlreadySettled();
    error PriceExceedsMax(uint256 currentPrice, uint256 maxPrice);
    error AuctionExpired();
    error InvalidParameters();
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

    function startAuction(
        address borrower,
        address collateral,
        uint256 debtToCover,
        uint256 collateralAmount,
        uint256 startPriceWad,
        uint256 floorPriceWad,
        uint256 duration
    ) external override onlyVaultManager returns (uint256 auctionId) {
        if (duration == 0 || floorPriceWad >= startPriceWad || collateralAmount == 0) {
            revert InvalidParameters();
        }

        auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            borrower: borrower,
            collateral: collateral,
            debtToCover: debtToCover,
            collateralAmount: collateralAmount,
            startPriceWad: startPriceWad,
            floorPriceWad: floorPriceWad,
            startTime: block.timestamp,
            duration: duration,
            settled: false
        });

        emit AuctionStarted(auctionId, borrower, collateral, debtToCover, collateralAmount, startPriceWad);
    }

    function getCurrentPrice(uint256 auctionId) public view override returns (uint256) {
        Auction memory auc = auctions[auctionId];
        if (auc.settled) return 0;

        uint256 elapsed = block.timestamp - auc.startTime;
        if (elapsed >= auc.duration) {
            return auc.floorPriceWad;
        }

        uint256 priceDrop = ((auc.startPriceWad - auc.floorPriceWad) * elapsed) / auc.duration;
        return auc.startPriceWad - priceDrop;
    }

    function buyCollateral(uint256 auctionId, uint256 maxPriceWad)
        external
        override
        nonReentrant
        returns (uint256 collateralPurchased, uint256 paymentAUSD)
    {
        Auction storage auc = auctions[auctionId];
        if (auc.settled) revert AuctionAlreadySettled();

        uint256 currentPrice = getCurrentPrice(auctionId);
        if (currentPrice > maxPriceWad) {
            revert PriceExceedsMax(currentPrice, maxPriceWad);
        }

        auc.settled = true;
        collateralPurchased = auc.collateralAmount;

        // Calculate total AUSD required = (collateralAmount * currentPrice) / 1e18
        paymentAUSD = (collateralPurchased * currentPrice) / 1e18;

        // Pull payment AUSD from buyer
        ausd.transferFrom(msg.sender, address(this), paymentAUSD);

        // Burn debt portion of AUSD
        uint256 debtPortion = MathLib.min(paymentAUSD, auc.debtToCover);
        ausd.burn(address(this), debtPortion);

        // Send surplus to borrower if payment exceeds debt
        if (paymentAUSD > debtPortion) {
            uint256 surplus = paymentAUSD - debtPortion;
            borrowerSurplus[auc.borrower] += surplus;
            ausd.transfer(auc.borrower, surplus);
        }

        emit AuctionSettled(auctionId, msg.sender, collateralPurchased, paymentAUSD);

        // Deliver seized collateral to buyer
        bool success = IERC20(auc.collateral).transfer(msg.sender, collateralPurchased);
        if (!success) revert TransferFailed();
    }
}
