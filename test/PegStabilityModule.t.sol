// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {PegStabilityModule} from "../src/psm/PegStabilityModule.sol";

contract PegStabilityModuleTest is Test {
    AlkahestUSD public ausd;
    MockERC20 public usdc;
    PegStabilityModule public psm;

    address public alice = address(0x111);

    function setUp() public {
        ausd = new AlkahestUSD();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        psm = new PegStabilityModule(address(ausd), address(usdc));

        ausd.setMinter(address(psm), true);
        ausd.setBurner(address(psm), true);

        // Fund Alice with 100,000 USDC (6 decimals)
        usdc.mint(alice, 100_000 * 1e6);

        vm.startPrank(alice);
        usdc.approve(address(psm), type(uint256).max);
        ausd.approve(address(psm), type(uint256).max);
        vm.stopPrank();
    }

    function test_SwapUSDCForAUSD() public {
        uint256 usdcAmount = 10_000 * 1e6; // $10,000 USDC

        vm.prank(alice);
        uint256 ausdReceived = psm.swapExactUnderlyingForAUSD(usdcAmount);

        // 10,000 gross AUSD - 10 bps (10 AUSD fee) = 9,990 AUSD
        assertEq(ausdReceived, 9990e18);
        assertEq(ausd.balanceOf(alice), 9990e18);
        assertEq(usdc.balanceOf(address(psm)), usdcAmount);
        assertEq(psm.totalMinted(), 10000e18);
    }

    function test_SwapAUSDForUSDC() public {
        // First fund PSM with reserves
        vm.prank(alice);
        psm.swapExactUnderlyingForAUSD(20_000 * 1e6);

        // Alice now has 19,980 AUSD. Redeem 5,000 AUSD
        uint256 ausdToRedeem = 5000e18;
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 usdcReceived = psm.swapExactAUSDForUnderlying(ausdToRedeem);

        // 5,000 AUSD - 10 bps ($5 fee) = $4,995 net USDC (4,995 * 1e6)
        assertEq(usdcReceived, 4995 * 1e6);
        assertEq(usdc.balanceOf(alice), usdcBefore + 4995 * 1e6);
        assertEq(psm.totalMinted(), 15000e18);
    }

    function test_DebtCeilingEnforcement() public {
        psm.setDebtCeiling(5000e18); // Set ceiling to $5,000 AUSD

        // Trying to swap $10,000 USDC exceeds ceiling
        vm.prank(alice);
        vm.expectRevert(PegStabilityModule.DebtCeilingExceeded.selector);
        psm.swapExactUnderlyingForAUSD(10_000 * 1e6);
    }
}
