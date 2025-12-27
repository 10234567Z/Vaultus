// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultTest is Test {
    Vault public vault;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant BASE_RATE = 200; // 2%
    uint256 public constant SLOPE = 2000; // 20%
    uint256 public constant OPTIMAL_DEPOSITS = 1_000_000 * 1e18;

    event Vault__Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Vault__Withdraw(address indexed user, uint256 amount, uint256 remainingBalance);

    function setUp() public {
        // Deploy mock token
        token = new MockERC20();

        // Deploy vault
        vault = new Vault(
            owner,
            address(token),
            BASE_RATE,
            SLOPE,
            OPTIMAL_DEPOSITS
        );

        // Give users some tokens
        token.mint(user1, 100_000 * 1e18);
        token.mint(user2, 100_000 * 1e18);

        // Approve vault
        vm.prank(user1);
        token.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(vault.asset()), address(token));
        assertEq(vault.baseRate(), BASE_RATE);
        assertEq(vault.slope(), SLOPE);
        assertEq(vault.optimalDeposits(), OPTIMAL_DEPOSITS);
        assertEq(vault.owner(), owner);
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(Vault.Vault__ZeroAddress.selector);
        new Vault(owner, address(0), BASE_RATE, SLOPE, OPTIMAL_DEPOSITS);
    }

    function test_constructor_revertsOnInvalidAPY() public {
        // Base rate > MAX_APY
        vm.expectRevert(Vault.Vault__InvalidAPY.selector);
        new Vault(owner, address(token), 10001, SLOPE, OPTIMAL_DEPOSITS);

        // Base + Slope > MAX_APY
        vm.expectRevert(Vault.Vault__InvalidAPY.selector);
        new Vault(owner, address(token), 5000, 6000, OPTIMAL_DEPOSITS);
    }

    function test_constructor_revertsOnZeroOptimalDeposits() public {
        vm.expectRevert(Vault.Vault__ZeroAmount.selector);
        new Vault(owner, address(token), BASE_RATE, SLOPE, 0);
    }

    // ============ Deposit Tests ============

    function test_deposit_success() public {
        uint256 depositAmount = 1000 * 1e18;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit Vault__Deposit(user1, depositAmount, depositAmount);
        vault.deposit(depositAmount);

        assertEq(vault.getDeposit(user1), depositAmount);
        assertEq(vault.getTotalDeposits(), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }

    function test_deposit_multipleUsers() public {
        uint256 amount1 = 1000 * 1e18;
        uint256 amount2 = 2000 * 1e18;

        vm.prank(user1);
        vault.deposit(amount1);

        vm.prank(user2);
        vault.deposit(amount2);

        assertEq(vault.getDeposit(user1), amount1);
        assertEq(vault.getDeposit(user2), amount2);
        assertEq(vault.getTotalDeposits(), amount1 + amount2);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__ZeroAmount.selector);
        vault.deposit(0);
    }

    // ============ Withdraw Tests ============

    function test_withdraw_success() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 400 * 1e18;

        vm.startPrank(user1);
        vault.deposit(depositAmount);
        
        vm.expectEmit(true, false, false, true);
        emit Vault__Withdraw(user1, withdrawAmount, depositAmount - withdrawAmount);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(vault.getDeposit(user1), depositAmount - withdrawAmount);
        assertEq(vault.getTotalDeposits(), depositAmount - withdrawAmount);
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        vm.startPrank(user1);
        vault.deposit(1000 * 1e18);

        vm.expectRevert(Vault.Vault__InsufficientBalance.selector);
        vault.withdraw(2000 * 1e18);
        vm.stopPrank();
    }

    function test_withdrawAll_success() public {
        uint256 depositAmount = 1000 * 1e18;

        vm.startPrank(user1);
        vault.deposit(depositAmount);
        vault.withdrawAll();
        vm.stopPrank();

        assertEq(vault.getDeposit(user1), 0);
        assertEq(vault.getTotalDeposits(), 0);
        assertEq(token.balanceOf(user1), 100_000 * 1e18); // Back to original
    }

    function test_withdrawAll_revertsOnNoDeposit() public {
        vm.prank(user1);
        vm.expectRevert(Vault.Vault__NoDeposit.selector);
        vault.withdrawAll();
    }

    // ============ APY Calculation Tests ============

    function test_getAPY_returnsBaseRateWhenNoDeposits() public view {
        assertEq(vault.getAPY(), BASE_RATE);
    }

    function test_getAPY_calculatesCorrectly() public {
        // Deposit 50% of optimal → utilization = 50%
        // APY = 200 + (50% * 2000) = 200 + 1000 = 1200 (12%)
        uint256 halfOptimal = OPTIMAL_DEPOSITS / 2;

        vm.prank(user1);
        token.mint(user1, halfOptimal);
        vm.prank(user1);
        token.approve(address(vault), halfOptimal);
        vm.prank(user1);
        vault.deposit(halfOptimal);

        uint256 expectedAPY = BASE_RATE + (SLOPE / 2); // 200 + 1000 = 1200
        assertEq(vault.getAPY(), expectedAPY);
    }

    function test_getAPY_capsAt100Utilization() public {
        // Deposit 150% of optimal → utilization should cap at 100%
        // APY = 200 + (100% * 2000) = 2200 (22%)
        uint256 overOptimal = (OPTIMAL_DEPOSITS * 150) / 100;
        
        token.mint(user1, overOptimal);
        vm.prank(user1);
        token.approve(address(vault), overOptimal);
        vm.prank(user1);
        vault.deposit(overOptimal);

        uint256 maxAPY = BASE_RATE + SLOPE; // 200 + 2000 = 2200
        assertEq(vault.getAPY(), maxAPY);
    }

    function test_getUtilization_calculatesCorrectly() public {
        // Deposit 25% of optimal
        uint256 quarterOptimal = OPTIMAL_DEPOSITS / 4;
        
        token.mint(user1, quarterOptimal);
        vm.prank(user1);
        token.approve(address(vault), quarterOptimal);
        vm.prank(user1);
        vault.deposit(quarterOptimal);

        // Utilization should be 2500 (25%)
        assertEq(vault.getUtilization(), 2500);
    }

    // ============ Emergency Withdraw Tests ============

    function test_emergencyWithdraw_success() public {
        uint256 depositAmount = 1000 * 1e18;

        vm.startPrank(user1);
        vault.deposit(depositAmount);
        vault.emergencyWithdraw();
        vm.stopPrank();

        assertEq(vault.getDeposit(user1), 0);
        assertEq(token.balanceOf(user1), 100_000 * 1e18);
    }

    // ============ View Function Tests ============

    function test_getVaultBalance() public {
        uint256 depositAmount = 1000 * 1e18;

        vm.prank(user1);
        vault.deposit(depositAmount);

        assertEq(vault.getVaultBalance(), depositAmount);
    }

    function test_getDepositTimestamp() public {
        vm.warp(1000);
        
        vm.prank(user1);
        vault.deposit(1000 * 1e18);

        assertEq(vault.getDepositTimestamp(user1), 1000);
    }

    // ============ Fuzz Tests ============

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1, 100_000 * 1e18);
        
        vm.prank(user1);
        vault.deposit(amount);

        assertEq(vault.getDeposit(user1), amount);
    }

    function testFuzz_APYCalculation(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, OPTIMAL_DEPOSITS * 2);
        
        token.mint(user1, depositAmount);
        vm.prank(user1);
        token.approve(address(vault), depositAmount);
        vm.prank(user1);
        vault.deposit(depositAmount);

        uint256 apy = vault.getAPY();
        
        // APY should be between baseRate and baseRate + slope
        assertGe(apy, BASE_RATE);
        assertLe(apy, BASE_RATE + SLOPE);
    }
}
