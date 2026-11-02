// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {VaultManager} from "../src/vault/VaultManager.sol";
import {StabilityPool} from "../src/stability/StabilityPool.sol";
import {DutchAuctionLiquidator} from "../src/auction/DutchAuctionLiquidator.sol";
import {PegStabilityModule} from "../src/psm/PegStabilityModule.sol";
import {PIDRateController} from "../src/controller/PIDRateController.sol";

contract DeployAlkahestMintScript is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy Core Token
        AlkahestUSD ausd = new AlkahestUSD();
        console.log("AlkahestUSD deployed to:", address(ausd));

        // 2. Deploy Price Oracle
        PriceOracle oracle = new PriceOracle();
        console.log("PriceOracle deployed to:", address(oracle));

        // 3. Deploy Vault Manager
        VaultManager vaultManager = new VaultManager(address(ausd), address(oracle));
        console.log("VaultManager deployed to:", address(vaultManager));

        // 4. Deploy Stability Pool
        StabilityPool stabilityPool = new StabilityPool(address(ausd));
        console.log("StabilityPool deployed to:", address(stabilityPool));

        // 5. Deploy Dutch Auction Liquidator
        DutchAuctionLiquidator dutchLiquidator = new DutchAuctionLiquidator(address(ausd));
        console.log("DutchAuctionLiquidator deployed to:", address(dutchLiquidator));

        // 6. Deploy PID Controller
        PIDRateController pidController = new PIDRateController(address(oracle), address(ausd));
        console.log("PIDRateController deployed to:", address(pidController));

        // 7. Deploy Mock Collaterals for Demonstration
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // 8. Deploy PSM for USDC
        PegStabilityModule psm = new PegStabilityModule(address(ausd), address(usdc));
        console.log("PegStabilityModule deployed to:", address(psm));

        // 9. Wire Permissions & Connections
        ausd.setMinter(address(vaultManager), true);
        ausd.setBurner(address(vaultManager), true);
        ausd.setMinter(address(psm), true);
        ausd.setBurner(address(psm), true);
        ausd.setBurner(address(stabilityPool), true);
        ausd.setBurner(address(dutchLiquidator), true);

        vaultManager.setStabilityPool(address(stabilityPool));
        vaultManager.setDutchLiquidator(address(dutchLiquidator));
        vaultManager.setRateController(address(pidController));

        stabilityPool.setVaultManager(address(vaultManager));
        dutchLiquidator.setVaultManager(address(vaultManager));

        // 10. Initial Oracle Feeds
        oracle.setDirectPrice(address(ausd), 1e18, 3600); // $1.00 USD
        oracle.setDirectPrice(address(weth), 3000e18, 3600); // $3,000 USD
        oracle.setDirectPrice(address(usdc), 1e18, 3600); // $1.00 USD

        // 11. Configure Collaterals in Vault Manager
        // WETH: 80% Max LTV, 85% Liquidation Threshold, 5% Penalty, 100M Ceiling
        vaultManager.configureCollateral(address(weth), 8000, 8500, 500, 100_000_000e18);

        vm.stopBroadcast();
        console.log("AlkahestMint protocol deployed and wired successfully!");
    }
}
