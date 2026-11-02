// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {VaultManager} from "../src/vault/VaultManager.sol";
import {StabilityPool} from "../src/stability/StabilityPool.sol";

contract StabilityPoolTest is Test {
    AlkahestUSD public ausd;
    PriceOracle public oracle;
    VaultManager public vaultManager;
    StabilityPool public pool;
    MockERC20 public weth;

    address public alice = address(0x111);
    address public bob = address(0x222);
    address public carol = address(0x333);

    function setUp() public {
        ausd = new AlkahestUSD();
        oracle = new PriceOracle();
        vaultManager = new VaultManager(address(ausd), address(oracle));
        pool = new StabilityPool(address(ausd));

        ausd.setMinter(address(vaultManager), true);
        ausd.setBurner(address(vaultManager), true);
        ausd.setBurner(address(pool), true);

        vaultManager.setStabilityPool(address(pool));
        pool.setVaultManager(address(vaultManager));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle.setDirectPrice(address(weth), 3000e18, 3600);

        // 80% LTV, 85% Liquidation Threshold, 5% Penalty, 10M Ceiling
        vaultManager.configureCollateral(address(weth), 8000, 8500, 500, 10_000_000e18);

        // Alice deposits 10 WETH ($30,000) and borrows 22,000 AUSD (Debt ~ 22,110 AUSD)
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(vaultManager), type(uint256).max);
        vaultManager.depositCollateral(address(weth), 10e18);
        vaultManager.borrowUSD(address(weth), 22000e18);
        vm.stopPrank();

        // Bob is a stability depositor: gets 50,000 AUSD
        ausd.mint(bob, 50000e18);
        vm.startPrank(bob);
        ausd.approve(address(pool), type(uint256).max);
        pool.deposit(30000e18);
        vm.stopPrank();
    }

    function test_StabilityDepositAndWithdraw() public {
        assertEq(pool.totalAUSDDeposited(), 30000e18);
        assertEq(pool.getDepositorBalance(bob), 30000e18);

        vm.prank(bob);
        pool.withdraw(10000e18); // withdraw 10,000 shares
        assertEq(pool.totalAUSDDeposited(), 20000e18);
        assertEq(pool.getDepositorBalance(bob), 20000e18);
    }

    function test_LiquidationAbsorptionByStabilityPool() public {
        // Price drops from $3,000 to $2,300
        // 10 WETH value = $23,000. Threshold 85% = $19,550. Debt = $22,110 -> HF = 19,550 / 22,110 ~ 0.884 < 1.0
        oracle.setDirectPrice(address(weth), 2300e18, 3600);

        uint256 hf = vaultManager.getHealthFactor(alice, address(weth));
        assertLt(hf, 1e18);

        uint256 poolAUSDInitial = pool.totalAUSDDeposited();

        // Carol triggers liquidation of up to 10,000 AUSD debt
        vm.prank(carol);
        uint256 colSeized = vaultManager.liquidate(alice, address(weth), 10000e18);
        assertGt(colSeized, 0);

        // Stability pool absorbed debt: AUSD was burned from pool
        assertLt(pool.totalAUSDDeposited(), poolAUSDInitial);
        assertEq(weth.balanceOf(address(pool)), colSeized);

        // Bob can claim his share of seized WETH
        uint256 claimable = pool.getDepositorCollateralGain(bob, address(weth));
        assertApproxEqAbs(claimable, colSeized, 1e12); // Within 1e-6 precision of seized collateral

        vm.prank(bob);
        uint256 claimed = pool.claimRewards(address(weth));
        assertEq(claimed, claimable);
        assertEq(weth.balanceOf(bob), claimed);
    }
}
