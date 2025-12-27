// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Script, console } from "forge-std/Script.sol";
import { Vault } from "../src/Vault.sol";
import { AutomationVault } from "../src/AutomationVault.sol";

/**
 * @title DeployVault
 * @notice Deployment script for cross-chain lending automation vault system
 * @dev Deploys Vault A, Vault B, and AutomationVault on the destination chain (e.g., Sepolia)
 *      ReactiveVault must be deployed separately on Reactive Network (Lasna)
 */
contract DeployVault is Script {
    // ============ Configuration ============
    
    // Vault A Configuration (Lower APY)
    uint256 public constant VAULT_A_BASE_RATE = 300; // 3% base APY
    uint256 public constant VAULT_A_SLOPE = 1000; // 10% max slope
    uint256 public constant VAULT_A_OPTIMAL_DEPOSITS = 10_000 * 1e6; // 10K USDC
    
    // Vault B Configuration (Higher APY)
    uint256 public constant VAULT_B_BASE_RATE = 500; // 5% base APY
    uint256 public constant VAULT_B_SLOPE = 1500; // 15% max slope
    uint256 public constant VAULT_B_OPTIMAL_DEPOSITS = 10_000 * 1e6; // 10K USDC
    
    // AutomationVault Configuration
    uint256 public constant MIN_REBALANCE_INTERVAL = 30; // 30 seconds
    
    // Chain-specific addresses
    address public constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address public constant SEPOLIA_CALLBACK_PROXY = 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA;

    // ============ Deployment Functions ============

    /**
     * @notice Deploy a single Vault
     */
    function _deployVault(
        address asset,
        uint256 baseRate,
        uint256 slope,
        uint256 optimalDeposits
    ) internal returns (Vault vault) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        vault = new Vault(deployer, asset, baseRate, slope, optimalDeposits);
        vm.stopBroadcast();

        console.log("Vault deployed at:", address(vault));
        console.log("  Base Rate:", baseRate, "bps");
        console.log("  Slope:", slope, "bps");
        
        return vault;
    }

    /**
     * @notice Deploy AutomationVault
     */
    function _deployAutomationVault(
        address asset,
        address poolA,
        address poolB,
        address callbackProxy,
        uint256 minRebalanceInterval
    ) internal returns (AutomationVault automationVault) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        automationVault = new AutomationVault{value: 0.02 ether}(
            asset,
            poolA,
            poolB,
            callbackProxy,
            minRebalanceInterval
        );
        vm.stopBroadcast();

        console.log("AutomationVault deployed at:", address(automationVault));
        
        return automationVault;
    }

    // ============ Main Deployment Functions ============

    /**
     * @notice Default run - deploys to Sepolia
     */
    function run() external {
        deployToSepolia();
    }

    /**
     * @notice Deploy full system to Sepolia
     */
    function deployToSepolia() public {
        console.log("");
        console.log("============================================");
        console.log("  Deploying Cross-Chain Lending Vault System");
        console.log("  Chain: Sepolia (11155111)");
        console.log("============================================");
        console.log("");

        // Deploy Vault A
        console.log("Step 1: Deploying Vault A (3% base APY)...");
        Vault vaultA = _deployVault(
            SEPOLIA_USDC,
            VAULT_A_BASE_RATE,
            VAULT_A_SLOPE,
            VAULT_A_OPTIMAL_DEPOSITS
        );
        console.log("");

        // Deploy Vault B
        console.log("Step 2: Deploying Vault B (5% base APY)...");
        Vault vaultB = _deployVault(
            SEPOLIA_USDC,
            VAULT_B_BASE_RATE,
            VAULT_B_SLOPE,
            VAULT_B_OPTIMAL_DEPOSITS
        );
        console.log("");

        // Deploy AutomationVault
        console.log("Step 3: Deploying AutomationVault...");
        AutomationVault automationVault = _deployAutomationVault(
            SEPOLIA_USDC,
            address(vaultA),
            address(vaultB),
            SEPOLIA_CALLBACK_PROXY,
            MIN_REBALANCE_INTERVAL
        );
        console.log("");

        // Summary
        console.log("============================================");
        console.log("  Deployment Summary");
        console.log("============================================");
        console.log("Vault A:          ", address(vaultA));
        console.log("Vault B:          ", address(vaultB));
        console.log("AutomationVault:  ", address(automationVault));
        console.log("USDC:             ", SEPOLIA_USDC);
        console.log("Callback Proxy:   ", SEPOLIA_CALLBACK_PROXY);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Deploy ReactiveVault on Lasna (Reactive Network)");
        console.log("2. Use the following command:");
        console.log("");
        console.log("   forge create --broadcast --rpc-url https://lasna-rpc.rnk.dev/ \\");
        console.log("     --private-key $PRIVATE_KEY \\");
        console.log("     src/ReactiveVault.sol:ReactiveVault \\");
        console.log("     --value 0.1ether \\");
        console.log("     --constructor-args \\");
        console.log("       0x0000000000000000000000000000000000fffFfF \\");
        console.log("       11155111 \\");
        console.log("       11155111 \\");
        console.log("       <VAULT_A_ADDRESS> \\");
        console.log("       <VAULT_B_ADDRESS> \\");
        console.log("       <AUTOMATION_VAULT_ADDRESS> \\");
        console.log("       100");
        console.log("");
    }

    /**
     * @notice Deploy only Vault A to Sepolia
     */
    function deployVaultAToSepolia() external returns (Vault) {
        console.log("Deploying Vault A to Sepolia...");
        return _deployVault(
            SEPOLIA_USDC,
            VAULT_A_BASE_RATE,
            VAULT_A_SLOPE,
            VAULT_A_OPTIMAL_DEPOSITS
        );
    }

    /**
     * @notice Deploy only Vault B to Sepolia
     */
    function deployVaultBToSepolia() external returns (Vault) {
        console.log("Deploying Vault B to Sepolia...");
        return _deployVault(
            SEPOLIA_USDC,
            VAULT_B_BASE_RATE,
            VAULT_B_SLOPE,
            VAULT_B_OPTIMAL_DEPOSITS
        );
    }

    /**
     * @notice Deploy AutomationVault with existing Vault addresses
     */
    function deployAutomationVaultToSepolia() external returns (AutomationVault) {
        address vaultA = vm.envAddress("VAULT_A");
        address vaultB = vm.envAddress("VAULT_B");
        
        console.log("Deploying AutomationVault to Sepolia...");
        console.log("  Vault A:", vaultA);
        console.log("  Vault B:", vaultB);
        
        return _deployAutomationVault(
            SEPOLIA_USDC,
            vaultA,
            vaultB,
            SEPOLIA_CALLBACK_PROXY,
            MIN_REBALANCE_INTERVAL
        );
    }
}
