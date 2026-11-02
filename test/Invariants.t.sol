// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {VaultManager} from "../src/vault/VaultManager.sol";
import {StabilityPool} from "../src/stability/StabilityPool.sol";
import {PegStabilityModule} from "../src/psm/PegStabilityModule.sol";

contract InvariantsTest is Test {
    AlkahestUSD public ausd;
    PriceOracle public oracle;
    VaultManager public vaultManager;
    StabilityPool public pool;
    PegStabilityModule public psm;
    MockERC20 public weth;
    MockERC20 public usdc;

    address public alice = address(0x111);
    address public bob = address(0x222);

    function setUp() public {
        ausd = new AlkahestUSD();
        oracle = new PriceOracle();
        vaultManager = new VaultManager(address(ausd), address(oracle));
        pool = new StabilityPool(address(ausd));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        psm = new PegStabilityModule(address(ausd), address(usdc));

        ausd.setMinter(address(vaultManager), true);
        ausd.setBurner(address(vaultManager), true);
        ausd.setMinter(address(psm), true);
        ausd.setBurner(address(psm), true);
        ausd.setBurner(address(pool), true);

        vaultManager.setStabilityPool(address(pool));
        pool.setVaultManager(address(vaultManager));

        oracle.setDirectPrice(address(weth), 3000e18, 3600);
        vaultManager.configureCollateral(address(weth), 8000, 8500, 500, 100_000_000e18);

        weth.mint(alice, 1000e18);
        usdc.mint(bob, 1_000_000 * 1e6);

        vm.prank(alice);
        weth.approve(address(vaultManager), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(psm), type(uint256).max);
    }

    /// @notice Fuzz test that whenever a borrow succeeds, the health factor is >= 1.0 (1e18)
    function testFuzz_BorrowAlwaysPreservesHealthFactor(uint256 colAmount, uint256 borrowAmount) public {
        // Bound inputs to reasonable ranges
        colAmount = bound(colAmount, 1e18, 100e18); // 1 to 100 WETH ($3,000 to $300,000)
        // Max borrowable is 80% LTV of collateral, discounted for 50 bps borrow fee
        uint256 maxBorrow = (colAmount * 3000 * 80) / 100;
        maxBorrow = (maxBorrow * 10000) / 10050; // account for 50 bps borrow fee
        borrowAmount = bound(borrowAmount, 100e18, maxBorrow);

        vm.startPrank(alice);
        vaultManager.depositCollateral(address(weth), colAmount);
        vaultManager.borrowUSD(address(weth), borrowAmount);
        vm.stopPrank();

        uint256 hf = vaultManager.getHealthFactor(alice, address(weth));
        assertGe(hf, 1e18);
    }

    /// @notice Fuzz test PSM mint and redeem roundtrip preserves reserve balance
    function testFuzz_PSM_RoundtripPreservation(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 100 * 1e6, 500_000 * 1e6); // $100 to $500,000 USDC

        vm.startPrank(bob);
        uint256 ausdOut = psm.swapExactUnderlyingForAUSD(usdcIn);
        assertGt(ausdOut, 0);

        ausd.approve(address(psm), ausdOut);
        uint256 usdcBack = psm.swapExactAUSDForUnderlying(ausdOut);
        vm.stopPrank();

        // Roundtrip loses only fees (20 bps total)
        assertLt(usdcBack, usdcIn);
        uint256 feeLoss = usdcIn - usdcBack;
        // Total fee should be roughly 0.2% of input
        assertLe(feeLoss, (usdcIn * 25) / 10000);
    }

    /// @notice Invariant: Total stability pool shares match deposit balance
    function testFuzz_StabilityPoolShareConservation(uint256 dep1, uint256 dep2) public {
        dep1 = bound(dep1, 100e18, 50_000e18);
        dep2 = bound(dep2, 100e18, 50_000e18);

        ausd.mint(alice, dep1);
        ausd.mint(bob, dep2);

        vm.startPrank(alice);
        ausd.approve(address(pool), dep1);
        pool.deposit(dep1);
        vm.stopPrank();

        vm.startPrank(bob);
        ausd.approve(address(pool), dep2);
        pool.deposit(dep2);
        vm.stopPrank();

        assertEq(pool.totalAUSDDeposited(), dep1 + dep2);
        assertEq(pool.totalShares(), pool.sharesOf(alice) + pool.sharesOf(bob));
    }
}
