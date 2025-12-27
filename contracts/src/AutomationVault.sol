// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AbstractCallback } from "reactive-lib/abstract-base/AbstractCallback.sol";

/**
 * @title IVault
 * @notice Interface for interacting with lending vaults
 */
interface IVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function withdrawAll() external;
    function getDeposit(address user) external view returns (uint256);
    function getAPY() external view returns (uint256);
    function asset() external view returns (IERC20);
}

/**
 * @title AutomationVault
 * @notice User-facing vault that receives automated rebalancing callbacks from Reactive Network
 * @dev Deployed on destination chain (e.g., Sepolia), manages funds across two lending pools
 *      Inherits from AbstractCallback to properly handle Reactive Network callbacks
 * 
 * Architecture:
 * - Users deposit into this vault
 * - Vault allocates funds to Pool A and Pool B
 * - ReactiveVault (on Reactive Network) monitors APYs and triggers rebalance
 * - This contract receives callbacks via the Reactive callback proxy
 */
contract AutomationVault is AbstractCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    
    error AutomationVault__ZeroAddress();
    error AutomationVault__ZeroAmount();
    error AutomationVault__InsufficientBalance();
    error AutomationVault__InvalidPool();
    error AutomationVault__Paused();
    error AutomationVault__RebalanceTooSoon();
    error AutomationVault__NoFundsToRebalance();

    // ============ Events ============
    
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event Rebalanced(address indexed fromPool, address indexed toPool, uint256 amount);
    event AllocationUpdated(address indexed pool, uint256 newAllocation);
    event APYUpdated(address indexed vault, uint256 newApy);
    event RebalanceTriggered(address indexed fromPool, address indexed toPool, uint256 apyDifference);

    // ============ State Variables ============
    
    IERC20 public immutable asset;
    IVault public poolA;
    IVault public poolB;
    
    // User accounting (share-based)
    uint256 public totalShares;
    mapping(address => uint256) public userShares;
    
    // Allocation tracking
    uint256 public allocationA; // Amount allocated to Pool A
    uint256 public allocationB; // Amount allocated to Pool B
    
    // Rebalancing config
    uint256 public minRebalanceInterval; // Minimum time between rebalances
    uint256 public lastRebalanceTime;
    
    // APY tracking (updated by ReactiveVault callbacks)
    uint256 public lastApyA;
    uint256 public lastApyB;
    uint256 public rebalanceThreshold; // Minimum APY difference to trigger rebalance (basis points)
    
    // Status
    bool public paused;

    // ============ Constants ============
    
    uint256 public constant SHARE_PRECISION = 1e18;

    // ============ Constructor ============
    
    /**
     * @param _asset The ERC20 token managed by this vault
     * @param _poolA First lending pool address
     * @param _poolB Second lending pool address
     * @param _callbackProxy Reactive Network's callback proxy address on this chain
     * @param _minRebalanceInterval Minimum seconds between rebalances
     */
    constructor(
        address _asset,
        address _poolA,
        address _poolB,
        address _callbackProxy,
        uint256 _minRebalanceInterval
    ) AbstractCallback(_callbackProxy) Ownable(msg.sender) payable {
        if (_asset == address(0)) revert AutomationVault__ZeroAddress();
        if (_poolA == address(0) || _poolB == address(0)) revert AutomationVault__ZeroAddress();
        if (_callbackProxy == address(0)) revert AutomationVault__ZeroAddress();
        
        asset = IERC20(_asset);
        poolA = IVault(_poolA);
        poolB = IVault(_poolB);
        minRebalanceInterval = _minRebalanceInterval;
        rebalanceThreshold = 100; // Default 1% (100 basis points)
        
        // Approve pools to spend tokens
        asset.approve(_poolA, type(uint256).max);
        asset.approve(_poolB, type(uint256).max);
    }

    // ============ Modifiers ============
    
    modifier whenNotPaused() {
        if (paused) revert AutomationVault__Paused();
        _;
    }

    // ============ User Functions ============
    
    /**
     * @notice Deposit tokens into the vault
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert AutomationVault__ZeroAmount();
        
        // Calculate shares
        uint256 shares;
        uint256 totalAssets = getTotalAssets();
        
        if (totalShares == 0 || totalAssets == 0) {
            shares = amount * SHARE_PRECISION;
        } else {
            shares = (amount * totalShares) / totalAssets;
        }
        
        // Transfer tokens from user
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update state
        userShares[msg.sender] += shares;
        totalShares += shares;
        
        // Deploy to higher APY pool
        _deployToHigherApyPool(amount);
        
        emit Deposit(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw tokens from the vault
     * @param shares Amount of shares to redeem
     */
    function withdraw(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert AutomationVault__ZeroAmount();
        if (userShares[msg.sender] < shares) revert AutomationVault__InsufficientBalance();
        
        // Calculate amount
        uint256 amount = (shares * getTotalAssets()) / totalShares;
        
        // Update state first
        userShares[msg.sender] -= shares;
        totalShares -= shares;
        
        // Withdraw from pools as needed
        _withdrawFromPools(amount);
        
        // Transfer to user
        asset.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, amount, shares);
    }

    // ============ Callback Functions (Called by Reactive Network via Callback Proxy) ============
    
    /**
     * @notice Update APY for a vault (called by Reactive Network callback)
     * @dev Receives APY updates from ReactiveVault and checks if rebalancing is needed
     * @param sender The ReactVM ID (RVM deployer address) - replaced by Reactive Network
     * @param vault The vault that emitted the APY update
     * @param newApy The new APY value in basis points
     */
    function updateAPY(
        address sender,
        address vault,
        uint256 newApy
    ) external authorizedSenderOnly nonReentrant {
        // Update the APY for the correct vault
        if (vault == address(poolA)) {
            lastApyA = newApy;
        } else if (vault == address(poolB)) {
            lastApyB = newApy;
        } else {
            revert AutomationVault__InvalidPool();
        }
        
        emit APYUpdated(vault, newApy);
        
        // Check if rebalancing is needed
        _checkAndRebalance();
    }
    
    /**
     * @notice Internal function to check APY difference and trigger rebalance
     */
    function _checkAndRebalance() internal {
        // Skip if we don't have APY data from both vaults yet
        if (lastApyA == 0 || lastApyB == 0) {
            return;
        }
        
        // Check rebalance interval
        if (block.timestamp < lastRebalanceTime + minRebalanceInterval) {
            return;
        }
        
        uint256 apyDifference;
        address fromPool;
        address toPool;
        
        // Determine which vault has higher APY
        if (lastApyA > lastApyB) {
            apyDifference = lastApyA - lastApyB;
            fromPool = address(poolB); // Move FROM lower APY
            toPool = address(poolA);   // Move TO higher APY
        } else {
            apyDifference = lastApyB - lastApyA;
            fromPool = address(poolA);
            toPool = address(poolB);
        }
        
        // Check if difference exceeds threshold
        if (apyDifference >= rebalanceThreshold) {
            _executeRebalance(fromPool, toPool, apyDifference);
        }
    }
    
    /**
     * @notice Execute the rebalance operation
     */
    function _executeRebalance(address fromPool, address toPool, uint256 apyDifference) internal {
        IVault from = IVault(fromPool);
        uint256 fromBalance = from.getDeposit(address(this));
        
        if (fromBalance == 0) {
            return; // No funds to rebalance
        }
        
        // Withdraw all from lower APY pool
        from.withdrawAll();
        
        // Get the actual withdrawn amount
        uint256 withdrawnAmount = asset.balanceOf(address(this));
        
        // Deposit to higher APY pool
        IVault(toPool).deposit(withdrawnAmount);
        
        // Update allocations
        if (fromPool == address(poolA)) {
            allocationA = 0;
            allocationB += withdrawnAmount;
        } else {
            allocationB = 0;
            allocationA += withdrawnAmount;
        }
        
        lastRebalanceTime = block.timestamp;
        
        emit RebalanceTriggered(fromPool, toPool, apyDifference);
        emit Rebalanced(fromPool, toPool, withdrawnAmount);
    }
    
    /**
     * @notice Manual rebalance (can be called directly - kept for backwards compatibility)
     * @dev Uses authorizedSenderOnly modifier from AbstractCallback to verify callback proxy
     * @param sender The ReactVM ID (RVM deployer address) - replaced by Reactive Network
     * @param fromPool Pool to withdraw from
     * @param toPool Pool to deposit to
     */
    function rebalance(
        address sender,
        address fromPool,
        address toPool
    ) external authorizedSenderOnly nonReentrant {
        // Note: authorizedSenderOnly already verifies msg.sender is the callback proxy
        // The 'sender' parameter is the RVM ID, automatically filled by Reactive Network
        
        // Validate pools
        if (fromPool != address(poolA) && fromPool != address(poolB)) revert AutomationVault__InvalidPool();
        if (toPool != address(poolA) && toPool != address(poolB)) revert AutomationVault__InvalidPool();
        if (fromPool == toPool) revert AutomationVault__InvalidPool();
        
        // Check rebalance interval
        if (block.timestamp < lastRebalanceTime + minRebalanceInterval) {
            revert AutomationVault__RebalanceTooSoon();
        }
        
        // Get amount to rebalance
        IVault from = IVault(fromPool);
        uint256 fromBalance = from.getDeposit(address(this));
        
        if (fromBalance == 0) revert AutomationVault__NoFundsToRebalance();
        
        // Withdraw all from lower APY pool
        from.withdrawAll();
        
        // Get the actual withdrawn amount
        uint256 withdrawnAmount = asset.balanceOf(address(this));
        
        // Deposit to higher APY pool
        IVault(toPool).deposit(withdrawnAmount);
        
        // Update allocations
        if (fromPool == address(poolA)) {
            allocationA = 0;
            allocationB += withdrawnAmount;
        } else {
            allocationB = 0;
            allocationA += withdrawnAmount;
        }
        
        lastRebalanceTime = block.timestamp;
        
        emit Rebalanced(fromPool, toPool, withdrawnAmount);
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Deploy new deposits to the pool with higher APY
     */
    function _deployToHigherApyPool(uint256 amount) internal {
        uint256 apyA = poolA.getAPY();
        uint256 apyB = poolB.getAPY();
        
        if (apyA >= apyB) {
            poolA.deposit(amount);
            allocationA += amount;
        } else {
            poolB.deposit(amount);
            allocationB += amount;
        }
    }

    /**
     * @notice Withdraw from pools to fulfill user withdrawal
     */
    function _withdrawFromPools(uint256 amount) internal {
        uint256 vaultBalance = asset.balanceOf(address(this));
        
        // Use vault balance first
        if (vaultBalance >= amount) {
            return;
        }
        
        uint256 remaining = amount - vaultBalance;
        
        // Withdraw from Pool A first
        uint256 depositA = poolA.getDeposit(address(this));
        if (depositA > 0) {
            uint256 withdrawFromA = remaining > depositA ? depositA : remaining;
            poolA.withdraw(withdrawFromA);
            allocationA -= withdrawFromA;
            remaining -= withdrawFromA;
        }
        
        // Withdraw from Pool B if needed
        if (remaining > 0) {
            uint256 depositB = poolB.getDeposit(address(this));
            uint256 withdrawFromB = remaining > depositB ? depositB : remaining;
            poolB.withdraw(withdrawFromB);
            allocationB -= withdrawFromB;
        }
    }

    // ============ Owner Functions ============
    
    /**
     * @notice Pause the vault
     */
    function pause() external onlyOwner {
        paused = true;
    }

    /**
     * @notice Unpause the vault
     */
    function unpause() external onlyOwner {
        paused = false;
    }

    /**
     * @notice Update minimum rebalance interval
     */
    function setMinRebalanceInterval(uint256 _interval) external onlyOwner {
        minRebalanceInterval = _interval;
    }
    
    /**
     * @notice Update rebalance threshold
     */
    function setRebalanceThreshold(uint256 _threshold) external onlyOwner {
        rebalanceThreshold = _threshold;
    }

    /**
     * @notice Emergency withdraw all from pools
     */
    function emergencyWithdrawAll() external onlyOwner {
        uint256 depositA = poolA.getDeposit(address(this));
        uint256 depositB = poolB.getDeposit(address(this));
        
        if (depositA > 0) {
            poolA.withdrawAll();
            allocationA = 0;
        }
        if (depositB > 0) {
            poolB.withdrawAll();
            allocationB = 0;
        }
    }

    // ============ View Functions ============
    
    /**
     * @notice Get total assets managed by vault
     */
    function getTotalAssets() public view returns (uint256) {
        uint256 vaultBalance = asset.balanceOf(address(this));
        uint256 poolADeposit = poolA.getDeposit(address(this));
        uint256 poolBDeposit = poolB.getDeposit(address(this));
        
        return vaultBalance + poolADeposit + poolBDeposit;
    }

    /**
     * @notice Get user's share balance in terms of underlying asset
     */
    function getUserBalance(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (userShares[user] * getTotalAssets()) / totalShares;
    }

    /**
     * @notice Get current allocations
     */
    function getAllocations() external view returns (uint256 poolAAmount, uint256 poolBAmount) {
        return (poolA.getDeposit(address(this)), poolB.getDeposit(address(this)));
    }

    /**
     * @notice Get current APYs from both pools
     */
    function getPoolAPYs() external view returns (uint256 apyA, uint256 apyB) {
        return (poolA.getAPY(), poolB.getAPY());
    }

    /**
     * @notice Convert shares to underlying amount
     */
    function sharesToAssets(uint256 shares) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * getTotalAssets()) / totalShares;
    }

    /**
     * @notice Convert underlying amount to shares
     */
    function assetsToShares(uint256 assets) external view returns (uint256) {
        uint256 totalAssets = getTotalAssets();
        if (totalAssets == 0 || totalShares == 0) {
            return assets * SHARE_PRECISION;
        }
        return (assets * totalShares) / totalAssets;
    }

    // ============ Receive ============
    
    receive() external payable override {}
}
