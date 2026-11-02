// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPegStabilityModule} from "../interfaces/IPegStabilityModule.sol";
import {IAlkahestUSD} from "../interfaces/IAlkahestUSD.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {MathLib} from "../libraries/MathLib.sol";

/**
 * @title PegStabilityModule (PSM)
 * @author ZengLLQ
 * @notice Provides deterministic 1:1 bidirectional arbitrage liquidity between exogenous
 *         reserve stablecoins (e.g. USDC) and AUSD to maintain peg parity.
 */
contract PegStabilityModule is IPegStabilityModule {
    using MathLib for uint256;

    IAlkahestUSD public immutable ausd;
    IERC20 public immutable underlying;
    uint8 public immutable underlyingDecimals;
    uint256 public immutable scaleFactor; // 10^(18 - decimals)

    address public owner;
    uint16 public mintFeeBps = 10; // 0.1%
    uint16 public redeemFeeBps = 10; // 0.1%
    uint256 public debtCeiling = 50_000_000e18; // 50M AUSD ceiling
    uint256 public totalMinted;

    error Unauthorized();
    error ZeroAmount();
    error DebtCeilingExceeded();
    error InsufficientReserves();
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

    constructor(address _ausd, address _underlying) {
        owner = msg.sender;
        ausd = IAlkahestUSD(_ausd);
        underlying = IERC20(_underlying);
        uint8 dec = underlying.decimals();
        underlyingDecimals = dec;
        scaleFactor = 10 ** (18 - dec);
    }

    function setFees(uint16 _mintFeeBps, uint16 _redeemFeeBps) external onlyOwner {
        mintFeeBps = _mintFeeBps;
        redeemFeeBps = _redeemFeeBps;
        emit FeesUpdated(_mintFeeBps, _redeemFeeBps);
    }

    function setDebtCeiling(uint256 _debtCeiling) external onlyOwner {
        debtCeiling = _debtCeiling;
        emit CeilingUpdated(_debtCeiling);
    }

    function getMintAmountOut(uint256 amountUnderlying)
        public
        view
        override
        returns (uint256 amountAUSDOut, uint256 fee)
    {
        uint256 grossAUSD = amountUnderlying * scaleFactor;
        fee = (grossAUSD * mintFeeBps) / 10000;
        amountAUSDOut = grossAUSD - fee;
    }

    function getRedeemAmountOut(uint256 amountAUSD)
        public
        view
        override
        returns (uint256 amountUnderlyingOut, uint256 fee)
    {
        fee = (amountAUSD * redeemFeeBps) / 10000;
        uint256 netAUSD = amountAUSD - fee;
        amountUnderlyingOut = netAUSD / scaleFactor;
    }

    function swapExactUnderlyingForAUSD(uint256 amountUnderlying)
        external
        override
        nonReentrant
        returns (uint256 amountAUSDOut)
    {
        if (amountUnderlying == 0) revert ZeroAmount();
        uint256 fee;
        (amountAUSDOut, fee) = getMintAmountOut(amountUnderlying);

        if (totalMinted + amountAUSDOut + fee > debtCeiling) {
            revert DebtCeilingExceeded();
        }

        totalMinted += (amountAUSDOut + fee);

        // Pull underlying reserve token
        bool success = underlying.transferFrom(msg.sender, address(this), amountUnderlying);
        if (!success) revert TransferFailed();

        // Mint AUSD to user
        ausd.mint(msg.sender, amountAUSDOut);

        emit PSMSwappedToAUSD(msg.sender, amountUnderlying, amountAUSDOut, fee);
    }

    function swapExactAUSDForUnderlying(uint256 amountAUSD)
        external
        override
        nonReentrant
        returns (uint256 amountUnderlyingOut)
    {
        if (amountAUSD == 0) revert ZeroAmount();
        uint256 fee;
        (amountUnderlyingOut, fee) = getRedeemAmountOut(amountAUSD);

        if (underlying.balanceOf(address(this)) < amountUnderlyingOut) {
            revert InsufficientReserves();
        }

        if (amountAUSD <= totalMinted) {
            totalMinted -= amountAUSD;
        } else {
            totalMinted = 0;
        }

        // Burn user AUSD
        ausd.burn(msg.sender, amountAUSD);

        emit PSMSwappedFromAUSD(msg.sender, amountAUSD, amountUnderlyingOut, fee);

        // Deliver underlying reserve token
        bool success = underlying.transfer(msg.sender, amountUnderlyingOut);
        if (!success) revert TransferFailed();
    }
}
