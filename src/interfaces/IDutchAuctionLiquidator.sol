// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDutchAuctionLiquidator {
    struct Auction {
        address borrower;
        address collateral;
        uint256 debtToCover;
        uint256 collateralAmount;
        uint256 startPriceWad; // Initial price per unit of collateral
        uint256 floorPriceWad; // Minimum reserve price per unit
        uint256 startTime;
        uint256 duration; // Linear decay duration in seconds
        bool settled;
    }

    event AuctionStarted(
        uint256 indexed auctionId,
        address indexed borrower,
        address indexed collateral,
        uint256 debtToCover,
        uint256 collateralAmount,
        uint256 startPrice
    );
    event AuctionSettled(
        uint256 indexed auctionId, address indexed buyer, uint256 collateralPurchased, uint256 paymentAUSD
    );

    function startAuction(
        address borrower,
        address collateral,
        uint256 debtToCover,
        uint256 collateralAmount,
        uint256 startPriceWad,
        uint256 floorPriceWad,
        uint256 duration
    ) external returns (uint256 auctionId);

    function buyCollateral(uint256 auctionId, uint256 maxPriceWad)
        external
        returns (uint256 collateralPurchased, uint256 paymentAUSD);

    function getCurrentPrice(uint256 auctionId) external view returns (uint256);
}
