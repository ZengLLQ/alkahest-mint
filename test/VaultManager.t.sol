// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {VaultManager} from "../src/vault/VaultManager.sol";

contract VaultManagerTest is Test {
    AlkahestUSD public ausd;
    PriceOracle public oracle;
    VaultManager public vaultManager;
    MockERC20 public weth;
    MockERC20 public wbtc;

    address public owner = address(this);
    address public alice = address(0x111);
    address public bob = address(0x222);

    function setUp() public {
        ausd = new AlkahestUSD();
        oracle = new PriceOracle();
        vaultManager = new VaultManager(address(ausd), address(oracle));

        ausd.setMinter(address(vaultManager), true);
        ausd.setBurner(address(vaultManager), true);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // Price: WETH = $3,000 WAD, WBTC = $60,000 WAD
        oracle.setDirectPrice(address(weth), 3000e18, 3600);
        oracle.setDirectPrice(address(wbtc), 60000e18, 3600);

        // Configure WETH: 80% LTV, 85% Liquidation Threshold, 5% Penalty, 10M Ceiling
        vaultManager.configureCollateral(address(weth), 8000, 8500, 500, 10_000_000e18);

        // Configure WBTC: 70% LTV, 75% Liquidation Threshold, 8% Penalty, 10M Ceiling
        vaultManager.configureCollateral(address(wbtc), 7000, 7500, 800, 10_000_000e18);

        // Fund Alice
        weth.mint(alice, 10e18); // 10 WETH ($30,000)
        wbtc.mint(alice, 1e8); // 1 WBTC ($60,000)

        vm.startPrank(alice);
        weth.approve(address(vaultManager), type(uint256).max);
        wbtc.approve(address(vaultManager), type(uint256).max);
        ausd.approve(address(vaultManager), type(uint256).max);
        vm.stopPrank();
    }

    function test_DepositCollateral() public {
        vm.prank(alice);
        vaultManager.depositCollateral(address(weth), 5e18);

        (uint256 colAmount, uint256 debt) = vaultManager.getVaultPosition(alice, address(weth));
        assertEq(colAmount, 5e18);
        assertEq(debt, 0);
        assertEq(weth.balanceOf(address(vaultManager)), 5e18);
    }

    function test_BorrowUSD_WithinLTV() public {
        vm.startPrank(alice);
        // Deposit 10 WETH ($30,000 value). Max LTV 80% = $24,000
        vaultManager.depositCollateral(address(weth), 10e18);

        // Borrow 20,000 AUSD. Borrow fee 0.5% = 100 AUSD. Gross debt = 20,100 AUSD
        vaultManager.borrowUSD(address(weth), 20000e18);
        vm.stopPrank();

        assertEq(ausd.balanceOf(alice), 20000e18);
        (uint256 col, uint256 debt) = vaultManager.getVaultPosition(alice, address(weth));
        assertEq(col, 10e18);
        assertEq(debt, 20100e18);

        // Health Factor: ($30,000 * 85%) / $20,100 = 25,500 / 20,100 ~ 1.268e18
        uint256 hf = vaultManager.getHealthFactor(alice, address(weth));
        assertGt(hf, 1e18);
    }

    function test_BorrowUSD_ExceedingLTV_Reverts() public {
        vm.startPrank(alice);
        vaultManager.depositCollateral(address(weth), 10e18); // $30,000 value. Max LTV $24,000

        // Borrowing 24,500 AUSD exceeds max LTV
        vm.expectRevert();
        vaultManager.borrowUSD(address(weth), 24500e18);
        vm.stopPrank();
    }

    function test_RepayUSD_ReducesDebt() public {
        vm.startPrank(alice);
        vaultManager.depositCollateral(address(weth), 10e18);
        vaultManager.borrowUSD(address(weth), 10000e18);

        // Repay 5,000 AUSD
        vaultManager.repayUSD(address(weth), 5000e18);
        vm.stopPrank();

        (, uint256 debt) = vaultManager.getVaultPosition(alice, address(weth));
        // Initial gross debt: 10,050. Repaid 5,000 -> 5,050
        assertEq(debt, 5050e18);
        assertEq(ausd.balanceOf(alice), 5000e18);
    }

    function test_WithdrawCollateral_RespectsHealthFactor() public {
        vm.startPrank(alice);
        vaultManager.depositCollateral(address(weth), 10e18);
        vaultManager.borrowUSD(address(weth), 20000e18); // Debt ~20,100

        // Withdrawing 5 WETH leaves 5 WETH ($15,000 value < $20,100 debt) -> Reverts
        vm.expectRevert();
        vaultManager.withdrawCollateral(address(weth), 5e18);

        // Withdrawing 1 WETH leaves 9 WETH ($27,000 * 85% = $22,950 > $20,100) -> Succeeds
        vaultManager.withdrawCollateral(address(weth), 1e18);
        vm.stopPrank();

        (uint256 col,) = vaultManager.getVaultPosition(alice, address(weth));
        assertEq(col, 9e18);
    }

    function test_AccrueInterest_CompoundsOverTime() public {
        vm.startPrank(alice);
        vaultManager.depositCollateral(address(weth), 10e18);
        vaultManager.borrowUSD(address(weth), 10000e18);
        vm.stopPrank();

        (, uint256 debtBefore) = vaultManager.getVaultPosition(alice, address(weth));

        // Fast-forward 1 year (365 days)
        vm.warp(block.timestamp + 365 days);
        vaultManager.accrueInterest(address(weth));

        (, uint256 debtAfter) = vaultManager.getVaultPosition(alice, address(weth));
        // At ~4% APY, debt should grow by approx 4%
        assertGt(debtAfter, debtBefore);
        uint256 growth = debtAfter - debtBefore;
        assertGt(growth, 350e18); // At least 3.5%
        assertLt(growth, 450e18); // Less than 4.5%
    }
}
