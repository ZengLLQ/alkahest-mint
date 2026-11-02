// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {DutchAuctionLiquidator} from "../src/auction/DutchAuctionLiquidator.sol";

contract DutchAuctionLiquidatorTest is Test {
    AlkahestUSD public ausd;
    MockERC20 public weth;
    DutchAuctionLiquidator public liquidator;

    address public manager = address(0x999);
    address public borrower = address(0x111);
    address public buyer = address(0x222);

    function setUp() public {
        ausd = new AlkahestUSD();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        liquidator = new DutchAuctionLiquidator(address(ausd));

        ausd.setBurner(address(liquidator), true);
        liquidator.setVaultManager(manager);

        // Fund liquidator with 5 WETH collateral
        weth.mint(address(liquidator), 5e18);

        // Fund buyer with 20,000 AUSD
        ausd.mint(buyer, 20000e18);
        vm.prank(buyer);
        ausd.approve(address(liquidator), type(uint256).max);
    }

    function test_LinearPriceDecay() public {
        // Start auction: 5 WETH seized for 10,000 AUSD debt.
        // Start price: $3,000 WAD, Floor price: $2,000 WAD, Duration: 3600s
        uint256 t0 = block.timestamp;
        vm.prank(manager);
        uint256 aucId = liquidator.startAuction(borrower, address(weth), 10000e18, 5e18, 3000e18, 2000e18, 3600);

        // At t=0: price = 3000
        assertEq(liquidator.getCurrentPrice(aucId), 3000e18);

        // At t=1800 (halfway): price = 2500
        vm.warp(t0 + 1800);
        assertEq(liquidator.getCurrentPrice(aucId), 2500e18);

        // At t=3600 (expired/floor): price = 2000
        vm.warp(t0 + 3600);
        assertEq(liquidator.getCurrentPrice(aucId), 2000e18);

        // Past duration: remains at floor
        vm.warp(t0 + 4600);
        assertEq(liquidator.getCurrentPrice(aucId), 2000e18);
    }

    function test_BuyCollateral_SettlesAndDistributesSurplus() public {
        vm.prank(manager);
        uint256 aucId = liquidator.startAuction(
            borrower,
            address(weth),
            10000e18, // Debt to cover
            5e18, // 5 WETH collateral
            3000e18,
            2000e18,
            3600
        );

        // Fast-forward to price = $2,400 (elapsed = 2160s)
        vm.warp(block.timestamp + 2160);
        uint256 price = liquidator.getCurrentPrice(aucId);
        assertEq(price, 2400e18);

        // 5 WETH * $2,400 = 12,000 AUSD payment
        // Debt = 10,000 AUSD (burned), Surplus = 2,000 AUSD (sent to borrower)
        vm.prank(buyer);
        (uint256 colBought, uint256 payment) = liquidator.buyCollateral(aucId, 2500e18);

        assertEq(colBought, 5e18);
        assertEq(payment, 12000e18);
        assertEq(weth.balanceOf(buyer), 5e18);
        assertEq(ausd.balanceOf(borrower), 2000e18); // Surplus received!
    }

    function test_BuyCollateral_ExceedsMaxPriceReverts() public {
        vm.prank(manager);
        uint256 aucId = liquidator.startAuction(borrower, address(weth), 10000e18, 5e18, 3000e18, 2000e18, 3600);

        // At t=0 price is 3000. Buyer specifies maxPrice 2500 -> Reverts
        vm.prank(buyer);
        vm.expectRevert();
        liquidator.buyCollateral(aucId, 2500e18);
    }
}
