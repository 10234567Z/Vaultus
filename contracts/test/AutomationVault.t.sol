// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";
import { AutomationVault } from "../src/AutomationVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 1e6);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// Mock callback proxy for testing
contract MockCallbackProxy {
    function call(address target, bytes calldata data) external returns (bool, bytes memory) {
        return target.call(data);
    }
}

contract AutomationVaultTest is Test {
    Vault public vaultA;
    Vault public vaultB;
    AutomationVault public automationVault;
    MockUSDC public usdc;
    MockCallbackProxy public callbackProxy;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Vault A: 3% base, 10% slope
    uint256 public constant VAULT_A_BASE_RATE = 300;
    uint256 public constant VAULT_A_SLOPE = 1000;
    
    // Vault B: 5% base, 15% slope
    uint256 public constant VAULT_B_BASE_RATE = 500;
    uint256 public constant VAULT_B_SLOPE = 1500;
    
    uint256 public constant OPTIMAL_DEPOSITS = 1_000_000 * 1e6;
    uint256 public constant MIN_REBALANCE_INTERVAL = 60; // 60 seconds

    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event Rebalanced(address indexed fromPool, address indexed toPool, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy mock callback proxy
        callbackProxy = new MockCallbackProxy();

        // Deploy Vault A (lower base APY)
        vaultA = new Vault(
            owner,
            address(usdc),
            VAULT_A_BASE_RATE,
            VAULT_A_SLOPE,
            OPTIMAL_DEPOSITS
        );

        // Deploy Vault B (higher base APY)
        vaultB = new Vault(
            owner,
            address(usdc),
            VAULT_B_BASE_RATE,
            VAULT_B_SLOPE,
            OPTIMAL_DEPOSITS
        );

        // Deploy AutomationVault
        automationVault = new AutomationVault(
            address(usdc),
            address(vaultA),
            address(vaultB),
            address(callbackProxy),
            MIN_REBALANCE_INTERVAL
        );

        vm.stopPrank();

        // Give users some USDC
        usdc.mint(user1, 100_000 * 1e6);
        usdc.mint(user2, 100_000 * 1e6);

        // Approve AutomationVault
        vm.prank(user1);
        usdc.approve(address(automationVault), type(uint256).max);

        vm.prank(user2);
        usdc.approve(address(automationVault), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(automationVault.asset()), address(usdc));
        assertEq(address(automationVault.poolA()), address(vaultA));
        assertEq(address(automationVault.poolB()), address(vaultB));
        assertEq(automationVault.minRebalanceInterval(), MIN_REBALANCE_INTERVAL);
        assertEq(automationVault.owner(), owner);
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(AutomationVault.AutomationVault__ZeroAddress.selector);
        new AutomationVault(
            address(0),
            address(vaultA),
            address(vaultB),
            address(callbackProxy),
            MIN_REBALANCE_INTERVAL
        );
    }

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(AutomationVault.AutomationVault__ZeroAddress.selector);
        new AutomationVault(
            address(usdc),
            address(0),
            address(vaultB),
            address(callbackProxy),
            MIN_REBALANCE_INTERVAL
        );
    }

    // ============ Deposit Tests ============

    function test_deposit_success() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(depositAmount);

        // Check allocations - should go to higher APY pool (Vault B has 5% vs 3%)
        assertEq(automationVault.allocationB(), depositAmount);
        assertEq(automationVault.allocationA(), 0);
        
        // Check user shares
        assertGt(automationVault.userShares(user1), 0);
    }

    function test_deposit_goesToHigherApyPool() public {
        // Vault B has higher base APY (5% > 3%), so funds should go there
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(depositAmount);

        // Verify Vault B received the deposit
        assertEq(vaultB.getDeposit(address(automationVault)), depositAmount);
        assertEq(vaultA.getDeposit(address(automationVault)), 0);
    }

    function test_deposit_multipleUsers() public {
        uint256 amount1 = 1000 * 1e6;
        uint256 amount2 = 2000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(amount1);

        vm.prank(user2);
        automationVault.deposit(amount2);

        assertGt(automationVault.userShares(user1), 0);
        assertGt(automationVault.userShares(user2), 0);
        assertEq(automationVault.getTotalAssets(), amount1 + amount2);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AutomationVault.AutomationVault__ZeroAmount.selector);
        automationVault.deposit(0);
    }

    // ============ Withdraw Tests ============

    function test_withdraw_success() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.startPrank(user1);
        automationVault.deposit(depositAmount);
        
        uint256 shares = automationVault.userShares(user1);
        uint256 balanceBefore = usdc.balanceOf(user1);
        
        automationVault.withdraw(shares);
        vm.stopPrank();

        uint256 balanceAfter = usdc.balanceOf(user1);
        assertEq(automationVault.userShares(user1), 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        vm.startPrank(user1);
        automationVault.deposit(1000 * 1e6);

        uint256 shares = automationVault.userShares(user1);
        vm.expectRevert(AutomationVault.AutomationVault__InsufficientBalance.selector);
        automationVault.withdraw(shares + 1);
        vm.stopPrank();
    }

    // ============ APY Update & Rebalance Tests ============

    function test_updateAPY_updatesApyA() public {
        // Simulate callback from ReactiveVault via callback proxy
        vm.prank(address(callbackProxy));
        automationVault.updateAPY(address(0), address(vaultA), 400);

        assertEq(automationVault.lastApyA(), 400);
    }

    function test_updateAPY_updatesApyB() public {
        vm.prank(address(callbackProxy));
        automationVault.updateAPY(address(0), address(vaultB), 600);

        assertEq(automationVault.lastApyB(), 600);
    }

    function test_updateAPY_triggersRebalance() public {
        // First, deposit some funds to Vault B (higher APY by default)
        vm.prank(user1);
        automationVault.deposit(1000 * 1e6);

        // Initially funds go to Vault B (higher APY)
        assertEq(vaultB.getDeposit(address(automationVault)), 1000 * 1e6);

        // Simulate APY updates where Vault A becomes much better
        vm.prank(address(callbackProxy));
        automationVault.updateAPY(address(0), address(vaultA), 1000); // 10%
        
        // Warp time to allow rebalance
        vm.warp(block.timestamp + MIN_REBALANCE_INTERVAL + 1);
        
        vm.prank(address(callbackProxy));
        automationVault.updateAPY(address(0), address(vaultB), 200); // 2%

        // Funds should have moved to Vault A (now higher APY)
        assertEq(vaultA.getDeposit(address(automationVault)), 1000 * 1e6);
        assertEq(vaultB.getDeposit(address(automationVault)), 0);
    }

    function test_updateAPY_revertsFromUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        automationVault.updateAPY(address(0), address(vaultA), 400);
    }

    // ============ View Function Tests ============

    function test_getTotalAssets() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(depositAmount);

        assertEq(automationVault.getTotalAssets(), depositAmount);
    }

    function test_getUserBalance() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(depositAmount);

        assertEq(automationVault.getUserBalance(user1), depositAmount);
    }

    function test_getAllocations() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        automationVault.deposit(depositAmount);

        (uint256 poolAAmount, uint256 poolBAmount) = automationVault.getAllocations();
        assertEq(poolAAmount, 0);
        assertEq(poolBAmount, depositAmount);
    }

    function test_getPoolAPYs() public view {
        (uint256 apyA, uint256 apyB) = automationVault.getPoolAPYs();
        assertEq(apyA, VAULT_A_BASE_RATE);
        assertEq(apyB, VAULT_B_BASE_RATE);
    }

    // ============ Owner Function Tests ============

    function test_pause_success() public {
        vm.prank(owner);
        automationVault.pause();

        assertTrue(automationVault.paused());
    }

    function test_pause_preventsDeposit() public {
        vm.prank(owner);
        automationVault.pause();

        vm.prank(user1);
        vm.expectRevert(AutomationVault.AutomationVault__Paused.selector);
        automationVault.deposit(1000 * 1e6);
    }

    function test_unpause_success() public {
        vm.startPrank(owner);
        automationVault.pause();
        automationVault.unpause();
        vm.stopPrank();

        assertFalse(automationVault.paused());
    }

    function test_setMinRebalanceInterval() public {
        vm.prank(owner);
        automationVault.setMinRebalanceInterval(120);

        assertEq(automationVault.minRebalanceInterval(), 120);
    }

    function test_emergencyWithdrawAll() public {
        vm.prank(user1);
        automationVault.deposit(1000 * 1e6);

        vm.prank(owner);
        automationVault.emergencyWithdrawAll();

        assertEq(vaultA.getDeposit(address(automationVault)), 0);
        assertEq(vaultB.getDeposit(address(automationVault)), 0);
        assertGt(usdc.balanceOf(address(automationVault)), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1, 100_000 * 1e6);
        
        vm.prank(user1);
        automationVault.deposit(amount);

        assertEq(automationVault.getTotalAssets(), amount);
    }
}
