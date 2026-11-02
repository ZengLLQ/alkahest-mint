// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {PIDRateController} from "../src/controller/PIDRateController.sol";

contract PIDRateControllerTest is Test {
    AlkahestUSD public ausd;
    PriceOracle public oracle;
    PIDRateController public controller;

    function setUp() public {
        ausd = new AlkahestUSD();
        oracle = new PriceOracle();
        controller = new PIDRateController(address(oracle), address(ausd));

        // Default oracle price = $1.00 WAD
        oracle.setDirectPrice(address(ausd), 1e18, 3600);
    }

    function test_InitialState() public view {
        assertEq(controller.targetPriceWad(), 1e18);
        assertEq(controller.getLatestError(), 0);
        assertGt(controller.getCurrentBorrowRate(), 1e27);
    }

    function test_RateHike_WhenUnderPeg() public {
        uint256 initialRate = controller.getCurrentBorrowRate();

        // Advance time 1 hour, market price drops to $0.96 (below peg)
        vm.warp(block.timestamp + 3600);
        oracle.setDirectPrice(address(ausd), 0.96e18, 3600);

        uint256 newRate = controller.updateStabilityFee();

        // Borrow rate must increase to contract supply and restore peg
        assertGt(newRate, initialRate);
        assertEq(controller.getLatestError(), int256(0.04e18));
    }

    function test_RateCut_WhenOverPeg() public {
        uint256 initialRate = controller.getCurrentBorrowRate();

        // Advance time 1 hour, market price rises to $1.04 (above peg)
        vm.warp(block.timestamp + 3600);
        oracle.setDirectPrice(address(ausd), 1.04e18, 3600);

        uint256 newRate = controller.updateStabilityFee();

        // Borrow rate must decrease to encourage expansion
        assertLt(newRate, initialRate);
        assertEq(controller.getLatestError(), -int256(0.04e18));
    }

    function test_AntiWindupClamping() public {
        // Repeated large negative price swings over several periods
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + 3600);
            oracle.setDirectPrice(address(ausd), 0.5e18, 3600);
            controller.updateStabilityFee();
        }

        // Output rate must stay capped at outputMax without overflow
        uint256 rate = controller.updateStabilityFee();
        assertLe(rate, 1e27 + 7.92e18); // outputMax
    }
}
